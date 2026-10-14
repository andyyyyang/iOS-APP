import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { AppError, toErrorBody } from "../errors.js";
import { MAX_TEMPLATE_RULES } from "../schemas.js";
import type { Services } from "../services/index.js";
import type { Scan } from "../types.js";
import { contentTypeFor } from "../vault/paths.js";
import type { VaultFile } from "../vault/types.js";
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

/** Like run, for tools that build their own content blocks. */
async function runRaw(fn: () => Promise<CallToolResult>): Promise<CallToolResult> {
  try {
    return await fn();
  } catch (error) {
    return fail(error);
  }
}

/** Larger text files are described instead of returned, so an agent never edits a truncated copy. */
const MAX_TEXT_BYTES = 1024 * 1024;
const utf8 = new TextDecoder("utf-8", { fatal: true });

/** The file as text, or null for binary content (images, PDF, NUL bytes, invalid UTF-8). */
function asText(file: VaultFile): string | null {
  const type = contentTypeFor(file.path);
  if (type.startsWith("image/") || type === "application/pdf" || file.body.includes(0)) return null;
  try {
    return utf8.decode(file.body);
  } catch {
    return null;
  }
}

/** vault_read: JSON metadata, then the raw text as a second block (no JSON escaping of the note). */
function vaultReadResult(file: VaultFile): CallToolResult {
  const meta = { path: file.path, size: file.size, mtime: file.mtime, etag: file.etag, contentType: contentTypeFor(file.path) };
  if (file.size > MAX_TEXT_BYTES) {
    return ok({ ...meta, tooLarge: true, note: "Over 1 MB; content not returned. 超過 1 MB，不回傳內容。" });
  }
  const text = asText(file);
  if (text === null) return ok({ ...meta, binary: true, note: "Binary file; content not returned. 二進位檔，不回傳內容。" });
  return { content: [{ type: "text", text: json(meta) }, { type: "text", text }] };
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
const vaultPath = z.string().describe("相對於 vault 根目錄的檔案路徑 File path relative to the vault root, e.g. Inbox/想法.md");
const vaultPrefix = z.string().describe("資料夾，例如 Daily/；省略代表根目錄 Folder such as Daily/ (default: vault root)");

export function createMcpServer(services: Services): McpServer {
  const server = new McpServer(
    { name: "localocr", version: VERSION },
    {
      instructions:
        "LocalOCR：iPhone 裝置端 OCR 的掃描紀錄與情境樣板。先用 list_scans 找掃描，get_scan 取全文，依 get_template 的 sample 結構抽取 JSON，" +
        "以 validate_data 檢查後用 update_scan_data 回寫。\n" +
        "LocalOCR: scans from on-device OCR plus scenario templates. Find scans with list_scans, read full text with get_scan, " +
        "extract JSON shaped like the template sample, check it with validate_data, then write it back with update_scan_data.\n" +
        "vault_* 工具讀寫使用者的 Obsidian 筆記庫（Markdown，經 Remotely Save 同步到所有裝置）：修改前先 vault_read，保留 frontmatter 與既有內容，寫入時帶 ifMatch=etag。\n" +
        "vault_* tools read and write the user's Obsidian vault (Markdown notes synced to all devices by Remotely Save): " +
        "vault_read before editing, keep the frontmatter and existing content, and pass ifMatch with the etag when writing.",
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

  server.registerTool(
    "vault_list",
    {
      title: "List vault files",
      description:
        "列出使用者 Obsidian 筆記庫（vault）的檔案。筆記是 Markdown（.md），由 Obsidian 的 Remotely Save 插件同步到 S3 儲存桶，" +
        "iPad App 與 Claude 讀寫的是同一份檔案。預設只列出該資料夾這一層（folders 為子資料夾）；recursive=true 列出底下全部檔案。" +
        "以 . 開頭的資料夾（例如 .obsidian、.localocr）是程式資料，不是筆記。" +
        "回傳 { items: [{ path, size, mtime（毫秒）, etag }], folders }。\n" +
        "List files in the user's Obsidian vault: Markdown notes synced by the Remotely Save plugin to an S3 bucket that the iPad app and Claude share. " +
        "Lists one folder level by default (folders = child folders); recursive=true lists every file below prefix. " +
        "Dot folders (e.g. .obsidian, .localocr) hold app data, not notes. " +
        "Returns { items: [{ path, size, mtime (ms), etag }], folders }.",
      inputSchema: {
        prefix: vaultPrefix.optional(),
        recursive: z.boolean().optional().describe("列出所有子資料夾的檔案（預設 false） List files in all subfolders (default false)"),
      },
      annotations: { readOnlyHint: true },
    },
    ({ prefix, recursive }) => run(() => services.vault.list({ prefix, recursive })),
  );

  server.registerTool(
    "vault_read",
    {
      title: "Read vault file",
      description:
        "讀取 Obsidian vault 中的一個檔案。文字檔回傳兩段內容：第一段是 JSON（path、size、mtime、etag），第二段是檔案原文；" +
        "圖片、PDF 等二進位檔或超過 1 MB 的檔案只回傳描述。要修改筆記時先讀取，再把 etag 當作 vault_write 的 ifMatch。\n" +
        "Read one file from the Obsidian vault. Text files return two blocks: JSON metadata (path, size, mtime, etag), then the raw content. " +
        "Binary files (images, PDF) and files over 1 MB return only a description. Read before editing and pass the etag to vault_write as ifMatch.",
      inputSchema: { path: vaultPath },
      annotations: { readOnlyHint: true },
    },
    ({ path }) => runRaw(async () => vaultReadResult(await services.vault.read(path))),
  );

  server.registerTool(
    "vault_write",
    {
      title: "Write vault file",
      description:
        "寫入（新增或整檔取代）Obsidian vault 中的文字檔，例如 Markdown 筆記；下次 Remotely Save 同步時就會出現在使用者的所有裝置上。" +
        "修改既有筆記：先 vault_read，保留原有的 frontmatter（開頭的 --- 區塊）與其他內容，只改需要改的部分，並帶 ifMatch=讀取時的 etag；" +
        "若檔案在這之間被改過會回傳 precondition_failed（含 currentEtag），請重新讀取、合併後再寫。沒有 ifMatch 時只會新增：檔案已存在就回傳 precondition_failed，不會覆寫。" +
        "回傳 { path, size, mtime, etag, created }。\n" +
        "Write (create or fully replace) a text file in the Obsidian vault, e.g. a Markdown note; it reaches all of the user's devices on the next Remotely Save sync. " +
        "To edit an existing note: vault_read it first, preserve its frontmatter (the leading --- block) and all other content, change only what is needed, " +
        "and pass ifMatch with the etag from the read. If the file changed in between you get precondition_failed (with currentEtag): re-read, merge and write again. " +
        "Without ifMatch the call only creates: an existing file is never overwritten and you get precondition_failed instead. Returns { path, size, mtime, etag, created }.",
      inputSchema: {
        path: vaultPath,
        content: z.string().describe("完整的新檔案內容（UTF-8） The complete new file content (UTF-8)"),
        ifMatch: z.string().optional().describe("vault_read 取得的 etag；不符時不寫入 Etag from vault_read; the write fails if the file changed"),
        createOnly: z.boolean().optional().describe("只新增（沒有 ifMatch 時的預設行為） Only create; the default when ifMatch is absent"),
      },
      annotations: { idempotentHint: true },
    },
    ({ path, content, ifMatch, createOnly }) =>
      run(async () => {
        // 覆寫既有筆記一定要帶讀取時的 etag：避免 agent 沒讀過就整檔取代使用者的筆記
        const { value, created } = await services.vault.write(path, Buffer.from(content, "utf8"), {
          ifMatch,
          ifNoneMatch: createOnly || !ifMatch ? "*" : undefined,
        });
        return { ...value, created };
      }),
  );

  server.registerTool(
    "vault_search",
    {
      title: "Search vault",
      description:
        "在 Obsidian vault 的 .md／.txt／.json／.canvas 檔案中搜尋檔名與內容（不分大小寫），依修改時間由新到舊，" +
        "回傳 { items: [{ path, mtime, snippet }] }（snippet 是符合處前後約 120 字）。\n" +
        "Search the names and contents of .md/.txt/.json/.canvas files in the Obsidian vault (case-insensitive), newest first. " +
        "Returns { items: [{ path, mtime, snippet }] } where snippet is ~120 characters around the match.",
      inputSchema: {
        query: z.string().describe("搜尋文字 Text to find"),
        prefix: vaultPrefix.optional(),
        limit: z.number().int().min(1).max(100).optional().describe("筆數 Max results (default 20, max 100)"),
      },
      annotations: { readOnlyHint: true },
    },
    ({ query, prefix, limit }) => run(() => services.vault.search(query, { prefix, limit })),
  );

  return server;
}
