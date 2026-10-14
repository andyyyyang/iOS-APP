# LocalOCR 伺服器

LocalOCR iPhone App 的後端：REST API（`/v1`）、MCP（`/mcp`）與 Postgres 儲存。
資料格式與 API 約定以 [`../docs/API.md`](../docs/API.md) 為準；本文件只說明伺服器的執行與擴充方式。

- Node.js 22、TypeScript（strict、ESM）、Express 5
- MCP：`@modelcontextprotocol/sdk`，Streamable HTTP、**無狀態**（每個請求建立新的 server + transport，可水平擴充）
- 驗證：zod；資料庫：Postgres（`pg`，全部使用參數化查詢）
- 分類：Jev（`@typesafe-ai/sdk`），放在 `Classifier` 介面後面，可替換或新增其他供應商

## 端點

除了 `GET /health`、`POST /pair`、`GET /obsidian-plugin/*` 與 WebSocket `GET /v1/vault/stream`（以第一個訊息驗證），所有端點都需要 API 金鑰：`Authorization: Bearer <API_KEY>`，或查詢參數 `?api_key=<API_KEY>`（網址可能被記錄，僅在無法設定標頭時使用）。
錯誤一律回傳 `{"error":{"code":"...","message":"..."}}`。

| 方法與路徑 | 說明 |
| --- | --- |
| `GET /health` | `{"status":"ok","version":"1.0.0","database":"postgres","jev":true,"assistant":true}`；`database` 為 `postgres` 或 `memory`，`jev` 表示伺服器端分類是否可用，`assistant` 表示雲端 AI 是否可用（需要 `ANTHROPIC_API_KEY` 與 vault） |
| `PUT /v1/scans/{id}` | 新增（201）或更新（200）掃描，冪等。`id` 為 UUID（不分大小寫，儲存為大寫）。`updatedAt` 由伺服器設定；`createdAt` 以第一次寫入為準，之後不會改變 |
| `GET /v1/scans` | 列表：`limit`（預設 50，上限 200）、`templateId`、`q`（全文搜尋，不分大小寫）、`updatedAfter`（ISO 8601）、`cursor`。回傳 `{"items":[...],"nextCursor":...}` |
| `GET /v1/scans/{id}` | 取得單筆 |
| `PATCH /v1/scans/{id}` | 局部更新 `templateId`、`data`、`classification`（至少一項；`null` 代表清除） |
| `DELETE /v1/scans/{id}` | 刪除，回傳 204 |
| `GET /v1/templates` | `{"items":[Template...]}`（依建立順序）；每個樣板都有 `rules` 陣列（沒有規則時為 `[]`） |
| `GET /v1/templates/{id}` | 取得單一樣板 |
| `PUT /v1/templates/{id}` | 新增（201）或整筆取代（200）樣板，`version` 自動加一；`rules` 一併取代（省略代表清空） |
| `DELETE /v1/templates/{id}` | 刪除，回傳 204 |
| `POST /v1/classify` | `{"text":"...","templateIds":[...]}` → `{"templateId","confidence","probabilities","provider"}`；未設定 Jev 時回傳 503 `jev_not_configured` |
| `POST /v1/validate` | `{"templateId":"receipt","data":{...}}` → `{"valid":false,"issues":[{"path":"$.items[0].price","message":"..."}]}`（REST 版的 `validate_data`） |
| `POST /v1/assistant/route` | `{"text","context"?,"budget"?:"low\|medium\|high","deviceAvailable"?}` → `{"kind":"question\|edit\|task","route":"device\|cloud","confidence","provider":"jev\|heuristic","cloudAvailable"}`；有 `budget` 時另外回傳 `difficulty`（simple/moderate/hard）、`tier`（device/small/medium/large）、`model`、`effort`：判斷聊天要求在裝置上處理，還是交給哪一級的雲端模型 |
| `POST /v1/assistant/runs` | 開始雲端 AI 工作 `{"prompt","history"?,"rulesPath"?,"openNote"?,"transcriptPath"?,"timeZone"?}` → 202 `{"id","status":"running","model"}`；未設定 `ANTHROPIC_API_KEY` 時 503 `assistant_not_configured` |
| `GET /v1/assistant/runs/{id}?after=&wait=` | 工作狀態與 `after` 之後的事件（長輪詢，`wait` 最多 25 秒）`{"id","status","model","events","answer","error","sources","edits","usage"}` |
| `POST /v1/assistant/runs/{id}/cancel`／`/undo` | 取消工作 → `{"status"}`；復原修改 `{"editIds"?}` → `{"undone":[...],"failed":[{"id","reason"}]}` |
| `GET /v1/openapi.json` | OpenAPI 3.1 規格，供自建 harness 產生客戶端 |
| `GET /v1/vault/status` | `{"configured":true,"prefix":""}`：Obsidian 筆記庫（儲存桶）是否已設定 |
| `GET /v1/vault/files?prefix=&recursive=` | 列出 vault 檔案 `{"items":[{"path","size","mtime","etag"}],"folders":[...]}`（`folders` 只在非遞迴時回傳） |
| `GET`／`PUT`／`DELETE /v1/vault/file?path=` | 下載／上傳（原始位元組，最多 25 MB；`If-Match`、`If-None-Match: *`、`X-Vault-Mtime`）／刪除單一檔案 |
| `GET /v1/vault/search?q=&prefix=&limit=` | 搜尋筆記檔名與內容 `{"items":[{"path","mtime","snippet"}]}` |
| `GET /v1/vault/index` | 所有筆記的標題、aliases、tags、連結、第一個嵌入、待辦、摘要、`localocr-notebook` 與屬性（`properties`，frontmatter 的值：文字、文字清單或 null；App 的 DataviewJS 用來當頁面欄位），以及其他檔案 `{"version":1,"notes":[...],"files":[...]}`；支援 `ETag`／`If-None-Match`（304）與 gzip，筆記的 etag 沒變就不重新讀取 |
| `GET /v1/vault/changes?since=&wait=` | 變更通知（長輪詢，`wait` 最多 25 秒）：經伺服器的寫入／刪除與裝置回報的變更 `{"cursor","reset","changes":[{"seq","path","op","client","at"}]}`；`X-LocalOCR-Client` 標頭相同的變更不列出 |
| `POST /v1/vault/changes` | 回報裝置自己上傳到儲存桶的檔案 `{"paths"?:[...]}` → 202 `{"cursor"}`（Obsidian 插件在 Remotely Save 上傳後呼叫） |
| `GET /v1/vault/stream`（WebSocket） | 即時推送變更（取代長輪詢，見下方「Vault 即時推送」）：第一個訊息 `{"type":"auth","token","client","since"?}` → `{"type":"ready","cursor","reset"}`，之後其他用戶端的變更即時送來 `{"type":"changes","cursor","reset":false,"changes":[...]}` |
| `GET /v1/vault/remotely-save?vault=` | Remotely Save 的 S3 設定（含儲存桶金鑰）與匯入用的 `obsidian://remotely-save?…` 網址 `{"settings":{...},"uri":"..."}`；未設定 vault 時 503 `vault_not_configured` |
| `POST /v1/pairing` | 建立配對碼（`XXXX-XXXX`，10 分鐘、只能用一次）：`{"vaultName"?,"notesFolder"?}` → 201 `{"code","expiresAt","pairUrl"}` |
| `POST /pair` | **不需要金鑰**：`{"code":"XXXX-XXXX"}` → `{"apiKey","vaultName","notesFolder"}`；無效／過期／已用過 404 `invalid_code`；每個 IP 每 10 分鐘最多 10 次，超過 429 `rate_limited` |
| `GET /obsidian-plugin/latest.json` | **不需要金鑰**：最新的 Obsidian 插件版本 `{"version","minAppVersion","notes","publishedAt","files":{"main.js":{"sha256","size","url"},"manifest.json":{...}}}`（`url` 為絕對網址）；還沒有同步任何版本 404 `not_found`，未設定 vault 503 `vault_not_configured` |
| `GET /obsidian-plugin/releases/{version}/{file}` | **不需要金鑰**：插件檔案（`file` 為 `main.js` 或 `manifest.json`），`ETag` 為 SHA-256、可長期快取；儲存桶中的檔案與資料庫紀錄的 SHA-256 不符時 502 `integrity_error` |
| `GET /obsidian-plugin/latest/{file}` | **不需要金鑰**：最新版本的插件檔案（第一次手動安裝的下載連結） |
| `POST /v1/obsidian-plugin/refresh` | 立即從 GitHub Releases 同步插件新版本 → `{"latest","mirrored":[...],"repaired":[...],"failed":[{"version","error"}]}`；GitHub 失敗 502 `github_unavailable` |
| `POST /mcp` | MCP Streamable HTTP（無狀態；`GET`／`DELETE /mcp` 回傳 405） |

