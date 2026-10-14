import { truncateText } from "../classifier/jev.js";
import { AppError } from "../errors.js";
import type { VaultService } from "../services/vault.js";
import { noteTitle } from "../vault/markdown.js";
import { zonedDate, zonedWeekday } from "./time.js";

/** The fixed instructions of every run (byte-identical across runs, so they stay in the prompt cache). */
export const SYSTEM_PROMPT = `你是使用者的知識庫助理，在雲端替使用者處理他的 Obsidian 筆記庫（vault）。把筆記庫當成一台電腦的檔案系統來操作：用工具列出、搜尋、閱讀、建立、修改、搬移與刪除檔案；需要計算、分析資料或產生檔案（表格、圖表、Excel、PDF 等）時，使用程式沙盒（code_execution，有提供時才能用）。

工作原則：
- 用工具查證，不要猜測筆記內容、檔名或資料夾結構。回答或動手之前，先搜尋、列出並閱讀相關的檔案。
- 引用來源時在句中用 [[筆記名稱]] 標示（檔名去掉 .md，例如 [[2026-10-12 週會]]）。
- 修改筆記時保留 frontmatter（開頭的 --- 區塊）、既有內容、[[連結]] 與來源網址，只改需要改的地方。小幅修改用 edit_file，不要整份重寫；write_file 只用來建立新檔，或在確實需要整份改寫時使用（覆寫既有檔案前一定要先 read_file）。
- 用 Obsidian 的方式整理：以資料夾分類，筆記之間用 [[wikilink]] 互相連結；附件（圖片、PDF 等）放在筆記旁邊或筆記庫設定的附件資料夾。搬移或改名用 move_file，它會一併更新其他筆記中指向該檔案的連結。
- 刪除用 delete_file：檔案會移到 .trash/（Obsidian 的垃圾桶），可以復原。不要寫入以 . 開頭的資料夾。
- 程式沙盒看不到筆記庫：要分析筆記時，先用 read_file 讀出內容，再把資料放進程式。沙盒產生的檔案要用 save_output 存回筆記庫，才會出現在使用者的裝置上。
- 批次工作先列出要處理的檔案，再逐一處理。不確定的地方寧可不改，並在最後的總結中說明。
- 工具呼叫之間可以寫一兩句進度說明，使用者會看到。
- 完成後用一段簡短的總結說明你做了什麼（新增、修改、搬移、刪除了哪些檔案），並附上相關筆記的 [[連結]]。
- 用繁體中文回答，除非使用者使用其他語言。`;

export const MAX_RULES_CHARS = 20_000;

/** Root files checked (case-insensitively, in this order) when the request does not name the rules file. */
export const RULES_FILE_NAMES = [
  "agents.md",
  "claude.md",
  "ai 規則.md",
  "ai規則.md",
  "編輯規則.md",
  "_編輯規則.md",
  "規則.md",
  "rules.md",
  "_rules.md",
];

export interface VaultRules {
  path: string;
  text: string;
  truncated: boolean;
}

const basename = (path: string) => path.slice(path.lastIndexOf("/") + 1);

/** The rules file at the vault root by name, else the first root .md whose name contains 規則, 規範 or "rule"; null if none. */
export async function findRulesPath(vault: VaultService): Promise<string | null> {
  const { items } = await vault.list({});
  const root = items.filter((entry) => !entry.path.includes("/") && !entry.path.startsWith("."));
  for (const name of RULES_FILE_NAMES) {
    const found = root.find((entry) => entry.path.normalize("NFC").toLowerCase() === name);
    if (found) return found.path;
  }
  return (
    root.find((entry) => /\.md$/i.test(entry.path) && /規則|規範|rule/i.test(basename(entry.path).normalize("NFC")))?.path ?? null
  );
}

/** `rulesPath` null = no rules; undefined = auto-detect. A missing file means no rules. */
export async function loadVaultRules(vault: VaultService, rulesPath: string | null | undefined): Promise<VaultRules | null> {
  if (rulesPath === null) return null;
  const path = rulesPath ?? (await findRulesPath(vault));
  if (!path) return null;
  try {
    const file = await vault.read(path);
    const full = file.body.toString("utf8").replace(/^﻿/, "");
    const text = truncateText(full, MAX_RULES_CHARS);
    return { path: file.path, text, truncated: text.length < full.length };
  } catch (error) {
    if (error instanceof AppError && (error.status === 404 || error.status === 400)) return null;
    throw error;
  }
}

export interface RunContextInput {
  now: Date;
  timeZone: string;
  openNote?: string;
  rules: VaultRules | null;
  codeExecution: boolean;
  webSearch: boolean;
}

/** This run's part of the system prompt. */
export function buildRunContext({ now, timeZone, openNote, rules, codeExecution, webSearch }: RunContextInput): string {
  const lines = [
    `今天是 ${zonedDate(now, timeZone)}（星期${zonedWeekday(now, timeZone)}），使用者的時區是 ${timeZone}。`,
    openNote ? `使用者目前開啟的筆記：[[${noteTitle(openNote)}]]（路徑 ${openNote}）。` : "使用者目前沒有開啟筆記。",
    codeExecution ? "本次可以使用程式沙盒（code_execution）與 save_output。" : "本次沒有程式沙盒，無法執行程式。",
    webSearch ? "本次可以搜尋網路（web_search）；引用網路資料時附上網址。" : "本次不能搜尋網路，只根據筆記庫回答。",
  ];
  if (rules) {
    lines.push(
      "",
      `以下是使用者為這個筆記庫訂的編輯規則（檔案 ${rules.path}），必須遵守；與上面的工作原則衝突時，以這些規則為準。` +
        (rules.truncated ? `規則超過 ${MAX_RULES_CHARS} 字，只列出前面的部分，需要時用 read_file 讀取全文。` : ""),
      `<vault_rules path="${rules.path}">`,
      rules.text,
      "</vault_rules>",
    );
  }
  return lines.join("\n");
}
