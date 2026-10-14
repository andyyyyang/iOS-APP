import { createHash } from "node:crypto";
import { z } from "zod";
import { AppError } from "../errors.js";
import type { VaultIndexService } from "../services/vault-index.js";
import { isHiddenPath } from "../services/vault-index.js";
import type { VaultService } from "../services/vault.js";
import { LinkResolver, retargetLink, rewriteWikilinks } from "../vault/links.js";
import { noteTitle } from "../vault/markdown.js";
import { contentTypeFor, vaultPath } from "../vault/paths.js";
import type { VaultFile } from "../vault/types.js";
import type { AssistantModel, ModelTool } from "./model.js";
import type { AssistantEdit, AssistantEventBody, EditOp } from "./types.js";

/** The change-feed client id of every vault write a run makes (the app and Obsidian devices hear about them). */
export const ASSISTANT_CLIENT_ID = "assistant";
/** read_file without a limit returns about this much text. */
export const READ_MAX_BYTES = 100 * 1024;
/** Hard cap on the characters read_file returns (a single huge line). */
export const READ_MAX_CHARS = 120_000;
export const LIST_MAX_FILES = 1000;
export const SAVE_OUTPUT_MAX_BYTES = 25 * 1024 * 1024;

export const sha1 = (body: Buffer) => createHash("sha1").update(body).digest("hex");

/** What undo needs about one change. */
export interface EditRecord {
  edit: AssistantEdit;
  /** update: the content before; delete: the deleted file's content. */
  previous: Buffer | null;
  previousMtime?: number;
  /** create/update/move: the etag and sha1 of what the run wrote at `edit.path`. */
  result: { etag: string; hash: string } | null;
  /** delete: the copy in .trash/. */
  trash?: { path: string; etag: string; hash: string };
}

export interface NewEdit extends Omit<EditRecord, "edit"> {
  op: EditOp;
  path: string;
  from?: string;
  summary: string;
}

/** The run a toolbox works for. */
export interface ToolHost {
  emit(event: AssistantEventBody): void;
  /** Records the edit, emits its "edit" event and returns it. */
  addEdit(edit: NewEdit): AssistantEdit;
  addSource(path: string): void;
  /** file_ids the code-execution sandbox produced in this run (the only ones save_output accepts). */
  readonly outputFileIds: ReadonlySet<string>;
  readonly signal: AbortSignal;
}

export interface ToolResult {
  content: string;
  isError: boolean;
}

const pathField = { type: "string", description: "Vault-relative path, e.g. 專案/週報.md (no leading /)." } as const;