### 增量同步（Obsidian 插件、harness）

1. 第一次同步：`GET /v1/scans?updatedAfter=1970-01-01T00:00:00Z&limit=200`。
2. 只要 `nextCursor` 不是 `null`，就帶 `?cursor=<nextCursor>` 取下一頁（結果依 `(updatedAt, id)` 由舊到新）。
3. 最後一頁的最後一筆 `updatedAt` 記為水位，下次同步用 `?updatedAfter=<水位>`。

伺服器每次寫入都從單一時鐘取得嚴格遞增的 `updatedAt`（Postgres 以 `write_clock` 列鎖確保順序與提交順序一致），所以不會漏掉或重複。
不帶 `updatedAfter`／`cursor` 時依 `createdAt` 由新到舊排序，`nextCursor` 也可用來翻頁。
注意：刪除不會出現在增量同步中。

配對碼存在記憶體中（伺服器只有一個實例；重新啟動後未使用的配對碼失效），只會交出建立配對碼時所用的那把 API 金鑰。配對與 Remotely Save 設定的回應都帶 `Cache-Control: no-store`，金鑰不會寫入紀錄。

### Vault 即時推送（WebSocket `GET /v1/vault/stream`）

與 REST 同一個連接埠（`index.ts` 在 `app.listen` 之後以 `attachVaultStream(server, app)` 接上 HTTP 伺服器的 `upgrade` 事件；其他路徑的升級請求直接斷線）。瀏覽器的 WebSocket 不能帶標頭，所以升級本身不需要金鑰，改由第一個訊息驗證：

