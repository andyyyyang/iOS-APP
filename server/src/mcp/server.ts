import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { AppError, toErrorBody } from "../errors.js";
import { MAX_TEMPLATE_RULES } from "../schemas.js";
import type { Services } from "../services/index.js";
import type { Scan } from "../types.js";
import { VERSION } from "../version.js";

const json = (value: unknown) => JSON.stringify(value, null, 2);

const ok = (value: unknown): CallToolResult => ({ content: [{ type: "text", text: json(value) }] });

function fail(error: unknown): CallToolResult {
  const appError =
    error instanceof AppError ? error : new AppError(500, "internal_error", "Internal server error");
  if (!(error instanceof AppError)) console.error("[mcp] tool error", error);
  return { isError: true, content: [{ type: "text", text: json(toErrorBody(appError)) }] };
}

async function run(fn: () => Promise<unknown>): Promise<CallToolResult> {
  try {
    return ok(await fn());
  } catch (error) {
    return fail(error);
  }
}

/** Compact view for list_scans; get_scan returns everything. */
function summarize(scan: Scan) {
  const title = scan.text.split(/\r?\n/).map((line) => line.trim()).find(Boolean) ?? "";
  return {
    id: scan.id,
    createdAt: scan.createdAt,
    updatedAt: scan.updatedAt,
    source: scan.source,
    templateId: scan.templateId,
    title: title.slice(0, 80),
    preview: scan.text.replace(/\s+/g, " ").trim().slice(0, 160),
    lineCount: scan.lineCount,
    hasData: scan.data !== null,
  };
}

// Plain schemas (no transforms) so they convert cleanly to JSON Schema; services do the strict parsing.
const templateId = z.string().describe("樣板代碼 Template id, e.g. receipt / business_card / event / document");
const scanId = z.string().describe("掃描 UUID Scan id (UUID)");
const jsonObject = z.record(z.string(), z.unknown());

