# LocalOCR 共用資料格式與 API 規格

本文件是 iPhone App、Railway 伺服器、Obsidian 插件、Claude Code 插件與任何自建 harness 之間的唯一約定。
所有元件都依這份規格實作；擴充時（新增情境、欄位、工具）請先更新本文件。

## 架構

```
iPhone App ──(OCR：Vision，裝置端)──▶ 文字
   │  分類：強特徵（! 關鍵字）→ Jev（經伺服器）→ 裝置端 Foundation Models → 關鍵字
   │  抽取：Foundation Models（裝置端）依樣板輸出 JSON
   ▼
Railway 伺服器（/v1 REST、/mcp MCP、Postgres）
   ├── Obsidian 插件：增量同步成筆記
   ├── Claude Code 插件／任何 MCP 客戶端：MCP 工具
   ├── 自建 harness：REST + OpenAPI（/v1/openapi.json）
   └── Vault（/v1/vault、vault_* 工具）⇄ Railway Storage Bucket ⇄ Remotely Save ⇄ 各裝置的 Obsidian
```

## 驗證

- 所有 `/v1/*` 與 `/mcp` 端點都需要 API 金鑰。
- 標頭：`Authorization: Bearer <API_KEY>`。無法自訂標頭的客戶端可改用查詢參數 `?api_key=<API_KEY>`（網址可能被記錄，僅在必要時使用）。
- 伺服器環境變數 `API_KEYS` 可放多把金鑰，以逗號分隔（方便替換與分發給不同裝置）。
- `GET /health` 不需要驗證。

## 資料格式

### Template（情境樣板）

情境就是資料，不寫死在程式中：新增情境只要新增一筆樣板，App、伺服器、harness 都能立即使用。

```json
{
  "id": "receipt",
  "name": "收據／發票",
  "description": "購物收據、統一發票、消費明細，含商店、日期、品項與金額",
  "keywords": ["合計", "總計", "統一編號", "發票", "收據", "找零"],
  "sample": {
    "store": "全聯福利中心",
    "date": "2026-10-02",
    "items": [{ "name": "鮮乳", "quantity": 1, "price": 45 }],
    "total": 45,
    "currency": "TWD"
  },
  "instructions": "金額使用數字；日期使用 YYYY-MM-DD。",
  "version": 1,
  "updatedAt": "2026-10-02T03:00:00.000Z"
}
```

| 欄位 | 說明 |
| --- | --- |
| `id` | 唯一代碼，符合 `^[a-z0-9][a-z0-9_-]{0,63}$` |
| `name` | 顯示名稱 |
| `description` | 情境描述；分類器（Jev 的 choice criteria、裝置端模型）依此判斷 |
| `keywords` | 選用；離線時的關鍵字分類備援。以 `!` 開頭的是**強特徵**（例如廠商統一編號、公司名稱，例：`"!22368445"`）：文字中只出現一個情境的強特徵時直接判定（`provider` 為 `keywords`、信心度 1），不呼叫 Jev 或裝置端模型；同時命中多個情境則照常交給分類器 |
| `sample` | **輸出樣式的範例 JSON**：輸出會有相同的欄位、巢狀結構、陣列形式與欄位順序。字串、數字、布林、陣列（以第一個元素為格式）、物件、`null`（代表可為空的字串）皆可 |
| `instructions` | 選用；給 AI 的額外抽取說明 |
| `rules` | 選用；AI 抽取後由程式套用的計算規則（見下方），回傳時一律為陣列 |
| `version` | 伺服器每次更新自動加一 |
| `updatedAt` | 伺服器設定，ISO 8601 |

`sample` 的欄位順序必須保留：伺服器以文字儲存原始 JSON（不可用 Postgres `jsonb`，它會重排鍵值）。

內建樣板：`receipt`（收據／發票）、`business_card`（名片）、`event`（活動／海報）、`document`（一般文件，作為無法判斷時的預設）。

受管理樣板：`server/templates/managed/*.json`（每個檔案是一個完整樣板）。伺服器啟動時若內容與資料庫不同就更新，repo 是唯一來源；App 也內附同一份（`LocalOCR/Resources/ManagedTemplates`，CI 檢查兩者一致）。目前有 `fv60_air`（FV60 空運請款）與 `fv60_sea`（FV60 海運請款，三家發票）。