1. 用戶端在 10 秒內送 `{"type":"auth","token":"<API 金鑰>","client":"<用戶端代碼>","since":"<cursor，選用>"}`；逾時關閉 4401。金鑰錯誤回 `{"type":"error","code":"unauthorized"}` 並關閉 4401；未設定 vault 回 `{"type":"error","code":"vault_not_configured"}` 並關閉 4503。
2. 成功回 `{"type":"ready","cursor","reset"}`。帶 `since` 時與 `GET /v1/vault/changes?since=` 相同的規則（其他 epoch、太舊、無法辨識或變更太多 → `reset: true`），漏掉的其他用戶端變更緊接著以一個 `changes` 訊息送出。
3. 之後每筆變更（50 毫秒內的合併成一則）即時推送 `{"type":"changes","cursor","reset":false,"changes":[{"seq","path","op","client","at"}]}`；`client` 與這條連線相同的變更不送。
4. 用戶端可送 `{"type":"report","paths":[...]}`（自己上傳到儲存桶的檔案，同 `POST /v1/vault/changes`；無效路徑略過，沒有路徑或超過 100 個時記一筆 `path: null`）→ `{"type":"ack","cursor"}`，以及 `{"type":"ping"}` → `{"type":"pong"}`；其他訊息忽略。
5. 伺服器每 30 秒送 WebSocket ping，沒回應上一次 ping 的連線會被中斷；關機時以 1001 關閉所有連線。

變更紀錄在記憶體中（`services/vault-changes.ts`，長輪詢與推送共用）。iPad App 與 Obsidian 插件（1.5.0 起）優先使用推送；舊版伺服器沒有這個端點（升級回 404）時，插件改用長輪詢。