const TOOL_DEFINITIONS: Record<string, ModelTool> = {
  list_files: {
    name: "list_files",
    description:
      "List files and child folders in the vault (dot folders such as .obsidian and .trash are hidden). " +
      "Returns JSON: folders (child folders, non-recursive only) and files (path, size in bytes, modified time).",
    input_schema: {
      type: "object",
      properties: {
        folder: { type: "string", description: "Vault-relative folder, e.g. 專案/ (default: the vault root)." },
        recursive: { type: "boolean", description: "List every file below the folder (default false)." },
      },
      additionalProperties: false,
    },
  },
  read_file: {
    name: "read_file",
    description:
      "Read a text file from the vault. By default the whole file up to about 100 KB (longer files are cut off with a note; " +
      "read the rest with offset/limit). offset is the 1-based line to start at, limit the number of lines. " +
      "Binary files (images, PDF, Office documents) return a description instead of content. " +
      "A file must be read in this run before write_file may overwrite it.",
    input_schema: {
      type: "object",
      properties: {
        path: pathField,
        offset: { type: "integer", minimum: 1, description: "First line to return (1-based, default 1)." },
        limit: { type: "integer", minimum: 1, description: "Number of lines to return." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  search_notes: {
    name: "search_notes",
    description:
      "Search file names and contents of .md/.txt/.json/.canvas files (case-insensitive substring match, newest first). " +
      "Returns JSON items with path, mtime and a snippet around the match. Use short keywords rather than sentences, " +
      "and several searches for several keywords.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Text to find." },
        folder: { type: "string", description: "Only search below this folder (default: the whole vault)." },
        limit: { type: "integer", minimum: 1, maximum: 100, description: "Maximum results (default 20)." },
      },
      required: ["query"],
      additionalProperties: false,
    },
  },
  get_links: {
    name: "get_links",
    description:
      "Outgoing [[wikilinks]] (resolved to vault paths) and backlinks (notes linking here) of a file, resolved the way Obsidian does.",
    input_schema: { type: "object", properties: { path: pathField }, required: ["path"], additionalProperties: false },
  },
  write_file: {
    name: "write_file",
    description:
      "Create a new text file, or overwrite an existing file entirely. Overwriting is only allowed after reading the file " +
      "with read_file in this run (and only if it has not changed since). Prefer edit_file for changes to existing notes. " +
      "Folders are created implicitly.",
    input_schema: {
      type: "object",
      properties: { path: pathField, content: { type: "string", description: "The complete file content (UTF-8)." } },
      required: ["path", "content"],
      additionalProperties: false,
    },
  },
  edit_file: {
    name: "edit_file",
    description:
      "Replace exact text in a text file. old_text must match the file exactly (whitespace and line breaks included) and be " +
      "unique in the file unless replace_all is true. Use this for focused changes; everything else stays untouched.",
    input_schema: {
      type: "object",
      properties: {
        path: pathField,
        old_text: { type: "string", description: "Exact text to replace." },
        new_text: { type: "string", description: "Replacement text." },
        replace_all: { type: "boolean", description: "Replace every occurrence (default false)." },
      },
      required: ["path", "old_text", "new_text"],
      additionalProperties: false,
    },
  },
  move_file: {
    name: "move_file",
    description:
      "Move or rename a file. The destination must not exist. With update_links (default true), [[wikilinks]] in other notes " +
      "that pointed to the old path are retargeted (keeping #heading, ^block and |alias parts).",
    input_schema: {
      type: "object",
      properties: {
        from: { type: "string", description: "Current vault-relative path." },
        to: { type: "string", description: "New vault-relative path (include the file extension)." },
        update_links: { type: "boolean", description: "Retarget links in other notes (default true)." },
      },
      required: ["from", "to"],
      additionalProperties: false,
    },
  },
  delete_file: {
    name: "delete_file",
    description: "Delete a file by moving it to .trash/ (Obsidian's trash folder); the user can restore it.",
    input_schema: { type: "object", properties: { path: pathField }, required: ["path"], additionalProperties: false },
  },
  save_output: {
    name: "save_output",
    description:
      "Save a file produced by code execution in the sandbox (use the file_id from the code execution result) into the vault. " +
      "Binary files are fine. The destination path must not exist yet.",
    input_schema: {
      type: "object",
      properties: {
        file_id: { type: "string", description: "file_id of the sandbox output file." },
        path: { type: "string", description: "Vault-relative destination path, e.g. 報表/2026-10 支出.xlsx." },
      },
      required: ["file_id", "path"],
      additionalProperties: false,
    },
  },
};

const optionalString = z.string().optional();
const INPUTS = {
  list_files: z.object({ folder: optionalString, recursive: z.boolean().optional() }),
  read_file: z.object({ path: z.string(), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).optional() }),
  search_notes: z.object({ query: z.string(), folder: optionalString, limit: z.number().int().min(1).max(100).optional() }),
  get_links: z.object({ path: z.string() }),
  write_file: z.object({ path: z.string(), content: z.string() }),
  edit_file: z.object({ path: z.string(), old_text: z.string(), new_text: z.string(), replace_all: z.boolean().optional() }),
  move_file: z.object({ from: z.string(), to: z.string(), update_links: z.boolean().optional() }),
  delete_file: z.object({ path: z.string() }),
  save_output: z.object({ file_id: z.string(), path: z.string() }),
};
type ToolName = keyof typeof INPUTS;
const isToolName = (name: string): name is ToolName => Object.hasOwn(INPUTS, name);

const utf8 = new TextDecoder("utf-8", { fatal: true });
const BINARY_EXTENSIONS = /\.(png|jpe?g|gif|webp|heic|bmp|svg|pdf|mp3|m4a|wav|ogg|mp4|mov|webm|zip|xlsx?|docx?|pptx?|key|numbers|pages)$/i;

/** The file as text, or null for binary content (images, PDF, Office files, NUL bytes, invalid UTF-8). */
export function fileText(file: Pick<VaultFile, "path" | "body">): string | null {
  const type = contentTypeFor(file.path);
  if (type.startsWith("image/") || type === "application/pdf" || BINARY_EXTENSIONS.test(file.path) || file.body.includes(0)) {
    return null;
  }
  try {
    return utf8.decode(file.body).replace(/^﻿/, "");
  } catch {
    return null;
  }
}