#### 計算規則（rules）

金額加總、串接、固定值這類計算交給程式，AI 只讀出文件上印的內容。規則依序執行，`set` 是目標欄位（`field` 或 `array[].field`）；規則設定的頂層欄位不會交給 AI 產生。來源路徑另可使用純值陣列 `array[]`。

**輔助欄位**：`sample` 中以 `_` 開頭的頂層欄位由 AI 擷取、只供規則計算，最後會從輸出移除，`validate_data` 也不要求它們。例如 FV60 的 `_declarationQuantities` 是出口報單上各品項的數量，規則 `{"set":"qty","sum":["_declarationQuantities[]"]}` 加總成 `qty`。

| 運算 | 範例 | 說明 |
| --- | --- | --- |
| `value` | `{"set":"supplier","value":"800000"}` | 固定值 |
| `copy` | `{"set":"expenseAmount","copy":"amount"}` | 複製欄位 |
| `template` | `{"set":"text","template":"出口/{osat}/{caseNo}"}` | 代入欄位的字串；`{amount:,}` 數字加千分位 |
| `sum` | `{"set":"amount","sum":["taxItems[].taxBase","taxItems[].taxAmount"]}` | 加總 |
| `join` | `{"set":"invoice","join":"taxItems[].invoice","separator":" / "}` | 串接 |
| `divide` | `{"set":"price","divide":["amount","qty"],"round":3}`、`{"set":"expenseAmount","divide":["amount",1.05],"round":0}` | 除法；運算元可為欄位或數字（分母為 0 或空值時為 null） |
| `match` | `{"set":"caseNo","match":"(JT)[ -]?(\\d{7}(?:-\\d{1,2})?)(?!\\d)","separator":","}` | 以正規表示式從整份 OCR 文字找出所有符合的字串（去除重複、依出現順序以 `separator` 串接）；有括號群組時取各群組串接；找不到時保留原值。適合格式固定的號碼，不經過 AI |
| `today` | `{"set":"date","today":true}` | 今天（YYYY-MM-DD） |
| `generate` | `{"set":"id","generate":"base36time"}` | 時間戳記 id（例如 `mum0takt3q2`） |
| `lookup` | `{"set":"taxItems[].name","lookup":"taxId","table":{"22368445":"義佳"}}` | 依同一層欄位對照 |
| `onlyIfEmpty` | `{"set":"note","value":"—","onlyIfEmpty":true}` | 已有值時不覆寫 |

**紀錄名稱**：`set` 為 `_title`、`_subtitle` 的規則（通常是 `template`）產生 App 紀錄列表顯示的名稱與副標，不會輸出到 `data`；`template` 以「 · 」分段，欄位沒有值的段落省略。例如 FV60：`{"set":"_title","template":"{caseNo}"}`、`{"set":"_subtitle","template":"總金額 {amount:,} · 單價 {price}"}`。

**防止照抄**：抽取提示只示範欄位格式（號碼的數字以 0 表示），不放範例的實際值；每頁抽出的數字與含 6 個以上數字的代碼必須出現在該頁 OCR 文字中，否則不採用。

多頁文件逐頁抽取後合併：單一值取第一個非空值；物件陣列依頁序串接並去除空白與重複項目；純值陣列只略過整頁重複的結果（同一頁的相同數值都保留）。最後套用規則並移除輔助欄位。

### Scan（掃描紀錄）

```json
{
  "id": "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11",
  "createdAt": "2026-10-02T03:10:00.000Z",
  "updatedAt": "2026-10-02T03:10:02.000Z",
  "source": "camera",
  "text": "全聯福利中心\n鮮乳 45\n合計 45",
  "templateId": "receipt",
  "classification": {
    "templateId": "receipt",
    "confidence": 0.93,
    "provider": "jev",
    "probabilities": { "receipt": 0.93, "document": 0.05, "business_card": 0.02 }
  },
  "data": { "store": "全聯福利中心", "date": null, "items": [{ "name": "鮮乳", "quantity": 1, "price": 45 }], "total": 45, "currency": "TWD" },
  "lineCount": 3,
  "averageConfidence": 0.91,
  "pageCount": 1,
  "device": "iPhone"
}
```

