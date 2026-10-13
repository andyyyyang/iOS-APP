# Obsidian 同步設定（Remotely Save × Railway Storage Bucket）

本文件說明如何讓 Mac、iPhone、iPad 上的 Obsidian 透過社群插件 **Remotely Save**，把同一個筆記庫（vault）同步到 Railway 的 Storage Bucket。
LocalOCR 伺服器讀寫的是同一個儲存桶，所以 iPad App 與 Claude（MCP）寫入的筆記，會在 Remotely Save 下一次同步時出現在每台裝置上；在 Obsidian 寫的筆記也能被 App 與 Claude 讀到。

```
Mac Obsidian ─┐
iPhone Obsidian ─┼─ Remotely Save（S3）⇄ Railway Storage Bucket ⇄ LocalOCR 伺服器（/v1/vault、vault_* 工具）⇄ iPad App／Claude
iPad Obsidian ─┘
```

App 與 Claude 一律經過伺服器存取筆記，只需要伺服器的 API 金鑰；儲存桶金鑰只放在伺服器與各裝置的 Remotely Save 設定中。
API 細節見 [API.md 的「Vault（Obsidian 筆記）」](API.md#vaultobsidian-筆記)。

> 插件的選項名稱會隨版本略有不同，下文以英文介面為準，括號內為說明。

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

每台裝置（Mac、iPhone、iPad）都要做一次：

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

1. **先在擁有完整筆記庫的裝置（通常是 Mac）同步**，讓它把所有筆記上傳到空的儲存桶。筆記多時第一次會比較久。
2. 到 Railway 儲存桶的 **Files** 分頁確認檔案都在，路徑與 vault 內相同（例如 `Daily/2026-10-13.md`，前面沒有多一層資料夾）。
3. 再到 iPhone、iPad：建立一個**空的** vault（建議與 Mac 同名），安裝並設定 Remotely Save（設定同上），然後同步，把筆記下載下來。
4. 之後每台裝置都可以正常編輯與自動同步。

不要讓兩台都已經有內容、但內容不同的裝置同時進行第一次同步，否則會產生大量衝突。
同一個 vault 也不要同時再用 iCloud、Obsidian Sync 等其他同步方式，以免互相覆蓋。

## 6. 備份

Railway 儲存桶**沒有版本控制，也沒有自動備份**：被覆寫或刪除的檔案無法從儲存桶復原，同步也會把刪除帶到每台裝置。

- 在 Mac 上保留本機備份（例如 Time Machine，或定期把 vault 資料夾壓縮備份）。
- 可在 Remotely Save 開啟「Abort Sync If Modification Above Percentage」之類的保護選項，避免一次大量刪改被同步出去。
- App 與 Claude 寫入時使用 etag 樂觀鎖，不會覆寫在讀取之後才被修改的筆記；Claude 的工具也刻意不提供刪除。

## 7. 疑難排解

| 症狀 | 可能原因與處理 |
| --- | --- |
| 403、`AccessDenied`、`InvalidAccessKeyId` | Access Key ID／Secret Access Key 錯誤，或 Bucket Name 填成顯示名稱。重新從 Credentials 分頁複製（注意前後空白），Bucket Name 使用 `BUCKET` 的完整值 |
| `NoSuchBucket`、404 | Bucket Name 錯誤（少了雜湊），或 Endpoint 不對 |
| `SignatureDoesNotMatch` | Region 不是 `auto`，或 S3 URL style 與儲存桶不符（新儲存桶用 virtual-hosted；只有 Credentials 分頁註明時才用 path-style），也可能是 Secret 複製不完整 |
| 手機上連線失敗、CORS 錯誤 | 開啟 Bypass CORS Locally，更新 Remotely Save 到最新版 |
| App／Claude 寫的筆記沒出現在 Obsidian | 等下一次自動同步或手動同步；在 Files 分頁確認檔案存在；確認 Remote Prefix 留空（或與伺服器的 `VAULT_PREFIX` 相同）；確認沒有開啟加密 |
| App 看不到 Obsidian 的新筆記 | 確認該裝置已同步完成（Files 分頁可看到檔案） |
| 伺服器 `GET /v1/vault/status` 回傳 `configured: false`，其他端點 503 `vault_not_configured` | 伺服器的 `VAULT_S3_*` 變數未設定或不完整（啟動紀錄會列出缺少的變數名稱），設定後重新部署 |
| 伺服器回傳 502 `vault_storage_error` | 訊息中有 S3 錯誤名稱（例如 `AccessDenied`、`SignatureDoesNotMatch`），依上表檢查伺服器的變數 |
