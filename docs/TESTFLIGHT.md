# 用 GitHub Actions 自動上傳到 TestFlight

不需要 Mac：GitHub 的 macOS runner 會封存、簽章並上傳 App，你在 iPhone 上用 TestFlight 安裝。
金鑰只存在 GitHub 加密的 Secrets 中，**不要貼到聊天、Issue 或程式碼裡**。

## 1. 註冊 Bundle ID

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) → Identifiers → **+** → App IDs → App：

- Description：`LocalOCR`
- Bundle ID（Explicit）：`com.andyyyyang.LocalOCR`（要換成別的，請同時修改專案的 `PRODUCT_BUNDLE_IDENTIFIER`）

## 2. 在 App Store Connect 建立 App

[App Store Connect](https://appstoreconnect.apple.com/apps) → 我的 App → **+** → 新增 App：

- 平台：iOS
- 名稱：例如「本機 OCR」（App Store 上必須唯一，被佔用就換一個）
- 主要語言：繁體中文
- 套件識別碼：選擇上一步的 `com.andyyyyang.LocalOCR`
- SKU：例如 `localocr`

## 3. 建立 App Store Connect API 金鑰

App Store Connect → 使用者與存取權限 → **整合** → App Store Connect API → **團隊金鑰** → **+**：

- 名稱：`GitHub Actions`
- 存取權限：**管理**（Admin）。自動簽章需要建立雲端管理的發佈憑證；想用較小權限，可選 **App 管理**並允許存取雲端管理的發佈憑證。

產生後記下：

- **Issuer ID**（頁面上方）
- **金鑰 ID**（Key ID）
- 下載 **AuthKey_XXXXXXXXXX.p8**（只能下載一次，請妥善保存）

## 4. 找到 Team ID

[Membership details](https://developer.apple.com/account#MembershipDetailsCard) 中的 **Team ID**（10 碼英數字）。

## 5. 加入 GitHub Secrets

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**，新增四個：

| 名稱 | 內容 |
| --- | --- |
| `APPSTORE_CONNECT_KEY_ID` | 金鑰 ID |
| `APPSTORE_CONNECT_ISSUER_ID` | Issuer ID |
| `APPSTORE_CONNECT_PRIVATE_KEY` | 用文字編輯器打開 `.p8`，貼上**完整內容**（含 `-----BEGIN PRIVATE KEY-----` 與 `-----END PRIVATE KEY-----`） |
| `APPLE_TEAM_ID` | Team ID |

## 6. 上傳

- GitHub → **Actions** → **TestFlight** → **Run workflow**；或推送 `v1.0.0` 這類標籤。
- 成功後約 5–30 分鐘，App Store Connect 處理完成，就能在 TestFlight 頁面加入自己為內部測試人員，並在 iPhone 的 TestFlight App 安裝。

## 常見問題

- **No profiles / No signing certificate**：API 金鑰權限不足，請改用「管理」權限。
- **No suitable application records were found**：還沒在 App Store Connect 建立 App，或 Bundle ID 不一致。
- **Redundant binary upload / build number 重複**：再執行一次即可（build number 依執行次數遞增）。
- **Apple Intelligence**：智慧掃描需要支援 Apple Intelligence 的 iPhone 並在設定中開啟；不支援的裝置仍可辨識文字並上傳，由伺服器端的 harness 產生 JSON。