| 欄位 | 說明 |
| --- | --- |
| `id` | 由 App 產生的 UUID；上傳使用 `PUT`，重送不會重複 |
| `createdAt` | App 端掃描時間 |
| `updatedAt` | 伺服器每次寫入時設定；增量同步依此排序 |
| `source` | `photoLibrary`、`camera`、`documentScanner`、`pasteboard`、`liveScanner` |
| `text` | OCR 全文 |
| `templateId` | 使用的樣板，可為 `null` |
| `classification` | 選用；`provider` 為 `jev`、`on-device`、`keywords`、`manual` |
| `data` | 依樣板抽取的 JSON，可為 `null` |
| 其他 | 選用的統計資訊 |

## REST API（`/v1`）

錯誤一律回傳 `{"error": {"code": "not_found", "message": "..."}}` 與對應的 HTTP 狀態碼。

| 方法與路徑 | 說明 |
| --- | --- |
| `GET /health` | `{"status":"ok","version":"1.0.0","database":"postgres","jev":true}`（`jev` 表示是否已設定 Jev 金鑰） |
| `PUT /v1/scans/{id}` | 新增或更新掃描（冪等），回傳完整 Scan |
| `GET /v1/scans` | 列表。查詢參數：`limit`（預設 50，最多 200）、`templateId`、`q`（全文搜尋）、`updatedAfter`（ISO 8601）與 `cursor`。帶 `updatedAfter` 或 `cursor` 時依 `updatedAt` 由舊到新排序（增量同步用），否則依 `createdAt` 由新到舊。回傳 `{"items":[...],"nextCursor":"..."或null}` |
| `GET /v1/scans/{id}` | 取得單筆 |
| `PATCH /v1/scans/{id}` | 局部更新 `templateId`、`data`、`classification`（harness 回寫結構化結果用） |
| `DELETE /v1/scans/{id}` | 刪除，回傳 204 |
| `GET /v1/templates` | `{"items":[Template...]}` |
| `GET /v1/templates/{id}` | 取得單一樣板 |
| `PUT /v1/templates/{id}` | 新增或更新樣板（`version` 自動加一） |
| `DELETE /v1/templates/{id}` | 刪除，回傳 204 |
| `POST /v1/classify` | 請求 `{"text":"...","templateIds":["receipt","document"]}`（`templateIds` 選用，預設全部樣板）。回傳 `{"templateId":"receipt","confidence":0.93,"probabilities":{...},"provider":"jev"}`。文字命中唯一情境的強特徵（`!` 關鍵字）時直接回傳該情境，`provider` 為 `keywords`，不需要 Jev。其他情況若未設定 Jev 金鑰則回傳 503 `jev_not_configured`，客戶端應改用其他分類器 |
| `GET /v1/openapi.json` | OpenAPI 3.1 規格，供自建 harness 產生客戶端 |
| `/v1/vault/*` | Obsidian 筆記檔案，見下方「Vault（Obsidian 筆記）」 |

`nextCursor` 是不透明字串，客戶端原樣帶回即可。

## MCP（`/mcp`）

Streamable HTTP 傳輸，無狀態（方便水平擴充）。工具：

| 工具 | 參數 | 說明 |
| --- | --- | --- |
| `list_scans` | `limit?`, `templateId?`, `query?`, `updatedAfter?` | 列出掃描（摘要） |
| `get_scan` | `id` | 取得完整掃描，含全文與 JSON |
| `update_scan_data` | `id`, `data`, `templateId?` | 回寫結構化資料 |
| `list_templates` | — | 列出情境樣板 |
| `get_template` | `id` | 取得樣板 |
| `upsert_template` | `id`, `name`, `description`, `sample`, `instructions?`, `keywords?`, `rules?` | 新增或更新情境 |
| `delete_template` | `id` | 刪除情境 |
| `classify_text` | `text`, `templateIds?` | 判斷情境：先比對強特徵，再用 Jev |
| `validate_data` | `templateId`, `data` | 檢查 JSON 是否符合樣板結構，回傳問題清單 |
| `vault_list`、`vault_read`、`vault_write`、`vault_search` | 見下方 | Obsidian 筆記，見「Vault（Obsidian 筆記）」 |

