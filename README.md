# 本機 OCR（LocalOCR）

使用 iOS 內建的 **Vision / VisionKit** 框架，在裝置上直接辨識圖片中的文字。全程離線，圖片不會上傳到任何伺服器。

## 功能

| 分頁 | 說明 |
| --- | --- |
| **辨識** | 從相簿選取（一次最多 10 張）、拍照、VisionKit 文件掃描（自動裁切與透視校正、可多頁）、從剪貼簿貼上圖片 |
| 結果頁 | 圖片上標示每個文字區塊（依信心度顯示綠／橘／紅框，點框即可複製）、可編輯的全文、逐行清單與信心度；可複製、分享、儲存 |
| **即時** | VisionKit `DataScannerViewController` 即時相機辨識，點選畫面中的文字加入，或一次擷取畫面上全部文字 |
| **紀錄** | 用 SwiftData 存在本機，可搜尋、編輯、分享、刪除 |
| **設定** | 辨識模式（精確／快速）、語言與優先順序、語言校正、自動偵測語言、自動儲存 |

預設辨識語言為繁體中文、簡體中文、英文；可用語言清單會依目前的辨識模式，直接向 Vision 查詢。

## 系統需求

- Xcode 16 以上（專案使用 Xcode 16 的資料夾同步格式）
- iOS 17.0 以上
- 即時掃描需要 A12 仿生晶片以上的實體裝置；相機、文件掃描與即時掃描都無法在模擬器上使用，但「從相簿選取」和「貼上圖片」可以

## 開始使用

1. 用 Xcode 開啟 `LocalOCR.xcodeproj`
2. 在 target **LocalOCR → Signing & Capabilities** 選擇你的 Team；如有需要，修改 Bundle Identifier（預設為 `com.andyyyyang.LocalOCR`）
3. 選擇裝置或模擬器後執行（⌘R）
4. 執行測試：⌘U

`LocalOCR/` 與 `LocalOCRTests/` 是同步資料夾，在 Finder 或 Xcode 中新增的檔案會自動加入對應的 target。

## 專案結構

```
LocalOCR/
├── App/                    App 進入點與分頁
├── OCR/
│   ├── OCRService.swift        VNRecognizeTextRequest 封裝（背景執行、async/await）
│   ├── OCRModels.swift         RecognizedLine / OCRPage / ScanSession
│   ├── TextLayout.swift        Vision 座標換算、閱讀順序排序
│   ├── ImagePreprocessor.swift 圖片轉正與縮圖
│   └── OCRSettings.swift       設定值與預設值
├── Features/
│   ├── Scan/               圖片來源、辨識流程、結果頁
│   ├── Live/               DataScannerViewController 即時掃描
│   ├── History/            SwiftData 紀錄
│   └── Settings/           設定與語言選擇
└── Shared/                 共用元件（Toast、信心度標籤）
LocalOCRTests/              單元測試（含實際呼叫 Vision 的辨識測試）
```

## 實作重點

- **座標系統**：Vision 的 `boundingBox` 是正規化座標、原點在左下角；`TextLayout.topLeftNormalizedRect` 轉換成 SwiftUI 使用的左上角原點，再依圖片在畫面中的 aspect-fit 區域換算成實際位置。
- **圖片方向**：辨識前先把圖片轉正為 `.up` 並限制長邊 4096 px，讓辨識座標能直接對應到顯示的圖片，也避免大圖造成記憶體暴增。
- **閱讀順序**：Vision 回傳的順序不一定是閱讀順序，`TextLayout.rows` 依垂直重疊程度分列、每列由左而右排序，同一列的區塊以空白連接。
- **語言限制**：快速模式只支援拉丁字母語言，送出請求前會濾掉目前模式不支援的語言。
- **模擬器**：模擬器沒有 Neural Engine，`OCRService` 在模擬器上會改用 CPU 執行辨識。

## 持續整合

`.github/workflows/ios.yml` 會在每次 push 時於 macOS runner 上：

1. 在最新的 iPhone 模擬器執行所有單元測試（包含把程式繪製的中英文字交給 Vision 實際辨識）
2. 以 Release 設定建置實體裝置版本（不簽章）

## 後續可以加的功能

- 使用 iOS 26 的 `RecognizeDocumentsRequest` 辨識表格、清單等文件結構
- 結果頁加入 VisionKit `ImageAnalysisInteraction`，可像「照片」App 一樣直接選取圖片中的文字
- 匯出 PDF（可搜尋文字層）
- 辨識結果翻譯（Translation 框架，同樣可在裝置上完成）