const toolError = (message: string) => new AppError(400, "tool_error", message);

const quote = (text: string, max = 40) => {
  const chars = Array.from(text.replace(/\s+/g, " ").trim());
  return chars.length > max ? `${chars.slice(0, max).join("")}…` : chars.join("");
};

/** A vault path the run may write: valid, and not in a dot folder. */
function writablePath(raw: string): string {
  const path = vaultPath(raw);
  if (isHiddenPath(path)) throw toolError(`不能寫入以 . 開頭的資料夾或檔案：${path}`);
  return path;
}

function countOccurrences(text: string, search: string): number {
  let count = 0;
  for (let index = text.indexOf(search); index !== -1; index = text.indexOf(search, index + search.length)) count += 1;
  return count;
}

/** The custom tools of one run, executed against the vault with client id "assistant". */
export class AssistantToolbox {
  /** Paths read (or written) in this run → the etag then; write_file only overwrites these. */
  private readonly readEtags = new Map<string, string>();

  constructor(
    private readonly deps: { vault: VaultService; vaultIndex: VaultIndexService; model: AssistantModel },
    private readonly host: ToolHost,
    private readonly options: { codeExecution: boolean },
  ) {}

  definitions(): ModelTool[] {
    return Object.values(TOOL_DEFINITIONS).filter((tool) => tool.name !== "save_output" || this.options.codeExecution);
  }

  setCodeExecution(enabled: boolean): void {
    this.options.codeExecution = enabled;
  }

  /** Short Traditional Chinese description of a call for the "tool" event. */
  summary(name: string, input: unknown): string {
    const args = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
    const text = (key: string) => (typeof args[key] === "string" ? (args[key] as string) : "");
    switch (name) {
      case "list_files":
        return `列出 ${text("folder") || "根目錄"}`;
      case "read_file":
        return `讀取 ${text("path")}`;
      case "search_notes":
        return `搜尋「${quote(text("query"))}」`;
      case "get_links":
        return `查看 ${text("path")} 的連結`;
      case "write_file":
        return `寫入 ${text("path")}`;
      case "edit_file":
        return `修改 ${text("path")}`;
      case "move_file":
        return `搬移 ${text("from")} → ${text("to")}`;
      case "delete_file":
        return `刪除 ${text("path")}`;
      case "save_output":
        return `儲存 ${text("path")}`;
      default:
        return name;
    }
  }

  async execute(name: string, input: unknown): Promise<ToolResult> {
    try {
      if (!isToolName(name) || (name === "save_output" && !this.options.codeExecution)) {
        throw toolError(`Unknown tool: ${name}`);
      }
      const parsed = INPUTS[name].safeParse(input);
      if (!parsed.success) {
        const issues = parsed.error.issues.map((issue) => `${issue.path.join(".") || "input"}: ${issue.message}`).join("; ");
        throw toolError(`Invalid input for ${name}: ${issues}`);
      }
      const content = await this.run(name, parsed.data as never);
      return { content, isError: false };
    } catch (error) {
      if (error instanceof AppError) {
        return { content: error.code === "tool_error" ? error.message : `${error.code}: ${error.message}`, isError: true };
      }
      if (this.host.signal.aborted) return { content: "cancelled", isError: true };
      console.error(`[assistant] tool ${name} failed`, error);
      return { content: "internal_error: the tool failed unexpectedly", isError: true };
    }
  }

  private run(name: ToolName, input: never): Promise<string> {
    switch (name) {
      case "list_files":
        return this.listFiles(input);
      case "read_file":
        return this.readFile(input);
      case "search_notes":
        return this.searchNotes(input);
      case "get_links":
        return this.getLinks(input);
      case "write_file":
        return this.writeFile(input);
      case "edit_file":
        return this.editFile(input);
      case "move_file":
        return this.moveFile(input);
      case "delete_file":
        return this.deleteFile(input);
      case "save_output":
        return this.saveOutput(input);
    }
  }

  private async readOrNull(path: string): Promise<VaultFile | null> {
    try {
      return await this.deps.vault.read(path);
    } catch (error) {
      if (error instanceof AppError && error.status === 404) return null;
      throw error;
    }
  }