## Vault（Obsidian 筆記）

使用者的 Obsidian 筆記庫（vault）由社群插件 **Remotely Save**（S3 模式）同步到 Railway Storage Bucket（S3 相容，底層為 Tigris）。
伺服器直接讀寫同一個儲存桶裡的**一般檔案**：iPad App 與 Claude（MCP）寫入的檔案，會在 Remotely Save 下一次同步時出現在所有裝置上，反之亦然。
裝置端設定步驟見 [OBSIDIAN-SYNC.md](OBSIDIAN-SYNC.md)。

- 物件鍵 = `VAULT_PREFIX` + vault 內路徑。`VAULT_PREFIX` 預設空白，必須與 Remotely Save 的 Remote prefix 一致。
- 寫入時與 Remotely Save 一樣設定物件中繼資料 `MTime`、`CTime`（秒，字串浮點數，例如 `"1760000000.123"`）；讀取時優先使用 `MTime`（相容舊版以毫秒儲存的值），沒有時用 `LastModified`。
- 伺服器未設定 `VAULT_S3_*` 時，除了 `GET /v1/vault/status` 之外的端點與 `vault_*` 工具都回傳 503 `vault_not_configured`。
- Remotely Save **不可**開啟端對端加密，否則儲存桶裡只有加密檔，App 與 Claude 無法讀取。
- 儲存桶沒有版本控制，覆寫與刪除都無法復原。

### 路徑

`path` 是相對於 vault 根目錄的檔案路徑，例如 `Daily/2026-10-13.md`、`Inbox/想法.md`。伺服器先做 Unicode NFC 正規化（找不到檔案時再試 NFD 寫法，相容 macOS 上傳的檔名），下列情況回傳 400 `invalid_path`：

