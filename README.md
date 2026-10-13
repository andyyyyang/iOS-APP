# 本機 OCR（LocalOCR）

原生 Swift 的 iPhone／iPad App：

- **手寫筆記（iPad）**：像 GoodNotes 的分頁筆記本（A4 空白／橫線／方格／點陣紙），使用系統原生 Apple Pencil 工具列；Apple **Foundation Models** 在裝置上辨識手寫並整理出標題、摘要、重點、待辦與標籤，連同每頁圖片存進 **Obsidian vault**。
- **Obsidian**：vault 存在 Railway 的 S3 空間（Bucket），Mac／iPhone／iPad 的 Obsidian 以 **Remotely Save** 同步；App 內可瀏覽、搜尋、閱讀、編輯所有筆記，Claude 也能透過 MCP 讀寫。
- **智慧掃描**：用 Apple **Vision** 在裝置上辨識文字，**自動判斷文件情境**（收據、名片、FV60 請款…），再用 Foundation Models 整理成**你指定格式的 JSON**。

```
iPhone／iPad App（SwiftUI，iPad 為原生側邊欄）
  ├─ 筆記：PencilKit 分頁筆記本 → Vision 手寫辨識 → Foundation Models 整理
  ├─ Obsidian：瀏覽／搜尋／編輯 vault
  ├─ 掃描：Vision OCR → 情境判斷（Jev → 裝置端模型 → 關鍵字）→ JSON
        │
        ▼
Railway
  ├─ 伺服器 server/（REST /v1、MCP /mcp、Postgres）
  │    └─ /v1/vault：讀寫 vault 檔案（Bucket）
  └─ Bucket obsidian-vault（S3）◀── Remotely Save ──▶ Obsidian（Mac／iPhone／iPad）

  ├─ obsidian-plugin/   掃描結果同步成筆記
  ├─ plugins/localocr/  Claude Code 插件（遠端 MCP，含 vault 工具）
  └─ 自建 harness       REST + OpenAPI
```

所有元件共用的資料格式與 API：[docs/API.md](docs/API.md)。

## 目錄

| 目錄 | 內容 |
| --- | --- |
| `LocalOCR/` | iOS App（Swift、SwiftUI、Vision、VisionKit、Foundation Models、SwiftData） |
| `LocalOCRTests/` | 單元測試（JSON、情境分類、樣板、Vision 實際辨識、伺服器格式） |
| `server/` | Node.js／TypeScript 伺服器：REST、MCP、Postgres、Jev（[說明](server/README.md)） |
| `obsidian-plugin/` | Obsidian 插件，把掃描同步成筆記（[說明](obsidian-plugin/README.md)） |
| `plugins/localocr/` | Claude Code 插件（[說明](plugins/localocr/README.md)） |
| `docs/` | [API 規格](docs/API.md)、[Obsidian 同步設定](docs/OBSIDIAN-SYNC.md)、[TestFlight 自動上傳](docs/TESTFLIGHT.md) |

## App 功能

| 畫面 | 說明 |
| --- | --- |
| **筆記** | 筆記本書架（封面、搜尋、排序）；分頁紙張、雙指縮放、系統 Apple Pencil 工具列（手指／Pencil 依系統設定）、頁面總覽（插入、刪除、跳頁）、改紙張；檢閱器：Apple Intelligence 整理（手寫辨識、標題、摘要、重點、待辦、標籤）、同步到 Obsidian、在 Obsidian 開啟。其他裝置建立的筆記本會從 vault 匯入，可繼續編輯 |
| **Obsidian** | iPad 左側資料夾樹、右側筆記；全文搜尋；Markdown 閱讀（屬性、標題、清單、待辦、callout、程式碼、內嵌圖片、[[連結]] 可點）；編輯（支援系統書寫工具）並以 ETag 防止覆蓋 Obsidian 中的修改；Apple Intelligence 整理並插入摘要與標籤；新增筆記 |
| **掃描** | 相簿（最多 50 張）、拍照、文件掃描（自動裁切、多頁）、貼上圖片；頁面先收進**這份文件**（可混用來源、刪除、調整順序），全部加入後再按「開始分析」；各情境的紀錄數量；右下角**工具選單**（弧形滾輪） |
| 結果頁 | **JSON**：判斷出的情境與信心度、依樣板產生的 JSON（可更換情境重跑）、上傳狀態；選單中的「加入頁面」可補上漏掉的頁面並重新分析；**圖片**：文字框標示、點選複製；**文字**：可編輯全文；**逐行**：每行信心度 |
| **相機** | 連續拍照：按快門一頁一頁加入同一份文件（不需點選文字），全部拍完再按「分析」 |
| **紀錄** | 名稱與副標取自擷取內容（例如 JT 號；總金額與單價）；保存每一頁照片，可全螢幕查看、縮放、分享；搜尋、編輯、補充頁面後重新分析、上傳 |
| **設定** | 筆記與 Obsidian（存放資料夾、vault 名稱、自動同步、連線狀態、Remotely Save 設定說明）、情境樣板管理、Apple Intelligence 狀態、Jev 開關、伺服器與同步、OCR 語言與模式 |

