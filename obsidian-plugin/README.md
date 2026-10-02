# LocalOCR Sync（Obsidian 插件）

把 LocalOCR 伺服器上的掃描紀錄，增量同步成 Obsidian 保險庫裡的 Markdown 筆記：每筆掃描一則筆記，內含 YAML 屬性、依樣板抽取的結構化 JSON，以及（可選的）OCR 全文。

```
iPhone App ──上傳──▶ LocalOCR 伺服器（Railway） ──GET /v1/scans──▶ Obsidian（本插件）
```

API 規格見 [`../docs/API.md`](../docs/API.md)。

## 功能

- **增量同步**：只下載上次同步之後新增或修改的掃描；同步中斷後，下次會從中斷的那一頁繼續。
- **一筆掃描一則筆記**：依樣板分資料夾（可關閉），檔名為 `YYYY-MM-DD HHmm 標題.md`。
- **保留你的筆記**：更新時只覆寫插件產生的區塊與插件管理的屬性；你在區塊外寫的內容、自己加的屬性與標籤都會保留。
- **自動同步**：預設每 15 分鐘一次，也可以用指令、左側功能區圖示或點狀態列手動同步。
- 使用 Obsidian 的 `requestUrl` 連線，沒有 CORS 問題，**桌面版與行動版（iOS／Android）都能用**。

## 安裝

### 手動安裝

1. 在保險庫中建立資料夾 `<保險庫>/.obsidian/plugins/localocr-sync/`（`.obsidian` 是隱藏資料夾）。
2. 把本資料夾中的 **`main.js`** 與 **`manifest.json`** 複製進去（`main.js` 已建置好並納入版本控制，不需要自己編譯）。
3. 開啟 Obsidian →「設定」→「第三方外掛」（社群外掛），關閉「限制模式」，按重新整理後啟用 **LocalOCR Sync**。
4. 到插件設定填入伺服器網址與 API 金鑰，按「測試連線」。

行動版可以先在電腦上安裝，再用 Obsidian Sync、iCloud 等方式同步 `.obsidian/plugins/localocr-sync/` 資料夾到手機。

### 用 BRAT 安裝

