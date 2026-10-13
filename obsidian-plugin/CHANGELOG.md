# LocalOCR Sync 更新紀錄

每個版本由 CI 發佈為 GitHub Release「obsidian-plugin-<版本>」；插件從這裡讀取更新內容（`## <版本>` 下的文字）。

## 1.2.0

- 線上更新：啟動 Obsidian 時（之後每 6 小時）檢查新版本，自動下載、驗證並安裝，不必再手動複製檔案
- 新指令「檢查並更新插件」；插件設定新增「更新」區塊（目前版本、檢查並更新、自動更新開關）

## 1.1.1

- 配對時不再指定「iPad 筆記」資料夾：App 同步整個保險庫，筆記可以放在任何資料夾

## 1.1.0

- 「配對 iPhone／iPad」（QR Code 與配對碼）與「設定 Remotely Save（同步 vault）」

## 1.0.0

- 把 LocalOCR 伺服器的掃描同步成 Markdown 筆記與 JSON 陣列
