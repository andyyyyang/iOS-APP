# Obsidian 同步設定（Remotely Save × Railway Storage Bucket）

本文件說明如何讓電腦（Windows 或 Mac）、iPhone、iPad 上的 Obsidian 透過社群插件 **Remotely Save**，把同一個筆記庫（vault）同步到 Railway 的 Storage Bucket。
LocalOCR 伺服器讀寫的是同一個儲存桶，所以 iPad App 與 Claude（MCP）寫入的筆記，會在 Remotely Save 下一次同步時出現在每台裝置上；在 Obsidian 寫的筆記也能被 App 與 Claude 讀到。

```
電腦 Obsidian ┐
iPhone Obsidian ─┼─ Remotely Save（S3）⇄ Railway Storage Bucket ⇄ LocalOCR 伺服器（/v1/vault、vault_* 工具）⇄ iPad App／Claude
iPad Obsidian ─┘
```

App 與 Claude 一律經過伺服器存取筆記，只需要伺服器的 API 金鑰；儲存桶金鑰只放在伺服器與各裝置的 Remotely Save 設定中（伺服器只透過需要 API 金鑰的 `GET /v1/vault/remotely-save` 交給 Remotely Save 設定使用）。
API 細節見 [API.md 的「Vault（Obsidian 筆記）」](API.md#vaultobsidian-筆記)。

## 最快的設定方式

前提：伺服器已設定 `VAULT_S3_*`（見「[1. 準備 Railway 儲存桶](#1-準備-railway-儲存桶)」），而且電腦的 Obsidian 已安裝我們的 LocalOCR 插件（[`obsidian-plugin/`](../obsidian-plugin/README.md)）並填好伺服器網址與 API 金鑰。

1. **電腦：安裝 Remotely Save。** Obsidian →「設定 → 第三方外掛」→ 瀏覽，搜尋「**Remotely Save**」，安裝並啟用。第一次啟用時 Remotely Save 會詢問是否使用新版同步演算法，請勾選並同意（不同意時它會自行停用）。
2. **電腦：在 LocalOCR 插件執行「設定 Remotely Save（同步 vault）」**（命令面板，或插件設定頁「裝置設定」的按鈕）→ 按「**套用到這台裝置**」。Remotely Save 顯示已匯入設定後，**重新啟動 Obsidian**。
   這一步會設定 S3 連線（Remote prefix 與伺服器的 `VAULT_PREFIX` 相同）、啟動 10 秒後同步一次、每 5 分鐘自動同步、儲存時同步，等同下方第 3、4 節的手動設定。
3. **電腦：第一次同步。** 按左側欄的 Remotely Save 同步按鈕，把筆記上傳到空的儲存桶（順序見「[5. 第一次同步的順序](#5-第一次同步的順序)」）。
4. **iPhone／iPad：** 在 Obsidian 建立一個與電腦**同名**的空保險庫，安裝並啟用 Remotely Save（同第 1 步）。接著用 iPhone／iPad 的**相機 App** 掃描電腦上同一個對話框中的 QR Code，點開連結讓 Obsidian 套用設定，再重新啟動 Obsidian，筆記就會開始下載。
5. **配對 LocalOCR App：** 在電腦的 LocalOCR 插件執行「**配對 iPhone／iPad**」，然後在 iPhone／iPad 的 LocalOCR App 開啟「設定 → 配對」掃描 QR Code，或輸入畫面上的配對碼（10 分鐘內有效、只能使用一次）。App 會取得伺服器網址、API 金鑰與保險庫名稱，然後同步**整個 vault**：所有資料夾的筆記、圖片、PDF 等檔案都會下載到 iPhone／iPad（`.obsidian` 設定資料夾除外），筆記可以放在任何資料夾，App 的資料夾頁面與 Obsidian 的檔案結構相同。

- Remotely Save 只接受與目前保險庫**同名**的設定；名稱不同時它會顯示「the target vault is … but you are currently in …」。
- Remotely Save 的 QR Code 含有**儲存桶的存取金鑰**，不要截圖、貼到聊天或分享。
- 匯入只會改 S3 連線與同步排程，Encryption Password（加密密碼）等其他設定不變；加密密碼請保持空白（見下方「不要開啟端對端加密」）。

自動設定失敗、或想自行調整時，依下面的手動步驟設定。

> 插件的選項名稱會隨版本略有不同，下文以英文介面為準，括號內為說明。


### Windows：vault 在 D: 槽時

1. **先備份**：把整個 vault 資料夾（例如 `D:\Obsidian\andy-jentech`）複製或壓縮一份到別處。Railway 儲存桶沒有版本紀錄。
2. **安裝 LocalOCR 插件**：從 [GitHub Releases](https://github.com/andyyyyang/iOS-APP/releases) 最新的 `obsidian-plugin-<版本>` 下載 `main.js` 與 `manifest.json`，放到 `D:\…\你的 vault\.obsidian\plugins\localocr-sync\`（`.obsidian` 是隱藏資料夾，檔案總管要開啟「顯示隱藏的項目」），重新啟動 Obsidian 後在「設定 → 第三方外掛」啟用 **LocalOCR Sync**，填入伺服器網址與 API 金鑰。1.2.0 起插件會自動線上更新，只需要手動安裝這一次。
3. 依照上面的步驟 1～3：安裝 Remotely Save → 「設定 Remotely Save（同步 vault）」→「套用到這台裝置」→ 重新啟動 Obsidian → 按 Remotely Save 的同步按鈕。第一次會把整個 vault 上傳，檔案多時需要一些時間，Remotely Save 的狀態列會顯示進度。
4. 到 Railway 專案 → `obsidian-vault` →「Files」確認筆記都已上傳。
5. 如果這個 vault 同時用 OneDrive、Google 雲端硬碟、Obsidian Sync 或 git 等方式同步，建議只保留一種，避免兩套同步互相覆蓋。

## 1. 準備 Railway 儲存桶

1. 在 Railway 專案畫布上按 **Create → Bucket** 建立儲存桶（例如顯示名稱 `obsidian-vault`）。地區建立後無法更改。
2. 打開儲存桶的 **Credentials** 分頁，記下：
   - `ENDPOINT`：例如 `https://t3.storageapi.dev`
   - `REGION`：`auto`
   - `ACCESS_KEY_ID`、`SECRET_ACCESS_KEY`
   - `BUCKET`：**實際的 S3 bucket 名稱**，是顯示名稱加上一段雜湊（例如 `obsidian-vault-jdhhd8oe18xi`），不是畫布上看到的顯示名稱
   - URL style：Credentials 分頁會註明使用 virtual-hosted 或 path-style。新建立的儲存桶都是 virtual-hosted。

### 伺服器變數

在 LocalOCR 伺服器服務的 **Variables** 中，用變數參照指向儲存桶（`obsidian-vault` 換成你的儲存桶服務名稱）：

```
VAULT_S3_ENDPOINT=${{obsidian-vault.ENDPOINT}}
VAULT_S3_BUCKET=${{obsidian-vault.BUCKET}}
VAULT_S3_REGION=${{obsidian-vault.REGION}}
VAULT_S3_ACCESS_KEY_ID=${{obsidian-vault.ACCESS_KEY_ID}}
VAULT_S3_SECRET_ACCESS_KEY=${{obsidian-vault.SECRET_ACCESS_KEY}}
```

- 只有 Credentials 分頁註明 path-style 時，才另外設定 `VAULT_S3_FORCE_PATH_STYLE=true`。
- 如果在 Remotely Save 設定了 Remote prefix（不建議），`VAULT_PREFIX` 要設成相同的值並以 `/` 結尾，例如 `vault/`。
- 部署後以 `GET /v1/vault/status` 確認回傳 `{"configured":true,"prefix":""}`。

## 2. 安裝 Remotely Save

每台裝置（電腦、iPhone、iPad）都要做一次：

1. Obsidian → **Settings（設定）→ Community plugins（社群插件）**，關閉 Restricted mode（安全模式）。
2. **Browse（瀏覽）** 搜尋「**Remotely Save**」，安裝後按 **Enable（啟用）**。
3. 打開 Remotely Save 的設定頁。

## 3. 設定 S3 連線

| 選項 | 填寫 |
| --- | --- |
| Choose a remote service（遠端服務） | **S3 or compatible**（S3 或相容服務） |
| Endpoint | Credentials 分頁的 `ENDPOINT`，例如 `https://t3.storageapi.dev` |
| Region | `auto` |
| Access Key ID | `ACCESS_KEY_ID` |
| Secret Access Key | `SECRET_ACCESS_KEY` |
| Bucket Name | `BUCKET`（顯示名稱加雜湊的完整名稱） |
| S3 URL style | **Virtual Hosted-Style**（預設）。除非 Credentials 分頁註明 path-style，否則**不要**改成 Path-Style |
| Remote Prefix | **留空** |
| Bypass CORS Locally（若有此選項） | 開啟 |
| Use Accurate MTime（若有此選項） | 建議開啟（Railway 的 API 請求不另外計費），能更準確判斷哪一邊的檔案較新 |

填完後按 **Check Connectivity（檢查連線）**，應顯示連線成功。

### 不要開啟端對端加密

**Encryption Password（加密密碼）請保持空白。** 開啟加密後，儲存桶裡只剩加密過的檔案（檔名也會被加密），iPad App 與 Claude 都無法讀取或寫入筆記。
已經用加密同步過的話，要先在每台裝置關閉加密，並清空儲存桶後重新同步。

## 4. 自動同步

| 選項 | 建議 |
| --- | --- |
| Run Once On Start Up Automatically（啟動時同步） | 開啟（例如啟動 1 秒後） |
| Schedule For Auto Run（定時同步） | 每 1–5 分鐘 |
| Sync On Save（儲存時同步） | 開啟 |

App 或 Claude 寫入的筆記，會在下一次自動同步（或手動按左側欄的同步按鈕）後出現在 Obsidian 中。
Sync Config Dir（同步 `.obsidian` 設定資料夾）可依個人需要決定；伺服器的搜尋會略過 `.obsidian`。

## 5. 第一次同步的順序

1. **先在擁有完整筆記庫的裝置（你的電腦，例如 Windows D: 槽的 vault）同步**，讓它把所有筆記上傳到空的儲存桶。筆記多時第一次會比較久。
2. 到 Railway 儲存桶的 **Files** 分頁確認檔案都在，路徑與 vault 內相同（例如 `Daily/2026-10-13.md`，前面沒有多一層資料夾）。
3. 再到 iPhone、iPad：建立一個**空的** vault（與電腦同名），安裝並設定 Remotely Save（設定同上），然後同步，把筆記下載下來。
4. 之後每台裝置都可以正常編輯與自動同步。

不要讓兩台都已經有內容、但內容不同的裝置同時進行第一次同步，否則會產生大量衝突。
同一個 vault 也不要同時再用 iCloud、Obsidian Sync 等其他同步方式，以免互相覆蓋。

## 6. 備份

Railway 儲存桶**沒有版本控制，也沒有自動備份**：被覆寫或刪除的檔案無法從儲存桶復原，同步也會把刪除帶到每台裝置。

- 在電腦上保留本機備份（Windows 可用「檔案歷程記錄」或定期把 vault 資料夾壓縮備份；Mac 可用 Time Machine）。
- 可在 Remotely Save 開啟「Abort Sync If Modification Above Percentage」之類的保護選項，避免一次大量刪改被同步出去。
- App 與 Claude 寫入時使用 etag 樂觀鎖，不會覆寫在讀取之後才被修改的筆記；Claude 的工具也刻意不提供刪除。

## 7. 疑難排解

| 症狀 | 可能原因與處理 |
| --- | --- |
| 403、`AccessDenied`、`InvalidAccessKeyId` | Access Key ID／Secret Access Key 錯誤，或 Bucket Name 填成顯示名稱。重新從 Credentials 分頁複製（注意前後空白），Bucket Name 使用 `BUCKET` 的完整值 |
| `NoSuchBucket`、404 | Bucket Name 錯誤（少了雜湊），或 Endpoint 不對 |
| `SignatureDoesNotMatch` | Region 不是 `auto`，或 S3 URL style 與儲存桶不符（新儲存桶用 virtual-hosted；只有 Credentials 分頁註明時才用 path-style），也可能是 Secret 複製不完整 |
| 手機上連線失敗、CORS 錯誤 | 開啟 Bypass CORS Locally，更新 Remotely Save 到最新版 |
| 掃描 QR Code 或「套用到這台裝置」後，Remotely Save 顯示「the target vault is …」 | 這台裝置的保險庫名稱與電腦不同。把保險庫改成相同名稱，或在這台裝置的 LocalOCR 插件執行「設定 Remotely Save」 |
| 套用設定後沒有自動同步 | 重新啟動 Obsidian（Remotely Save 只在啟動時建立自動同步排程）；也確認已同意新版同步演算法 |
| LocalOCR 插件顯示「伺服器尚未設定 Obsidian 儲存桶」 | 伺服器的 `VAULT_S3_*` 未設定，見第 1 節 |
| App／Claude 寫的筆記沒出現在 Obsidian | 等下一次自動同步或手動同步；在 Files 分頁確認檔案存在；確認 Remote Prefix 留空（或與伺服器的 `VAULT_PREFIX` 相同）；確認沒有開啟加密 |
| App 看不到 Obsidian 的新筆記 | 確認該裝置已同步完成（Files 分頁可看到檔案） |
| 伺服器 `GET /v1/vault/status` 回傳 `configured: false`，其他端點 503 `vault_not_configured` | 伺服器的 `VAULT_S3_*` 變數未設定或不完整（啟動紀錄會列出缺少的變數名稱），設定後重新部署 |
| 伺服器回傳 502 `vault_storage_error` | 訊息中有 S3 錯誤名稱（例如 `AccessDenied`、`SignatureDoesNotMatch`），依上表檢查伺服器的變數 |