  private async listFiles({ folder, recursive = false }: z.infer<typeof INPUTS.list_files>): Promise<string> {
    const listing = await this.deps.vault.list({ prefix: folder, recursive });
    const files = listing.items.filter((entry) => !isHiddenPath(entry.path));
    const shown = files.slice(0, LIST_MAX_FILES).map((entry) => ({
      path: entry.path,
      size: entry.size,
      modified: new Date(entry.mtime).toISOString(),
    }));
    return JSON.stringify({
      folder: folder || "/",
      ...(listing.folders ? { folders: listing.folders.filter((path) => !isHiddenPath(path)) } : {}),
      files: shown,
      ...(files.length > shown.length ? { truncated: true, totalFiles: files.length } : {}),
    });
  }

  private async readFile({ path, offset = 1, limit }: z.infer<typeof INPUTS.read_file>): Promise<string> {
    const file = await this.deps.vault.read(path);
    this.readEtags.set(file.path, file.etag);
    this.host.addSource(file.path);
    const meta = `path="${file.path}" size="${file.size}" modified="${new Date(file.mtime).toISOString()}"`;
    const text = fileText(file);
    if (text === null) {
      return `<file ${meta} type="${contentTypeFor(file.path)}" binary="true">二進位檔，無法以文字讀取。</file>`;
    }
    const lines = text.split("\n");
    const start = Math.min(offset, lines.length + 1);
    let end = limit === undefined ? lines.length : Math.min(lines.length, start - 1 + limit);
    if (limit === undefined) {
      let bytes = 0;
      for (let index = start - 1; index < end; index += 1) {
        bytes += Buffer.byteLength(lines[index]!, "utf8") + 1;
        if (bytes > READ_MAX_BYTES && index > start - 1) {
          end = index;
          break;
        }
      }
    }
    const partial = start > 1 || end < lines.length;
    let content = lines.slice(start - 1, end).join("\n");
    let note = partial ? `\n（顯示第 ${start}–${end} 行，共 ${lines.length} 行；用 offset/limit 讀取其他部分。）` : "";
    if (content.length > READ_MAX_CHARS) {
      // one enormous line (minified JSON, base64): cut it rather than flood the context
      content = content.slice(0, READ_MAX_CHARS);
      note += `\n（內容太長，只顯示前 ${READ_MAX_CHARS} 個字元。）`;
    }
    return `<file ${meta} lines="${lines.length}"${partial ? ` showing="${start}-${end}"` : ""}>\n${content}\n</file>${note}`;
  }

  private async searchNotes({ query, folder, limit }: z.infer<typeof INPUTS.search_notes>): Promise<string> {
    return JSON.stringify(await this.deps.vault.search(query, { prefix: folder, limit }));
  }

  private async getLinks({ path }: z.infer<typeof INPUTS.get_links>): Promise<string> {
    return JSON.stringify(await this.deps.vaultIndex.links(path));
  }

  private async writeFile({ path: rawPath, content }: z.infer<typeof INPUTS.write_file>): Promise<string> {
    const path = writablePath(rawPath);
    const body = Buffer.from(content, "utf8");
    const current = await this.readOrNull(path);
    const { vault } = this.deps;
    if (current) {
      const readEtag = this.readEtags.get(current.path);
      if (readEtag === undefined) {
        throw toolError(`${current.path} 已經存在。要整份覆寫請先用 read_file 讀取它；小幅修改請改用 edit_file。`);
      }
      if (readEtag !== current.etag) throw toolError(`${current.path} 在你讀取之後被修改過，請重新 read_file 後再寫入。`);
      if (current.body.equals(body)) return `${current.path} 的內容沒有變更。`;
      const { value } = await vault.write(current.path, body, { ifMatch: current.etag, client: ASSISTANT_CLIENT_ID });
      this.readEtags.set(value.path, value.etag);
      this.host.addEdit({
        op: "update",
        path: value.path,
        summary: `修改 ${value.path}`,
        previous: current.body,
        previousMtime: current.mtime,
        result: { etag: value.etag, hash: sha1(body) },
      });
      return `已覆寫 ${value.path}（${body.length} bytes）。`;
    }
    const { value } = await vault.write(path, body, { ifNoneMatch: "*", client: ASSISTANT_CLIENT_ID });
    this.readEtags.set(value.path, value.etag);
    this.host.addEdit({
      op: "create",
      path: value.path,
      summary: `新增 ${value.path}`,
      previous: null,
      result: { etag: value.etag, hash: sha1(body) },
    });
    return `已新增 ${value.path}（${body.length} bytes）。`;
  }

