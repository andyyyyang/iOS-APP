# LocalOCR Sync 更新紀錄

每個版本由 CI 發佈為 GitHub Release「obsidian-plugin-<版本>」，再由 LocalOCR 伺服器同步到 Railway 儲存空間；插件從這裡讀取更新內容（`## <版本>` 下的文字）。

## 1.3.0

- 線上更新改由你的 Railway 伺服器提供：伺服器把每個新版本存進自己的儲存空間，插件先讀取 `<伺服器網址>/obsidian-plugin/latest.json`，下載後逐一比對 SHA-256
- 未填伺服器網址、伺服器還沒有可用版本或連不上時，自動改從 GitHub 更新
- 第一次手動安裝可以直接從伺服器下載 `main.js` 與 `manifest.json`

## 1.2.0

- 線上更新：啟動 Obsidian 時（之後每 6 小時）檢查新版本，自動下載、驗證並安裝，不必再手動複製檔案
- 新指令「檢查並更新插件」；插件設定新增「更新」區塊（目前版本、檢查並更新、自動更新開關）

## 1.1.1

- 配對時不再指定「iPad 筆記」資料夾：App 同步整個保險庫，筆記可以放在任何資料夾

## 1.1.0

- 「配對 iPhone／iPad」（QR Code 與配對碼）與「設定 Remotely Save（同步 vault）」

## 1.0.0

- 把 LocalOCR 伺服器的掃描同步成 Markdown 筆記與 JSON 陣列