### 情境樣板（照你要的樣式輸出 JSON）

情境是資料而不是程式碼：

- **內建**：`receipt` 收據／發票、`business_card` 名片、`event` 活動／海報、`document` 一般文件
- **自訂**：在 App 貼上一段**範例 JSON**，輸出就會有相同的欄位、巢狀結構與順序；也可覆寫內建情境的格式
- **伺服器**：在伺服器或透過 MCP 新增的情境，App 啟動時自動同步

範例 JSON 會轉成 Foundation Models 的 `DynamicGenerationSchema`，由裝置端模型以引導式生成（guided generation）直接產生符合結構的資料，再依樣板整理欄位順序、補上缺少的欄位。

### 系統需求

- Xcode 26 以上（CI 同時以 Xcode 26 與 Xcode 27／iOS 27 SDK 建置與測試）
- iOS／iPadOS 18 以上可使用 OCR 與手寫筆記；**智慧 JSON 與筆記整理需要 iOS 26 以上且支援並開啟 Apple Intelligence 的 iPhone／iPad**（iOS 27 會自動使用新一代裝置端模型）
- 不支援 Apple Intelligence 的裝置仍會判斷情境（Jev／關鍵字）並保存文字；上傳後可由 harness 透過 MCP 補上 JSON

## 開始使用

### 在 iPhone 上安裝（不需要 Mac）

設定 GitHub Secrets 後執行 **Actions → TestFlight**，步驟見 [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md)。

### 用 Xcode 開發

1. 開啟 `LocalOCR.xcodeproj`，在 **Signing & Capabilities** 選擇 Team（Bundle ID 預設 `com.andyyyyang.LocalOCR`）
2. ⌘R 執行、⌘U 測試

### 連接伺服器

App **設定 → 伺服器與同步**：

- 網址：`https://localocr-server-production.up.railway.app`
- API 金鑰：Railway 專案 `localocr` → `localocr-server` → Variables → `API_KEYS`

同一把金鑰也用於 Obsidian 插件與 Claude Code 插件。要使用 Jev 判斷情境，在 Railway 的 `localocr-server` 加上 `JEV_API_KEY`（TypeSafe AI 金鑰）。

## 擴充方式

| 想做的事 | 做法 |
| --- | --- |
| 新增情境／輸出格式 | App 設定 → 情境樣板 → ＋，或 MCP `upsert_template`、`PUT /v1/templates/{id}` |
| 新增分類來源（其他模型） | App：實作 `DocumentClassifier` 並加入 `SmartScanEngine.classifierPipeline`；伺服器：實作 `Classifier` 介面 |
| 新增抽取引擎 | App：實作 `StructuredExtractor` |
| 新增 MCP 工具 | `server/src/mcp/server.ts`，業務邏輯放在 `server/src/services/` 與 REST 共用 |
| 新增同步目的地 | 讀取 `GET /v1/scans?updatedAfter=…`（增量同步）或使用 MCP |
| 水平擴充伺服器 | MCP 為無狀態模式、資料在 Postgres，可直接增加 Railway 副本數 |

## 持續整合

| Workflow | 內容 |
| --- | --- |
| `ios.yml` | Xcode 26 與 Xcode 27：模擬器單元測試、Release 裝置建置 |
| `server.yml` | 型別檢查、記憶體與 Postgres 兩種儲存的測試、建置 |
| `obsidian-plugin.yml` | 測試、建置、檢查 `main.js` 與原始碼一致 |
| `testflight.yml` | 手動或推送 `v*` 標籤時封存、簽章並上傳 TestFlight |