export function createMcpServer(services: Services): McpServer {
  const server = new McpServer(
    { name: "localocr", version: VERSION },
    {
      instructions:
        "LocalOCR：iPhone 裝置端 OCR 的掃描紀錄與情境樣板。先用 list_scans 找掃描，get_scan 取全文，依 get_template 的 sample 結構抽取 JSON，" +
        "以 validate_data 檢查後用 update_scan_data 回寫。\n" +
        "LocalOCR: scans from on-device OCR plus scenario templates. Find scans with list_scans, read full text with get_scan, " +
        "extract JSON shaped like the template sample, check it with validate_data, then write it back with update_scan_data.",
    },
  );

  server.registerTool(
    "list_scans",
    {
      title: "List scans",
      description:
        "列出掃描紀錄摘要（標題、預覽、樣板、時間），預設由新到舊；帶 updatedAfter 時依更新時間由舊到新。\n" +
        "List scan summaries (newest first; oldest-updated first when updatedAfter is given). Use get_scan for full text and data.",
      inputSchema: {
        limit: z.number().int().min(1).max(200).optional().describe("筆數 Max items (default 50, max 200)"),
        templateId: templateId.optional().describe("只列出此樣板 Only scans with this templateId"),
        query: z.string().optional().describe("全文搜尋（不分大小寫） Case-insensitive text search"),
        updatedAfter: z.string().optional().describe("ISO 8601；只列出之後更新的 Only scans updated after this time"),
        cursor: z.string().optional().describe("上一頁回傳的 nextCursor Pass back nextCursor to get the next page"),
      },
      annotations: { readOnlyHint: true },
    },
    ({ limit, templateId, query, updatedAfter, cursor }) =>
      run(async () => {
        const page = await services.scans.list({ limit, templateId, q: query, updatedAfter, cursor });
        return { items: page.items.map(summarize), nextCursor: page.nextCursor };
      }),
  );

  server.registerTool(
    "get_scan",
    {
      title: "Get scan",
      description: "取得完整掃描紀錄，含 OCR 全文、分類與結構化 JSON。\nGet a full scan including OCR text, classification and extracted data.",
      inputSchema: { id: scanId },
      annotations: { readOnlyHint: true },
    },
    ({ id }) => run(() => services.scans.get(id)),
  );

  server.registerTool(
    "update_scan_data",
    {
      title: "Update scan data",
      description:
        "回寫掃描的結構化資料（data），可同時指定樣板。建議先用 validate_data 檢查。\n" +
        "Write extracted structured data back to a scan, optionally setting its templateId. Validate first with validate_data.",
      inputSchema: {
        id: scanId,
        data: jsonObject.nullable().describe("依樣板 sample 結構的 JSON；null 代表清除 JSON shaped like the template sample, or null to clear"),
        templateId: templateId.nullable().optional().describe("使用的樣板 Template used for the data"),
      },
      annotations: { idempotentHint: true },
    },
    ({ id, data, templateId }) =>
      run(() => services.scans.patch(id, templateId === undefined ? { data } : { data, templateId })),
  );

  server.registerTool(
    "list_templates",
    {
      title: "List templates",
      description: "列出所有情境樣板（含描述、關鍵字與輸出範例 sample）。\nList all scenario templates with description, keywords and output sample.",
      annotations: { readOnlyHint: true },
    },
    () => run(async () => ({ items: await services.templates.list() })),
  );

  server.registerTool(
    "get_template",
    {
      title: "Get template",
      description:
        "取得單一情境樣板。sample 是輸出 JSON 的範例：欄位、巢狀結構、陣列形式與順序都要一致；rules 是抽取後由 App 套用的後處理規則。\n" +
        "Get one template. Its sample is an example of the output JSON: same keys, nesting, array shape and key order. " +
        "rules are post-processing steps clients apply after extraction.",
      inputSchema: { id: templateId },
      annotations: { readOnlyHint: true },
    },
    ({ id }) => run(() => services.templates.get(id)),
  );

  server.registerTool(
    "upsert_template",
    {
      title: "Create or update template",
      description:
        "新增或更新情境樣板（整筆取代，version 自動加一）。新增情境不需改程式：App、伺服器與 harness 都會立即使用。\n" +
        "rules（選用，最多 100 條）是 App 在 AI 抽取後依序套用的確定性後處理，伺服器只儲存不執行。每條規則必須有 set（目標路徑：field 或 array[].field），" +
        "其他鍵為操作：value 固定值；copy 複製欄位；template 字串模板 \"{field}\"（{field:,} 千分位）；sum [路徑...] 加總；join 路徑 + separator；" +
        "divide [分子, 分母]（欄位或數字）+ round 小數位；match 正規表示式（從整份 OCR 文字找出所有符合者，以 separator 串接）；today: true 今天日期；generate: \"base36time\" 產生代碼；lookup 欄位 + table {鍵: 值} 對照；onlyIfEmpty: true 僅在目標為空時套用。" +
        "set 為 _title／_subtitle 的規則是 App 紀錄的名稱與副標，不會輸出。\n" +
        "Create or replace a scenario template (version auto-increments). New scenarios need no code changes. " +
        "rules (optional, max 100) are deterministic post-processing steps clients apply in order after AI extraction; the server stores them verbatim. " +
        "Each rule needs set (target path: field or array[].field) plus an op: value (constant), copy (field), template (\"{field}\" string), " +
        "sum ([paths]), join (path + separator), divide ([num, den] as fields or numbers + round), match (regex over the whole OCR text; unique matches joined by separator), " +
        "today: true, generate: \"base36time\", lookup (field + table {key: value}); onlyIfEmpty: true applies the rule only when the target is empty. " +
        "Rules whose set is _title / _subtitle name the record in the app and are not part of data.\n" +
        'Example: [{"set":"total","sum":["items[].price"]},{"set":"items[].category","lookup":"name","table":{"鮮乳":"飲品"},"onlyIfEmpty":true}]',
      inputSchema: {
        id: templateId.describe("代碼，符合 ^[a-z0-9][a-z0-9_-]{0,63}$ Id matching ^[a-z0-9][a-z0-9_-]{0,63}$"),
        name: z.string().describe("顯示名稱 Display name"),
        description: z.string().describe("情境描述，供分類器判斷 Scenario description used by classifiers"),
        sample: jsonObject.describe("輸出 JSON 範例（保留欄位順序；null 代表可為空的字串） Example output JSON (key order kept; null = nullable string)"),
        instructions: z.string().optional().describe("額外抽取規則 Extra extraction rules"),
        keywords: z
          .array(z.string())
          .optional()
          .describe(
            "離線關鍵字分類備援；以 ! 開頭為強特徵（統編、公司名稱），唯一命中時直接判定 Keywords for fallback classification; a \"!\" prefix marks a strong signal (tax ID, company name) that decides the scenario when only one template matches",
          ),
        rules: z
          .array(z.record(z.string(), z.unknown()))
          .max(MAX_TEMPLATE_RULES)
          .optional()
          .describe("後處理規則，每條需有 set；省略代表清空 Post-processing rules, each with a set target; omitted = none"),
      },
      annotations: { idempotentHint: true },
    },
    ({ id, ...body }) => run(async () => (await services.templates.put(id, body)).value),
  );

  server.registerTool(
    "delete_template",
    {
      title: "Delete template",
      description: "刪除情境樣板（內建樣板會在伺服器重啟時補回）。\nDelete a scenario template (built-in templates are re-seeded on restart).",
      inputSchema: { id: templateId },
      annotations: { destructiveHint: true },
    },
    ({ id }) =>
      run(async () => {
        await services.templates.delete(id);
        return { deleted: true, id };
      }),
  );

  server.registerTool(
    "classify_text",
    {
      title: "Classify text",
      description:
        "判斷文字屬於哪個情境樣板：唯一命中強特徵（! 關鍵字）時直接判定，否則用 Jev；回傳 templateId、信心度與各樣板機率。\n" +
        "Classify text into a template: a unique strong signal (\"!\" keyword) decides, otherwise Jev; returns templateId, confidence and per-template probabilities.",
      inputSchema: {
        text: z.string().describe("OCR 文字（超過 8000 字會截斷） Text to classify (truncated to 8000 chars)"),
        templateIds: z.array(templateId).optional().describe("限定候選樣板，預設全部 Restrict candidates (default: all templates)"),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    (args) => run(() => services.classify.classify(args)),
  );

  server.registerTool(
    "validate_data",
    {
      title: "Validate data",
      description:
        "檢查 JSON 是否符合樣板 sample 的結構（缺少／多餘欄位、型別），回傳 { valid, issues }。\n" +
        "Check JSON against a template sample's structure (missing/unexpected keys, types); returns { valid, issues }.",
      inputSchema: {
        templateId,
        data: jsonObject.describe("要檢查的 JSON JSON to check"),
      },
      annotations: { readOnlyHint: true },
    },
    (args) => run(() => services.validate.validate(args)),
  );

  return server;
}