  private async editFile({ path: rawPath, old_text, new_text, replace_all = false }: z.infer<typeof INPUTS.edit_file>): Promise<string> {
    const path = writablePath(rawPath);
    if (old_text === "") throw toolError("old_text must not be empty; use write_file to create a file.");
    if (old_text === new_text) throw toolError("old_text and new_text are identical.");
    const current = await this.deps.vault.read(path);
    const text = fileText(current);
    if (text === null) throw toolError(`${current.path} 是二進位檔，不能用 edit_file 修改。`);
    let search = old_text;
    let replacement = new_text;
    let count = countOccurrences(text, search);
    if (count === 0 && text.includes("\r\n")) {
      // the note uses CRLF line endings; the model wrote LF
      search = old_text.replace(/\r?\n/g, "\r\n");
      replacement = new_text.replace(/\r?\n/g, "\r\n");
      count = countOccurrences(text, search);
    }
    if (count === 0) {
      throw toolError(`在 ${current.path} 中找不到 old_text（必須與檔案內容完全相同，包括空白與換行）。請先 read_file 確認原文。`);
    }
    if (count > 1 && !replace_all) {
      throw toolError(`old_text 在 ${current.path} 中出現 ${count} 次。請加入更多前後文讓它唯一，或設定 replace_all: true。`);
    }
    const updated = replace_all ? text.split(search).join(replacement) : text.replace(search, () => replacement);
    const hadBom = current.body.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]));
    const body = Buffer.from(hadBom ? `﻿${updated}` : updated, "utf8");
    const { value } = await this.deps.vault.write(current.path, body, { ifMatch: current.etag, client: ASSISTANT_CLIENT_ID });
    this.readEtags.set(value.path, value.etag);
    this.host.addEdit({
      op: "update",
      path: value.path,
      summary: `修改 ${value.path}`,
      previous: current.body,
      previousMtime: current.mtime,
      result: { etag: value.etag, hash: sha1(body) },
    });
    return `已修改 ${value.path}（取代 ${replace_all ? count : 1} 處）。`;
  }

  private async moveFile({ from: rawFrom, to: rawTo, update_links = true }: z.infer<typeof INPUTS.move_file>): Promise<string> {
    const from = writablePath(rawFrom);
    const to = writablePath(rawTo);
    if (from === to) throw toolError("from and to are the same path.");
    const { vault, vaultIndex } = this.deps;
    const source = await vault.read(from);
    if (await this.readOrNull(to)) throw toolError(`目的地 ${to} 已經存在。`);

    // Notes linking to the file, found before it moves (the index resolves links against the current vault).
    const before = update_links ? await vaultIndex.snapshot({ fresh: true }) : null;
    const linking = before
      ? [...before.details]
          .filter(([path, detail]) => path !== source.path && detail.allLinks.some((target) => before.resolver.resolve(target) === source.path))
          .map(([path]) => path)
      : [];

    const written = await vault.write(to, source.body, { ifNoneMatch: "*", mtime: source.mtime, client: ASSISTANT_CLIENT_ID });
    try {
      await vault.delete(source.path, { ifMatch: source.etag, client: ASSISTANT_CLIENT_ID });
    } catch (error) {
      await vault.delete(written.value.path, { ifMatch: written.value.etag, client: ASSISTANT_CLIENT_ID }).catch(() => {});
      throw error;
    }
    const destination = written.value.path;
    if (this.readEtags.delete(source.path)) this.readEtags.set(destination, written.value.etag);
    this.host.addEdit({
      op: "move",
      path: destination,
      from: source.path,
      summary: `搬移 ${source.path} → ${destination}`,
      previous: null,
      previousMtime: source.mtime,
      result: { etag: written.value.etag, hash: sha1(source.body) },
    });

    const updated: string[] = [];
    const failed: string[] = [];
    if (before && linking.length) {
      const moved = (path: string) => (path === source.path ? destination : path);
      const after = new LinkResolver([
        ...before.body.notes.map((note) => ({ path: moved(note.path), aliases: note.aliases })),
        ...before.body.files.map((file) => ({ path: moved(file.path) })),
      ]);
      for (const notePath of linking) {
        try {
          const note = await this.readOrNull(notePath);
          if (!note) continue;
          const text = fileText(note);
          if (text === null) continue;
          const rewritten = rewriteWikilinks(text, (target) =>
            retargetLink(target, { from: source.path, to: destination, before: before.resolver, after }),
          );
          if (rewritten.count === 0 || rewritten.text === text) continue;
          const hadBom = note.body.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]));
          const body = Buffer.from(hadBom ? `﻿${rewritten.text}` : rewritten.text, "utf8");
          const { value } = await vault.write(note.path, body, { ifMatch: note.etag, client: ASSISTANT_CLIENT_ID });
          if (this.readEtags.has(note.path)) this.readEtags.set(note.path, value.etag);
          this.host.addEdit({
            op: "update",
            path: value.path,
            summary: `更新 ${value.path} 中指向 ${noteTitle(destination)} 的連結`,
            previous: note.body,
            previousMtime: note.mtime,
            result: { etag: value.etag, hash: sha1(body) },
          });
          updated.push(value.path);
        } catch (error) {
          if (!(error instanceof AppError)) throw error;
          failed.push(notePath);
        }
      }
    }
    let message = `已將 ${source.path} 搬移到 ${destination}。`;
    if (updated.length) message += ` 已更新 ${updated.length} 則筆記中的連結：${updated.join("、")}。`;
    if (failed.length) message += ` 以下筆記的連結沒有更新成功：${failed.join("、")}。`;
    return message;
  }

  /** `.trash/<path>`, or `.trash/<name> 2.md` … when an earlier copy is already there. */
  private async freeTrashPath(path: string): Promise<string> {
    const base = `.trash/${path}`;
    if (!(await this.readOrNull(base))) return base;
    const slash = base.lastIndexOf("/");
    const dot = base.lastIndexOf(".");
    const [stem, extension] = dot > slash + 1 ? [base.slice(0, dot), base.slice(dot)] : [base, ""];
    for (let index = 2; index < 100; index += 1) {
      const candidate = `${stem} ${index}${extension}`;
      if (!(await this.readOrNull(candidate))) return candidate;
    }
    return `${stem} ${Date.now()}${extension}`;
  }

  private async deleteFile({ path: rawPath }: z.infer<typeof INPUTS.delete_file>): Promise<string> {
    const path = writablePath(rawPath);
    const { vault } = this.deps;
    const current = await vault.read(path);
    const trashPath = await this.freeTrashPath(current.path);
    const trashed = await vault.write(trashPath, current.body, { ifNoneMatch: "*", mtime: current.mtime, client: ASSISTANT_CLIENT_ID });
    try {
      await vault.delete(current.path, { ifMatch: current.etag, client: ASSISTANT_CLIENT_ID });
    } catch (error) {
      await vault.delete(trashed.value.path, { ifMatch: trashed.value.etag, client: ASSISTANT_CLIENT_ID }).catch(() => {});
      throw error;
    }
    this.readEtags.delete(current.path);
    this.host.addEdit({
      op: "delete",
      path: current.path,
      summary: `刪除 ${current.path}（移到 .trash）`,
      previous: current.body,
      previousMtime: current.mtime,
      result: null,
      trash: { path: trashed.value.path, etag: trashed.value.etag, hash: sha1(current.body) },
    });
    return `已將 ${current.path} 移到 ${trashed.value.path}（可以復原）。`;
  }

  private async saveOutput({ file_id, path: rawPath }: z.infer<typeof INPUTS.save_output>): Promise<string> {
    if (!this.host.outputFileIds.has(file_id)) {
      throw toolError(`Unknown file_id ${file_id}: only files produced by code execution in this run can be saved.`);
    }
    const path = writablePath(rawPath);
    if (await this.readOrNull(path)) throw toolError(`${path} 已經存在，請換一個檔名。`);
    const { body } = await this.deps.model.downloadFile(file_id, { signal: this.host.signal });
    if (body.length > SAVE_OUTPUT_MAX_BYTES) throw toolError(`The file is larger than ${SAVE_OUTPUT_MAX_BYTES / 1024 / 1024} MB.`);
    const { value } = await this.deps.vault.write(path, body, { ifNoneMatch: "*", client: ASSISTANT_CLIENT_ID });
    this.host.emit({ type: "file", path: value.path });
    this.host.addEdit({
      op: "create",
      path: value.path,
      summary: `儲存程式產生的檔案 ${value.path}`,
      previous: null,
      result: { etag: value.etag, hash: sha1(body) },
    });
    return `已儲存到 ${value.path}（${body.length} bytes）。`;
  }
}