Vault 端點的完整規格（路徑規則、樂觀鎖、錯誤碼）見 [`../docs/API.md`](../docs/API.md) 的「Vault（Obsidian 筆記）」；裝置端的 Remotely Save 設定見 [`../docs/OBSIDIAN-SYNC.md`](../docs/OBSIDIAN-SYNC.md)。

### Obsidian 插件更新

插件（LocalOCR Sync）的線上更新來自本伺服器：有 vault 儲存桶時，伺服器在啟動 15 秒後、之後每 30 分鐘（以及 `POST /v1/obsidian-plugin/refresh`）讀取 GitHub Releases `obsidian-plugin-x.y.z`，把新版本的 `main.js`、`manifest.json` 驗證後（GitHub 的 SHA-256、`manifest.json` 的 `id` 與版本）存進儲存桶的隱藏資料夾 `.localocr/obsidian-plugin/<版本>/`，並把版本、更新內容與每個檔案的 SHA-256 寫進資料庫（資料表 `obsidian_plugin_releases`）。
儲存桶金鑰在每台裝置的 Remotely Save 裡，所以送出檔案前一定重新計算 SHA-256，與資料庫不符就拒絕；最新版本的檔案會在下次同步時修復。細節見 [`../docs/API.md`](../docs/API.md) 的「Obsidian 插件更新」。

### MCP 工具

`list_scans`、`get_scan`、`update_scan_data`、`list_templates`、`get_template`、`upsert_template`、`delete_template`、`classify_text`、`validate_data`，
以及 Obsidian 筆記的 `vault_list`、`vault_read`、`vault_write`、`vault_search`、`vault_links`（對外連結與反向連結，依 Obsidian 的方式解析；沒有刪除工具）。
工具結果是格式化的 JSON 文字；失敗時 `isError: true`，內容為 `{"error":{"code","message"}}`。
`list_scans` 另外接受選用的 `cursor` 參數以翻頁；`upsert_template` 接受選用的 `rules`（工具說明中列出支援的操作）。

### 雲端 AI（`/v1/assistant`）

App 首頁的 AI 對話：簡單的問題在裝置上處理，較難的要求由 `POST /v1/assistant/route` 判斷後交給伺服器上的 Claude（官方 `@anthropic-ai/sdk`，Messages API + 工具）。

**預算與模型分級**：App 帶上預算（低／中／高）時，Jev 一次判斷要求的種類（問答／小修改／多步驟工作）與難度（簡單／中等／困難），再依下表決定由誰處理；三個預算都自動選，而且都看難度，不會隨便用貴的模型。Jev 把握不到 0.5 時往便宜的一級算。雲端分三級：small＝最新 Haiku、medium＝最新 Sonnet、large＝最新 Opus（自動跟上新版本，見 `ASSISTANT_MODEL*`），思考程度（effort）隨難度 low／medium／high（低預算最多 medium）。手機不能用 Apple Intelligence 時，裝置端的工作改用 small。

| 預算 | 問答、小修改：簡單／中等／困難 | 多步驟工作：簡單／中等／困難 |
|---|---|---|
| 低（盡量用裝置端） | 裝置／裝置／small | 裝置／small／medium |
| 中 | 裝置／small／medium | small／medium／large |
| 高（難的用最好的模型） | 裝置／medium／large | medium／large／large |

不帶預算的舊版 App 維持原本的判斷（只有多步驟工作交給雲端，用 large）。
Claude 把 vault 當成電腦的檔案系統操作：`list_files`、`read_file`、`search_notes`、`get_links`、`write_file`（覆寫前必須先讀過）、`edit_file`（精確字串取代）、`move_file`（同時更新其他筆記的 `[[連結]]`）、`delete_file`（移到 `.trash/`），
以及 Anthropic 的程式沙盒（`code_execution_20260521`，產生的檔案用 `save_output` 存回 vault）與選用的網路搜尋。所有寫入的 client 都是 `assistant`，App 與 Obsidian 會從變更通知得知。
系統提示詞與工具定義使用提示快取；vault 根目錄的編輯規則（`AGENTS.md`、`CLAUDE.md`、`規則.md` 等，或 `rulesPath` 指定的檔案）會放進提示詞並要求遵守。
工作狀態只存在記憶體（24 小時）；`undo` 以 etag 檢查，修改後又被別人改過的檔案不會被覆蓋。指定 `transcriptPath` 時，每次工作結束後把這一輪（問題、回答、來源、修改）附加到該筆記。
測試以腳本化的假模型執行（`AssistantModel` 介面），不連網路。

