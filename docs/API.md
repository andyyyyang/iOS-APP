# LocalOCR 共用資料格式與 API 規格

本文件是 iPhone App、Railway 伺服器、Obsidian 插件、Claude Code 插件與任何自建 harness 之間的唯一約定。
所有元件都依這份規格實作；擴充時（新增情境、欄位、工具）請先更新本文件。

## 架構

```
iPhone App ──(OCR：Vision，裝置端)──▶ 文字
   │  分類：Jev（經伺服器）→ 裝置端 Foundation Models → 關鍵字
   │  抽取：Foundation Models（裝置端）依樣板輸出 JSON
   ▼
Railway 伺服器（/v1 REST、/mcp MCP、Postgres）
   ├── Obsidian 插件：增量同步成筆記
   ├── Claude Code 插件／任何 MCP 客戶端：MCP 工具
   └── 自建 harness：REST + OpenAPI（/v1/openapi.json）
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
| `keywords` | 選用；離線時的關鍵字分類備援 |
| `sample` | **輸出樣式的範例 JSON**：輸出會有相同的欄位、巢狀結構、陣列形式與欄位順序。字串、數字、布林、陣列（以第一個元素為格式）、物件、`null`（代表可為空的字串）皆可 |
| `instructions` | 選用；額外的抽取規則 |
| `version` | 伺服器每次更新自動加一 |
| `updatedAt` | 伺服器設定，ISO 8601 |

`sample` 的欄位順序必須保留：伺服器以文字儲存原始 JSON（不可用 Postgres `jsonb`，它會重排鍵值）。

內建樣板：`receipt`（收據／發票）、`business_card`（名片）、`event`（活動／海報）、`document`（一般文件，作為無法判斷時的預設）。

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
| `POST /v1/classify` | 請求 `{"text":"...","templateIds":["receipt","document"]}`（`templateIds` 選用，預設全部樣板）。回傳 `{"templateId":"receipt","confidence":0.93,"probabilities":{...},"provider":"jev"}`。未設定 Jev 金鑰時回傳 503 `jev_not_configured`，客戶端應改用其他分類器 |
| `GET /v1/openapi.json` | OpenAPI 3.1 規格，供自建 harness 產生客戶端 |

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
| `upsert_template` | `id`, `name`, `description`, `sample`, `instructions?`, `keywords?` | 新增或更新情境 |
| `delete_template` | `id` | 刪除情境 |
| `classify_text` | `text`, `templateIds?` | 用 Jev 判斷情境 |
| `validate_data` | `templateId`, `data` | 檢查 JSON 是否符合樣板結構，回傳問題清單 |

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