[BRAT](https://github.com/TfTHacker/obsidian42-brat) 會讀取 GitHub 儲存庫**根目錄**的 `manifest.json`，再從對應版本號的 GitHub Release 下載 `main.js` 與 `manifest.json`。本插件放在 monorepo 的子資料夾中，因此要用 BRAT 時：

1. 把本資料夾的內容（至少 `main.js`、`manifest.json`、`versions.json`、`README.md`）放到一個獨立儲存庫的根目錄。
2. 建立標籤為 `1.0.0`（與 `manifest.json` 的 `version` 相同）的 GitHub Release，並把 `main.js` 與 `manifest.json` 上傳為附件。
3. 在 Obsidian 安裝並啟用 BRAT →「Add Beta plugin」→ 輸入該儲存庫（例如 `你的帳號/obsidian-localocr-sync`）。

## 設定

| 設定 | 預設 | 說明 |
| --- | --- | --- |
| 伺服器網址 | — | 例如 `https://xxx.up.railway.app`。結尾的 `/` 會自動移除；沒有寫 `https://` 時會自動補上 |
| API 金鑰 | — | 伺服器環境變數 `API_KEYS` 中的任一把金鑰，以 `Authorization: Bearer` 標頭送出（以密碼欄位顯示） |
| 目標資料夾 | `LocalOCR` | 筆記存放的資料夾，留空代表保險庫根目錄 |
| 依樣板建立子資料夾 | 開 | 依樣板名稱分資料夾（例如 `LocalOCR/收據／發票/`），沒有樣板的放在 `未分類` |
| 包含辨識文字 | 開 | 在筆記中加入「辨識文字」段落 |
| 自動同步間隔（分鐘） | `15` | `0` 表示關閉自動同步；開啟時，Obsidian 啟動後約 5 秒也會同步一次 |
| 測試連線 | — | 先呼叫 `GET /health`，再用 API 金鑰呼叫 `GET /v1/templates`，結果以通知顯示 |
| 重設同步進度 | — | 下次同步時重新下載全部掃描；已存在的筆記會原地更新，不會重複建立 |

### 指令與介面

- 指令「**立即同步 LocalOCR**」：手動同步，完成後顯示「新增 N 筆、更新 M 筆」。
- 指令「**重新同步全部（重設進度）**」：重設進度後立刻同步全部掃描。
- 左側功能區的 `scan-text` 圖示：立即同步。
- 狀態列（桌面版）：`LocalOCR：同步中…`、`LocalOCR：HH:mm 已同步 N 筆` 或 `LocalOCR：同步失敗`（滑鼠移上去可看錯誤原因）；點一下即可同步。

## 筆記格式

路徑：`<目標資料夾>/<樣板名稱或「未分類」>/<YYYY-MM-DD HHmm> <標題>.md`

- 時間使用掃描的 `createdAt`，以本機時區顯示。
- 標題依序取 `data` 中第一個非空的 `title`、`store`、`name`、`company`；都沒有時取 OCR 文字的第一個非空行；再沒有就是「未命名」。
- 檔名會移除 `\ / : * ? " < > | # ^ [ ]`、合併空白，最多 60 個字。同名時加上 ` (2)`、` (3)`…

範例（`LocalOCR/收據／發票/2026-10-02 1110 全聯福利中心.md`）：

````markdown
---
localocr_id: "6F1C9D0E-2B7A-4E43-9A57-5B1E9F0C2D11"
created: "2026-10-02T03:10:00.000Z"
updated: "2026-10-02T03:10:02.000Z"
template: receipt
template_name: "收據／發票"
source: camera
confidence: 0.93
classifier: jev
tags: [localocr, localocr/receipt]
---
<!-- localocr:start -->

# 全聯福利中心

## 結構化資料

```json
{
  "store": "全聯福利中心",
  "date": null,
  "items": [
    {
      "name": "鮮乳",
      "quantity": 1,
      "price": 45
    }
  ],
  "total": 45,
  "currency": "TWD"
}
```

## 辨識文字

```text
全聯福利中心
鮮乳 45
合計 45
```

<!-- localocr:end -->

## 我的筆記

這裡（標記之外）寫的任何內容，同步時都會保留。
````

說明：

- `<!-- localocr:start -->` 與 `<!-- localocr:end -->` 之間是插件產生的內容，**每次更新都會被覆寫**，請把自己的筆記寫在標記之外（上方或下方皆可）。如果標記被刪掉，下次更新會把產生的區塊重新插入到內文最上方。
- 屬性中 `localocr_id`、`created`、`updated`、`template`、`template_name`、`source`、`confidence`、`classifier`、`tags` 由插件管理；你自己新增的其他屬性會保留，`tags` 中你自己加的標籤也會保留（`localocr`、`localocr/*` 由插件維護）。
- `confidence`（分類信心度）與 `classifier`（分類來源：`jev`、`on-device`、`keywords`、`manual`）只在掃描有分類資訊時出現。
- 結構化資料以 `JSON.stringify(data, null, 2)` 輸出，欄位順序與伺服器回傳的相同。
- OCR 文字中若出現 ```` ``` ````，會在反引號之間插入零寬空格，避免提早結束程式碼區塊。

## 同步的運作方式

1. 讀取 `GET /v1/templates`，取得樣板 id 與顯示名稱的對照。
2. 以 `GET /v1/scans?limit=100&updatedAfter=…&cursor=…` 逐頁下載，伺服器依 `updatedAt` 由舊到新排序。
   - 第一次同步會送出 `updatedAfter=1970-01-01T00:00:00.000Z`：沒有 `updatedAfter` 與 `cursor` 時，伺服器會改用「依建立時間由新到舊」排序，不適合增量同步。
3. 每處理完一頁，就把進度存進插件資料（`data.json`）：
   - 伺服器回傳 `nextCursor` 時，保存游標並繼續下一頁（同一輪同步中 `updatedAfter` 保持不變，讓游標搭配相同的查詢）。
   - `nextCursor` 為 `null` 時，把最後一筆的 `updatedAt` 記為下次的 `updatedAfter`，並清除游標。
   - 因此同步中途斷線或關閉 Obsidian，下次會從最後完成的那一頁繼續。
4. 每筆掃描：
   - 插件會記住「掃描 id → 筆記路徑」。筆記已存在時原地更新（不會改名或搬移，即使樣板或標題變了）；你自己搬移或改名筆記，插件會跟著更新記錄。
   - 如果記錄遺失（例如刪除了 `data.json`），會從筆記屬性 `localocr_id` 找回對應的筆記，不會重複建立。
   - 筆記被刪除時，下次這筆掃描有更新（或重設進度）時會重新建立。
   - 內容沒有變化時不會寫入檔案。
5. 同一時間只會有一個同步在執行；手動同步完成後會顯示新增／更新筆數，錯誤以通知顯示。自動同步只在第一次失敗時跳出通知，之後只在狀態列顯示，避免一直跳通知。

注意：伺服器上刪除的掃描不會刪除 Obsidian 中的筆記（API 不提供刪除紀錄）。

## 疑難排解

| 狀況 | 處理方式 |
| --- | --- |
| 「請先在設定中填入伺服器網址與 API 金鑰」 | 到插件設定填入兩者後再試 |
| 「無法連線到伺服器」 | 確認網址正確（含 `https://`）、伺服器正在執行；在瀏覽器開 `<網址>/health` 應看到 `{"status":"ok",…}`。行動版請使用 HTTPS 網址 |
| 「API 金鑰無效或未提供（401）」 | 金鑰必須是伺服器 `API_KEYS` 中的其中一把（以逗號分隔多把），注意前後不要有空白或換行 |
| 「找不到端點（404）」 | 網址不要包含 `/v1` 等路徑，只填伺服器根網址 |
| 「伺服器錯誤（5xx）」 | 查看 Railway 的伺服器記錄；已完成的頁面會保留，修好後再同步即可接續 |
| 「N 筆掃描無法寫入」 | 通常是資料夾名稱與既有檔案衝突，或檔案被其他程式鎖住；修正後執行「重新同步全部（重設進度）」 |
| 想用新的資料夾設定重新產生全部筆記 | 已存在的筆記不會搬移。可把舊的筆記資料夾移走或刪除，再執行「重新同步全部（重設進度）」 |
| 修改了「包含辨識文字」 | 只影響之後更新的筆記；要套用到全部筆記，請執行「重新同步全部（重設進度）」 |
| 筆記重複 | 請確認沒有手動複製筆記（兩則筆記有相同的 `localocr_id`）；刪掉多餘的那則即可 |

更多細節可以開啟開發者工具（桌面版 `Ctrl/Cmd + Shift + I`）查看以 `[LocalOCR Sync]` 開頭的訊息。插件不會在任何記錄或通知中輸出 API 金鑰。

### 安全性

API 金鑰以明文存在 `<保險庫>/.obsidian/plugins/localocr-sync/data.json`（Obsidian 插件的標準做法）。若你把保險庫放到公開的 Git 儲存庫或分享給他人，請排除這個檔案，或為該裝置建立專用的金鑰，以便隨時從伺服器的 `API_KEYS` 移除。

## 開發

需要 Node.js 22.12 以上。

```bash
cd obsidian-plugin
npm install
npm test            # vitest 單元測試（純邏輯：src/format.ts、src/sync-core.ts）
npx tsc --noEmit    # 型別檢查
npm run build       # 型別檢查 + 以 esbuild 打包成 main.js
npm run dev         # 監看模式（含 inline source map；提交前請改跑 npm run build）
```

| 檔案 | 內容 |
| --- | --- |
| `src/main.ts` | 插件主體：指令、功能區圖示、狀態列、自動同步、寫入筆記（Obsidian API） |
| `src/settings.ts` | 設定頁 |
| `src/sync-core.ts` | REST 用戶端（注入 HTTP 傳輸）、游標記錄、分頁同步迴圈（不依賴 Obsidian） |
| `src/format.ts` | 標題、檔名、路徑、筆記產生與保留使用者內容的合併（不依賴 Obsidian） |
| `src/types.ts` | API 資料型別 |
| `test/` | vitest 測試 |

發佈新版本時，同步更新 `manifest.json`、`package.json` 的 `version`，並在 `versions.json` 加上「版本 → 最低 Obsidian 版本」。