- 空字串或未提供
- 以 `/` 開頭，或（檔案路徑）以 `/` 結尾
- 含 `.` 或 `..` 段落、空段落（`//`）
- 反斜線 `\`、控制字元（U+0000–U+001F、U+007F）
- UTF-8 超過 1024 位元組

`prefix`（資料夾）可省略或空白（根目錄），或是資料夾路徑，例如 `Daily/`；沒有結尾 `/` 時自動補上，其餘規則同上。

### VaultEntry

```json
{ "path": "Daily/2026-10-13.md", "size": 1834, "mtime": 1760000000123, "etag": "5d41402abc4b2a76b9719d911017c592" }
```

| 欄位 | 說明 |
| --- | --- |
| `path` | 相對於 vault 根目錄 |
| `size` | 位元組數 |
| `mtime` | 毫秒（Unix epoch）。**列表**中是儲存桶的上傳時間（`LastModified`，ListObjects 不含中繼資料）；`GET /v1/vault/file` 的 `X-Vault-Mtime` 與寫入回應則是 `MTime` 中繼資料 |
| `etag` | 不含引號的 etag；寫入或刪除時放在 `If-Match` 做樂觀鎖 |

### 端點

所有端點都需要 API 金鑰（同其他 `/v1` 端點）。

| 方法與路徑 | 說明 |
| --- | --- |
| `GET /v1/vault/status` | `{"configured":true,"prefix":""}`；一律 200（未設定時 `configured` 為 `false`） |
| `GET /v1/vault/files?prefix=&recursive=` | 列出檔案，`items` 依 `path` 排序。`recursive=false`（預設）只列出這一層，並回傳子資料夾 `folders`（相對於根目錄、以 `/` 結尾，例如 `["Daily/","Inbox/"]`）；`recursive=true` 列出底下所有檔案，回傳中**沒有** `folders`。`recursive` 接受 `true`／`false`／`1`／`0`。資料夾標記物件（以 `/` 結尾的鍵）不會出現在 `items`。回傳 `{"items":[VaultEntry...],"folders":[...]}` |
| `GET /v1/vault/file?path=` | 下載原始位元組。回應標頭：`Content-Type`（依副檔名）、`ETag`（含引號，例如 `"5d41…"`）、`Last-Modified`、`X-Vault-Mtime`（毫秒）。不存在時 404 `not_found` |
| `PUT /v1/vault/file?path=` | 以請求本文（原始位元組，任何 Content-Type 都原樣儲存，最多 25 MB）新增或整檔取代。選用標頭：`If-Match`、`If-None-Match: *`、`X-Vault-Mtime`（毫秒，預設為現在）。新增回傳 **201**、覆寫回傳 **200**，本文為 `{"path","size","mtime","etag"}`，並附 `ETag` 標頭 |
| `DELETE /v1/vault/file?path=` | 刪除，回傳 204；選用 `If-Match`。不存在時 404 `not_found`（不論是否帶 `If-Match`） |
| `GET /v1/vault/search?q=&prefix=&limit=` | 在 `.md`、`.txt`、`.json`、`.canvas` 檔案中比對檔名與內容（不分大小寫，`q` 為一般文字而非正規表示式），略過 `.obsidian` 等以 `.` 開頭的資料夾與檔案。依 `mtime` 由新到舊，最多檢查最新的 3000 個檔案，超過 1 MB 的檔案只比對檔名。`limit` 預設 20、上限 100。回傳 `{"items":[{"path","mtime","snippet"}]}`，`snippet` 是第一個內容符合處前後約 120 字（只有檔名符合時為檔案開頭；空白會合併、截斷處加 `…`） |

`Content-Type` 對照（`GET` 回應與寫入儲存桶時使用）：

| 副檔名 | Content-Type |
| --- | --- |
| `.md` | `text/markdown; charset=utf-8` |
| `.txt` | `text/plain; charset=utf-8` |
| `.json`、`.canvas` | `application/json` |
| `.png`、`.jpg`／`.jpeg`、`.gif`、`.webp`、`.heic` | `image/png`、`image/jpeg`、`image/gif`、`image/webp`、`image/heic` |
| `.pdf` | `application/pdf` |
| 其他 | `application/octet-stream` |

`ETag`、`Last-Modified`、`X-Vault-Mtime` 已列在 CORS `Access-Control-Expose-Headers`。

### 樂觀鎖（避免覆寫其他裝置的修改）

1. `GET /v1/vault/file?path=…`，記下 `ETag`。
2. 修改後 `PUT` 並帶 `If-Match: "<etag>"`。如果檔案在這之間被 Remotely Save 或其他客戶端更新（或已被刪除），回傳 412：

   ```json
   { "error": { "code": "precondition_failed", "message": "File has changed since it was read (etag mismatch)", "currentEtag": "9a0364b9e99bb480dd25e1f0284c8555" } }
   ```

   `currentEtag` 是目前的 etag（檔案不存在時為 `null`）。客戶端應重新讀取、合併後再寫入。
3. 只想新增、不想覆寫既有檔案時帶 `If-None-Match: *`：檔案已存在就回傳 412（同樣附 `currentEtag`）。

- `If-Match` 接受 `"etag"`、`etag`、`W/"etag"`、逗號分隔的清單，或 `*`（檔案必須存在）。
- 儲存桶不支援條件式寫入，伺服器是「先 HEAD 比對、再 PUT」，兩者之間仍有極短的競爭窗口。
- Remotely Save 本身不檢查 etag；同一份筆記同時在 Obsidian 與 App 修改時，由 Remotely Save 的衝突處理設定決定保留哪一份。

### 錯誤碼

錯誤格式同其他端點：`{"error":{"code","message"}}`（412 另含 `currentEtag`）。

| HTTP | `code` | 說明 |
| --- | --- | --- |
| 400 | `invalid_path` | `path` 或 `prefix` 不合法（見「路徑」） |
| 400 | `invalid_request` | `recursive`、`q`、`limit` 或 `X-Vault-Mtime`（須為正整數毫秒）格式錯誤 |
| 401 | `unauthorized` | 缺少或錯誤的 API 金鑰 |
| 404 | `not_found` | 檔案不存在 |
| 412 | `precondition_failed` | `If-Match`／`If-None-Match` 不成立；含 `currentEtag` |
| 413 | `payload_too_large` | 上傳超過 25 MB |
| 502 | `vault_storage_error` | 儲存桶請求失敗（金鑰、bucket 名稱、網路），訊息含 S3 錯誤名稱，例如 `AccessDenied`、`SignatureDoesNotMatch` |
| 503 | `vault_not_configured` | 伺服器未設定 `VAULT_S3_*` |

### MCP 工具

| 工具 | 參數 | 說明 |
| --- | --- | --- |
| `vault_list` | `prefix?`, `recursive?`（預設 `false`） | 同 `GET /v1/vault/files` |
| `vault_read` | `path` | 文字檔回傳兩段內容：第一段 JSON `{"path","size","mtime","etag","contentType"}`，第二段是檔案原文。圖片、PDF、含 NUL 或非 UTF-8 的檔案回傳 `{…, "binary": true}`，超過 1 MB 回傳 `{…, "tooLarge": true}`，都不含內容 |
| `vault_write` | `path`, `content`, `ifMatch?`, `createOnly?` | 以 UTF-8 文字整檔寫入（`mtime` 為現在）；`ifMatch` 同 `If-Match`，`createOnly: true` 同 `If-None-Match: *`。回傳 VaultEntry 加上 `created` |
| `vault_search` | `query`, `prefix?`, `limit?` | 同 `GET /v1/vault/search` |

刻意**不提供刪除工具**，避免代理誤刪筆記。工具說明要求 Claude：這些是使用者經 Remotely Save 同步的 Markdown 筆記；修改前先 `vault_read`，保留 frontmatter 與既有內容，寫入時帶 `ifMatch`（讀取時的 etag），新增筆記用 `createOnly`。

### 伺服器環境變數

`VAULT_S3_ENDPOINT`、`VAULT_S3_BUCKET`、`VAULT_S3_ACCESS_KEY_ID`、`VAULT_S3_SECRET_ACCESS_KEY` 四個都有值時才啟用 Vault；只設定部分時伺服器會記錄缺少的變數名稱（不會記錄值）。金鑰不會出現在任何回應或紀錄中。

| 變數 | 預設 | Railway 參照（儲存桶名為 `obsidian-vault` 時） |
| --- | --- | --- |
| `VAULT_S3_ENDPOINT` | — | `${{obsidian-vault.ENDPOINT}}`（例如 `https://t3.storageapi.dev`） |
| `VAULT_S3_BUCKET` | — | `${{obsidian-vault.BUCKET}}`（顯示名稱加雜湊，例如 `obsidian-vault-jdhhd8oe18xi`） |
| `VAULT_S3_REGION` | `auto` | `${{obsidian-vault.REGION}}` |
| `VAULT_S3_ACCESS_KEY_ID` | — | `${{obsidian-vault.ACCESS_KEY_ID}}` |
| `VAULT_S3_SECRET_ACCESS_KEY` | — | `${{obsidian-vault.SECRET_ACCESS_KEY}}` |
| `VAULT_S3_FORCE_PATH_STYLE` | `false` | 只有儲存桶 Credentials 分頁註明使用 path-style 時才設為 `true` |
| `VAULT_PREFIX` | 空白 | 與 Remotely Save 的 Remote prefix 相同；有值時必須以 `/` 結尾（例如 `vault/`），否則伺服器拒絕啟動 |

## Jev 分類

伺服器以 `JEV_API_KEY`（亦接受 `TYPESAFE_API_KEY`）呼叫 TypeSafe AI 的 `POST https://api.typesafe.ai/v1/systemone`：

```json
{
  "model": "jev-latest",
  "state": { "document": "<OCR 全文，最多 8000 字>" },
  "questions": {
    "template": {
      "type": "choice",
      "instructions": "這份文件屬於哪一種情境？",
      "criteria": { "receipt": "購物收據、統一發票…", "document": "一般文件…" }
    }
  }
}
```

回應中的 `answers.template.choice`、`confidence`、`probabilities` 對應到 `/v1/classify` 的回傳。金鑰只放在伺服器，不可放進 App。
