# LocalOCR 伺服器

LocalOCR iPhone App 的後端：REST API（`/v1`）、MCP（`/mcp`）與 Postgres 儲存。
資料格式與 API 約定以 [`../docs/API.md`](../docs/API.md) 為準；本文件只說明伺服器的執行與擴充方式。

- Node.js 22、TypeScript（strict、ESM）、Express 5
- MCP：`@modelcontextprotocol/sdk`，Streamable HTTP、**無狀態**（每個請求建立新的 server + transport，可水平擴充）
- 驗證：zod；資料庫：Postgres（`pg`，全部使用參數化查詢）
- 分類：Jev（`@typesafe-ai/sdk`），放在 `Classifier` 介面後面，可替換或新增其他供應商

## 端點

除了 `GET /health`，所有端點都需要 API 金鑰：`Authorization: Bearer <API_KEY>`，或查詢參數 `?api_key=<API_KEY>`（網址可能被記錄，僅在無法設定標頭時使用）。
錯誤一律回傳 `{"error":{"code":"...","message":"..."}}`。

| 方法與路徑 | 說明 |
| --- | --- |
| `GET /health` | `{"status":"ok","version":"1.0.0","database":"postgres","jev":true}`；`database` 為 `postgres` 或 `memory`，`jev` 表示伺服器端分類是否可用 |
| `PUT /v1/scans/{id}` | 新增（201）或更新（200）掃描，冪等。`id` 為 UUID（不分大小寫，儲存為大寫）。`updatedAt` 由伺服器設定；`createdAt` 以第一次寫入為準，之後不會改變 |
| `GET /v1/scans` | 列表：`limit`（預設 50，上限 200）、`templateId`、`q`（全文搜尋，不分大小寫）、`updatedAfter`（ISO 8601）、`cursor`。回傳 `{"items":[...],"nextCursor":...}` |
| `GET /v1/scans/{id}` | 取得單筆 |
| `PATCH /v1/scans/{id}` | 局部更新 `templateId`、`data`、`classification`（至少一項；`null` 代表清除） |
| `DELETE /v1/scans/{id}` | 刪除，回傳 204 |
| `GET /v1/templates` | `{"items":[Template...]}`（依建立順序） |
| `GET /v1/templates/{id}` | 取得單一樣板 |
| `PUT /v1/templates/{id}` | 新增（201）或整筆取代（200）樣板，`version` 自動加一 |
| `DELETE /v1/templates/{id}` | 刪除，回傳 204 |
| `POST /v1/classify` | `{"text":"...","templateIds":[...]}` → `{"templateId","confidence","probabilities","provider"}`；未設定 Jev 時回傳 503 `jev_not_configured` |
| `POST /v1/validate` | `{"templateId":"receipt","data":{...}}` → `{"valid":false,"issues":[{"path":"$.items[0].price","message":"..."}]}`（REST 版的 `validate_data`） |
| `GET /v1/openapi.json` | OpenAPI 3.1 規格，供自建 harness 產生客戶端 |
| `POST /mcp` | MCP Streamable HTTP（無狀態；`GET`／`DELETE /mcp` 回傳 405） |

### 增量同步（Obsidian 插件、harness）

1. 第一次同步：`GET /v1/scans?updatedAfter=1970-01-01T00:00:00Z&limit=200`。
2. 只要 `nextCursor` 不是 `null`，就帶 `?cursor=<nextCursor>` 取下一頁（結果依 `(updatedAt, id)` 由舊到新）。
3. 最後一頁的最後一筆 `updatedAt` 記為水位，下次同步用 `?updatedAfter=<水位>`。

伺服器每次寫入都從單一時鐘取得嚴格遞增的 `updatedAt`（Postgres 以 `write_clock` 列鎖確保順序與提交順序一致），所以不會漏掉或重複。
不帶 `updatedAfter`／`cursor` 時依 `createdAt` 由新到舊排序，`nextCursor` 也可用來翻頁。
注意：刪除不會出現在增量同步中。

### MCP 工具

`list_scans`、`get_scan`、`update_scan_data`、`list_templates`、`get_template`、`upsert_template`、`delete_template`、`classify_text`、`validate_data`。
工具結果是格式化的 JSON 文字；失敗時 `isError: true`，內容為 `{"error":{"code","message"}}`。
`list_scans` 另外接受選用的 `cursor` 參數以翻頁。

## 環境變數

| 變數 | 必填 | 說明 |
| --- | --- | --- |
| `API_KEYS` | 是 | API 金鑰，逗號分隔可放多把（方便替換、分發給不同裝置）。空白時伺服器拒絕啟動，除非 `NODE_ENV=test` 或 `ALLOW_NO_AUTH=1`（此時所有端點不需驗證，僅供本機開發） |
| `DATABASE_URL` | 建議 | Postgres 連線字串（Railway 的 Postgres 服務會提供）。未設定時使用記憶體儲存，重啟即遺失 |
| `JEV_API_KEY` | 否 | Jev（TypeSafe AI）金鑰；亦接受 `TYPESAFE_API_KEY`。未設定時 `/v1/classify` 回傳 503，App 應改用裝置端分類 |
| `JEV_MODEL` | 否 | Jev 模型，預設 `jev-latest` |
| `PORT` | 否 | 監聽埠，預設 `3000`（Railway 自動注入）；監聽 `0.0.0.0` |

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

啟動時會自動執行資料庫遷移（`schema_migrations` 記錄已套用的版本，多個實例同時啟動時以 advisory lock 排隊），並補上缺少的內建樣板（`receipt`、`business_card`、`event`、`document`）。已存在的樣板不會被覆寫；刪除的內建樣板會在下次啟動時補回。

### 測試

```sh
npm test          # vitest + supertest，使用記憶體儲存與假分類器，不連網路
npm run typecheck
npm run build

# 以真實 Postgres 執行整套測試（會刪除資料表，請用拋棄式資料庫！）
TEST_DATABASE_URL=postgres://user:pass@localhost:5432/localocr_test npm test
```

### 部署到 Railway

`railway.json` 已設定：建置 `npm ci && npm run build`、啟動 `npm start`、健康檢查 `/health`。
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

`PUT`／`upsert_template` 是整筆取代：沒帶的 `keywords`、`instructions` 會被清空。每次更新 `version` 加一。

若要新增**內建**樣板（每個新部署都會有），在 `src/templates/builtin.ts` 加一筆即可，啟動時只會在缺少時插入。

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
  bootstrap.ts        遷移 + 補內建樣板
  schemas.ts          zod 輸入格式（REST 與 MCP 共用）
  validate.ts         依樣板 sample 檢查 JSON 結構
  cursor.ts           不透明分頁游標
  store/              Store 介面、PostgresStore（含 migrations.ts）、MemoryStore
  services/           商業邏輯：scans、templates、classify、validate
  classifier/         Classifier 介面與 Jev 實作
  templates/builtin.ts 內建樣板
  http/               createApp、驗證、錯誤處理、路由、OpenAPI
  mcp/                MCP 工具與無狀態 /mcp 路由
test/                 vitest + supertest
```

資料庫結構變更：在 `src/store/migrations.ts` 的 `MIGRATIONS` 陣列尾端加入下一個版本號的遷移，不要修改已發佈的遷移。
