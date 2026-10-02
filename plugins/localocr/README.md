# LocalOCR Claude Code 插件

讓 Claude Code 透過 MCP 連到你的 LocalOCR 伺服器：瀏覽 iPhone App 上傳的掃描、讀取 OCR 文字與情境 JSON、用 Jev 判斷情境、新增或修改情境樣板、檢查並回寫 JSON。

## 安裝

```text
/plugin marketplace add andyyyyang/iOS-APP
/plugin install localocr@localocr
```

安裝時會詢問：

- **LocalOCR server URL**：預設 `https://localocr-server-production.up.railway.app`
- **API key**：伺服器 `API_KEYS` 變數中的任一把金鑰（存放在系統的安全儲存區）

安裝後執行 `/mcp` 確認 `localocr` 已連線。

## 不使用插件

```bash
claude mcp add --transport http localocr https://localocr-server-production.up.railway.app/mcp \
  --header "Authorization: Bearer <API_KEY>"
```

其他支援 MCP（Streamable HTTP）的 harness 使用同一個網址與標頭；無法設定標頭時可改用 `?api_key=<API_KEY>`。

## 可以請 Claude 做的事

- 「列出這週的收據，整理成每家店的總金額」
- 「幫沒有 JSON 的掃描補上結構化資料」
- 「新增一個『藥袋』情境，欄位要有藥名、劑量、每日次數、注意事項」
- 「把所有名片匯出成 CSV」

工具清單與資料格式見 [docs/API.md](../../docs/API.md)。