## 環境變數

| 變數 | 必填 | 說明 |
| --- | --- | --- |
| `API_KEYS` | 是 | API 金鑰，逗號分隔可放多把（方便替換、分發給不同裝置）。空白時伺服器拒絕啟動，除非 `NODE_ENV=test` 或 `ALLOW_NO_AUTH=1`（此時所有端點不需驗證，僅供本機開發） |
| `DATABASE_URL` | 建議 | Postgres 連線字串（Railway 的 Postgres 服務會提供）。未設定時使用記憶體儲存，重啟即遺失 |
| `JEV_API_KEY` | 否 | Jev（TypeSafe AI）金鑰；亦接受 `TYPESAFE_API_KEY`。未設定時 `/v1/classify` 回傳 503，App 應改用裝置端分類 |
| `JEV_MODEL` | 否 | Jev 模型，預設 `jev-latest` |
| `PORT` | 否 | 監聽埠，預設 `3000`（Railway 自動注入）；監聽 `0.0.0.0` |
| `VAULT_S3_ENDPOINT`、`VAULT_S3_BUCKET`、`VAULT_S3_ACCESS_KEY_ID`、`VAULT_S3_SECRET_ACCESS_KEY` | 否 | Obsidian 筆記庫所在的 S3 相容儲存桶（Railway：`${{obsidian-vault.ENDPOINT}}`、`${{obsidian-vault.BUCKET}}`、`${{obsidian-vault.ACCESS_KEY_ID}}`、`${{obsidian-vault.SECRET_ACCESS_KEY}}`）。四個都有值才啟用，否則 vault 端點回傳 503 `vault_not_configured` |
| `VAULT_S3_REGION` | 否 | 預設 `auto` |
| `VAULT_S3_FORCE_PATH_STYLE` | 否 | 預設 `false`（virtual-hosted URL）；只有儲存桶註明 path-style 時才設 `true` |
| `VAULT_PREFIX` | 否 | 物件鍵前綴，需與 Remotely Save 的 Remote prefix 相同；預設空白，有值時必須以 `/` 結尾 |
| `PUBLIC_URL` | 否 | 伺服器的公開網址（例如 `https://xxx.up.railway.app`，結尾的 `/` 會移除），用於配對連結 `pairUrl` 與 `latest.json` 的檔案網址；未設定時取請求的網址（`X-Forwarded-Proto` + `Host`） |
| `GITHUB_TOKEN` | 否 | 同步插件版本時讀取 GitHub 版本清單用的權杖（只用來提高 API 次數上限，公開儲存庫不需要任何權限）；未設定時使用未驗證的請求（每小時 60 次，每 30 分鐘同步一次綽綽有餘） |
| `ANTHROPIC_API_KEY` | 否 | 雲端 AI（`/v1/assistant/runs`）用的 Anthropic API 金鑰；未設定時該功能關閉（503 `assistant_not_configured`，`/health` 的 `assistant` 為 `false`） |
| `ANTHROPIC_WORKSPACE_ID` | 否 | API key 不屬於任何 workspace（組織層級的 key）時必填：Anthropic Console → Settings → Workspaces 中的 workspace ID，伺服器會帶上 `anthropic-workspace-id`。`GET /health` 的 `assistantIssue` 會顯示 key 的問題 |
| `ASSISTANT_MODEL` | 否 | 雲端 AI 的模型。預設 `latest`：自動使用最新的 Opus（每 6 小時查一次開源模型目錄 [models.dev](https://github.com/sst/models.dev) 與 Anthropic Models API，只選這把金鑰叫得到、支援工具的模型；查不到時用 `claude-opus-5-5`）。`latest-sonnet`、`latest-haiku`、`latest-fable` 改用該系列的最新模型；填模型 ID（例如 `claude-opus-5-5`）則固定使用。目前使用的模型見 `GET /health` 的 `assistantModel`（各級見 `assistantModels`） |
| `ASSISTANT_MODEL_MEDIUM` | 否 | 中級雲端模型，預設 `latest-sonnet`（寫法同 `ASSISTANT_MODEL`） |
| `ASSISTANT_MODEL_SMALL` | 否 | 最便宜的雲端模型，預設 `latest-haiku`（寫法同 `ASSISTANT_MODEL`） |
| `ASSISTANT_MAX_TURNS` | 否 | 每個工作最多呼叫模型幾次，預設 `40` |
| `ASSISTANT_CODE_EXECUTION` | 否 | Anthropic 程式沙盒，預設開啟；`0` 關閉 |
| `ASSISTANT_WEB_SEARCH` | 否 | Anthropic 網路搜尋，預設關閉；`1` 開啟 |

參考 [`.env.example`](.env.example)。

## 本機執行

```sh
cd server
npm install

# 開發模式（tsx watch，記憶體儲存、不需金鑰）
ALLOW_NO_AUTH=1 npm run dev

# 正式模式
npm run build
API_KEYS=dev-key DATABASE_URL=postgres://user:pass@localhost:5432/localocr npm start
# 或：cp .env.example .env 編輯後執行 node --env-file=.env dist/index.js

curl localhost:3000/health
curl -H "Authorization: Bearer dev-key" localhost:3000/v1/templates
```

啟動時依序：

1. 執行資料庫遷移（`schema_migrations` 記錄已套用的版本，多個實例同時啟動時以 advisory lock 排隊）。
2. 補上缺少的內建樣板（`receipt`、`business_card`、`event`、`document`）。已存在的樣板不會被覆寫；刪除的內建樣板會在下次啟動時補回。
3. 同步 `templates/managed/*.json` 的受管理樣板（見下方「受管理的樣板」）。

步驟 2、3 在全域鎖內執行，多個實例同時啟動也只會建立／更新一次。開始監聽後，有 vault 儲存桶時另外排程 Obsidian 插件版本的同步（15 秒後一次，之後每 30 分鐘；失敗只記錄）。

### 測試

```sh
npm test          # vitest + supertest，使用記憶體儲存與假分類器，不連網路
npm run typecheck
npm run build

# 以真實 Postgres 執行整套測試（會刪除資料表，請用拋棄式資料庫！）
# 另外會執行只在 Postgres 上跑的測試：舊資料庫升級（遷移 2）與多實例同時啟動
TEST_DATABASE_URL=postgres://user:pass@localhost:5432/localocr_test npm test
```

測試會檢查 `templates/managed/` 裡每個檔案都是有效的樣板，壞掉的檔案在 CI 就會被發現。

### 部署到 Railway

Railway 服務設定：Root Directory `/server`、建置 `npm ci && npm run build`、啟動 `npm start`、健康檢查 `/health`（Railway 已不建議使用 `railway.json`，設定直接放在服務上）。
在 Railway 建立服務時將 Root Directory 設為 `server`，加入 Postgres 服務並設定 `DATABASE_URL`（引用 Postgres 的變數）、`API_KEYS`，需要時再設定 `JEV_API_KEY`。

## 新增情境（樣板）

情境是資料，不需要改程式。`sample` 是輸出 JSON 的範例：欄位、巢狀結構、陣列形式（以第一個元素為格式）與欄位順序都會被沿用；`null` 代表可為空的字串。伺服器以文字儲存原始 JSON，保留欄位順序（注意：JavaScript 會把像 `"1"`、`"2"` 這種整數字串鍵排到最前面，請避免用數字當鍵）。

透過 REST：

```sh
curl -X PUT https://<host>/v1/templates/menu \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{
    "name": "菜單",
    "description": "餐廳或飲料店菜單，含品名與價格",
    "keywords": ["菜單", "價目表", "套餐"],
    "sample": {"shop": "範例小館", "items": [{"name": "牛肉麵", "price": 180}], "currency": "TWD"},
    "instructions": "價格使用數字；找不到的欄位填 null。"
  }'
```

透過 MCP（例如在 Claude Code 中直接說「新增一個菜單情境」），會呼叫 `upsert_template`：

```json
{ "id": "menu", "name": "菜單", "description": "餐廳或飲料店菜單，含品名與價格",
  "sample": { "shop": "範例小館", "items": [{ "name": "牛肉麵", "price": 180 }], "currency": "TWD" },
  "keywords": ["菜單", "價目表"], "instructions": "價格使用數字。" }
```

`PUT`／`upsert_template` 是整筆取代：沒帶的 `keywords`、`instructions`、`rules` 會被清空。每次更新 `version` 加一。

若要新增**內建**樣板（每個新部署都會有），在 `src/templates/builtin.ts` 加一筆即可，啟動時只會在缺少時插入。
若希望樣板內容由 repo 控管（修改後重新部署就生效），改用下方的受管理樣板。

### 後處理規則（`rules`）

`rules` 是選用的陣列（最多 100 條），App 等客戶端在 AI 抽取完 JSON 後依序套用，做確定性的補值與計算。**伺服器只負責驗證、儲存與回傳，不會執行規則。**

- 每條規則是一個 JSON 物件，必須有字串 `set`：目標路徑，格式為 `field` 或 `array[].field`（對陣列每個元素套用）。
- 其他鍵為自由格式的 JSON，伺服器不檢查；目前客戶端支援的操作：

| 操作 | 範例 | 說明 |
| --- | --- | --- |
| `value` | `{"set":"currency","value":"TWD"}` | 固定值（任何 JSON） |
| `copy` | `{"set":"expenseAmount","copy":"amount"}` | 複製另一個欄位 |
| `template` | `{"set":"text","template":"出口/{osat}/{caseNo}"}` | 字串模板，`{field}` 代入欄位值 |
| `sum` | `{"set":"total","sum":["items[].price"]}` | 加總（路徑陣列） |
| `join` | `{"set":"names","join":"items[].name","separator":"、"}` | 以分隔字串串接 |
| `divide` | `{"set":"price","divide":["amount","qty"],"round":3}` | 相除，`round` 為小數位數 |
| `today` | `{"set":"date","today":true}` | 今天日期（YYYY-MM-DD） |
| `generate` | `{"set":"id","generate":"base36time"}` | 產生以時間為基礎的 base36 代碼 |
| `lookup` | `{"set":"items[].category","lookup":"name","table":{"鮮乳":"飲品"}}` | 以欄位值查對照表 |
| `onlyIfEmpty` | `{"set":"date","today":true,"onlyIfEmpty":true}` | 只在目標欄位為空時套用（可與任何操作並用） |

規則以原始 JSON 文字儲存（Postgres `templates.rules TEXT`，由遷移 2 新增），陣列順序與物件鍵順序都會保留。驗證失敗（不是陣列、超過 100 條、缺少 `set`、`set` 不是字串或路徑格式不對）回傳 400 `invalid_request`。

### 受管理的樣板（`templates/managed/`）

`server/templates/managed/*.json` 每個檔案是一個完整的樣板物件（`id`、`name`、`description`、`keywords`、`sample`、`instructions`、`rules`；`keywords`、`instructions`、`rules` 可省略）。這些檔案是一般 JSON，不經過編譯，會隨 `server/` 目錄一起部署。

每次啟動（內建樣板補齊之後）：

- 資料庫中沒有該 `id` → 建立（`version` 1）。
- `name`、`description`、`keywords`、`sample`（原始文字，含鍵順序）、`instructions`、`rules`（原始文字）任一不同 → 以檔案內容整筆取代，`version` 加一。
- 完全相同 → 不動。
- 檔案不是有效 JSON、不符合樣板格式或 `id` 與其他檔案重複 → 記錄錯誤並略過，伺服器照常啟動。

啟動紀錄會列出結果，例如：`[managed] templates: created fv60_air; updated fv60_sea; unchanged -`。

因為 repo 檔案是唯一來源，透過 API 或 MCP 修改受管理樣板只會維持到下次啟動；刪除也會在下次啟動時重建。要永久修改，請改檔案後重新部署。
目錄位置以編譯後程式的位置推算（`dist/templates/` 與 `src/templates/` 往上兩層的 `templates/managed/`），所以 `npm start`、`npm run dev` 與測試都能找到；測試使用 `test/fixtures/managed/`，可透過 `bootstrapStore(store, { managedTemplatesDir })` 指定其他目錄（`null` 代表停用）。

## 新增分類器供應商

1. 在 `src/classifier/` 新增實作 `Classifier` 介面的類別：

   ```ts
   import { ClassifierError, type Classifier, type ClassificationCandidate, type ClassifierResult } from "./types.js";

   export class MyClassifier implements Classifier {
     readonly provider = "my-provider";
     async classify(text: string, candidates: ClassificationCandidate[]): Promise<ClassifierResult> {
       // candidates: [{ id, name, description }]；回傳的 templateId 必須是其中之一
       // 上游失敗時 throw new ClassifierError("...")，會回傳 502 classifier_error
       return { templateId: candidates[0]!.id, confidence: 1, probabilities: {}, provider: this.provider };
     }
   }
   ```

2. 在 `src/config.ts` 加入所需的環境變數，並在 `src/classifier/index.ts` 的 `createClassifier` 中依設定回傳新的實作。
3. 測試時可直接把假的 `Classifier` 傳給 `createApp({ store, classifier, apiKeys })`（見 `test/helpers.ts`）。

REST 與 MCP 共用 `src/services/` 的同一套邏輯，新增供應商不需修改路由或工具。

## 連接 MCP 客戶端

Claude Code：

```sh
claude mcp add --transport http localocr https://<host>/mcp --header "Authorization: Bearer <key>"
```

其他支援 Streamable HTTP 的客戶端：URL 為 `https://<host>/mcp`，加上 `Authorization: Bearer <key>` 標頭；無法設定標頭時可用 `https://<host>/mcp?api_key=<key>`。

## 程式結構

```
src/
  index.ts            進入點：讀設定、建立 store／classifier、監聽、SIGTERM 優雅關閉
  config.ts           環境變數解析
  bootstrap.ts        遷移 + 補內建樣板 + 同步受管理樣板
  schemas.ts          zod 輸入格式（REST 與 MCP 共用）
  validate.ts         依樣板 sample 檢查 JSON 結構
  cursor.ts           不透明分頁游標
  store/              Store 介面、PostgresStore（含 migrations.ts）、MemoryStore
  services/           商業邏輯：scans、templates、classify、validate、vault、pairing（配對碼）、obsidian-plugin（插件版本同步與提供）
  classifier/         Classifier 介面與 Jev 實作
  assistant/          雲端 AI：路由判斷、Claude 工作迴圈、vault 工具、復原、對話紀錄
  vault/              VaultStore 介面、S3VaultStore（@aws-sdk/client-s3）、MemoryVaultStore、路徑驗證、Remotely Save 設定
  templates/builtin.ts 內建樣板
  templates/managed.ts 讀取並同步 templates/managed/*.json
  http/               createApp、驗證、錯誤處理、/pair 頻率限制、路由、OpenAPI、vault-stream.ts（WebSocket 即時推送）
  mcp/                MCP 工具與無狀態 /mcp 路由
templates/managed/    受管理樣板（repo 控管的 JSON 檔）
test/                 vitest + supertest（fixtures/managed/ 為測試用樣板檔）
```

資料庫結構變更：在 `src/store/migrations.ts` 的 `MIGRATIONS` 陣列尾端加入下一個版本號的遷移，不要修改已發佈的遷移。
