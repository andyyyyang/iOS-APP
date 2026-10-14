import { AppError } from "../errors.js";
import type { VaultService } from "../services/vault.js";
import { ASSISTANT_CLIENT_ID } from "./tools.js";
import { zonedIso, zonedMinute } from "./time.js";
import type { AssistantEdit, RunError } from "./types.js";

// The chat-history note (transcriptPath): each finished run appends its turn in this exact format, which the app
// reads back to show the conversation.

export interface TranscriptTurn {
  prompt: string;
  answer: string | null;
  error: RunError | null;
  sources: readonly string[];
  edits: readonly AssistantEdit[];
  /** When the user asked (the run's start). */
  askedAt: Date;
  timeZone: string;
}

const TRANSCRIPT_RETRIES = 4;

/** File name without ".md": the [[link]] text. */
const linkName = (path: string) => path.slice(path.lastIndexOf("/") + 1).replace(/\.md$/i, "");
const link = (path: string) => `[[${linkName(path)}]]`;

export function transcriptHeader(now: Date, timeZone: string): string {
  return `---\ntype: ai-chat\ncreated: ${zonedIso(now, timeZone)}\ntags: [ai-chat]\n---\n\n`;
}

/** "新增 [[X]]；修改 [[Y]]；搬移 [[Old]] → [[New]]；刪除 [[Z]]" (undone edits left out, repeats merged). */
export function describeEdits(edits: readonly AssistantEdit[]): string {
  const entries: string[] = [];
  const created = new Set<string>();
  for (const edit of edits) {
    if (edit.undone) continue;
    let entry: string;
    switch (edit.op) {
      case "create":
        created.add(edit.path);
        entry = `新增 ${link(edit.path)}`;
        break;
      case "update":
        if (created.has(edit.path)) continue;
        entry = `修改 ${link(edit.path)}`;
        break;
      case "move":
        if (edit.from && created.has(edit.from)) created.add(edit.path);
        entry = `搬移 ${link(edit.from ?? edit.path)} → ${link(edit.path)}`;
        break;
      case "delete":
        entry = `刪除 ${link(edit.path)}`;
        break;
    }
    if (!entries.includes(entry)) entries.push(entry);
  }
  return entries.join("；");
}

export function formatTurn({ prompt, answer, error, sources, edits, askedAt, timeZone }: TranscriptTurn): string {
  const lines = [
    `## 🙋 ${zonedMinute(askedAt, timeZone)}`,
    prompt.trim(),
    "",
    "## 🤖 雲端 AI",
    answer?.trim() ? answer.trim() : `（沒有完成：${error?.message ?? "沒有回答"}）`,
  ];
  const names = [...new Set(sources.map(link))];
  const changes = describeEdits(edits);
  const meta = [...(names.length ? [`> 來源：${names.join("、")}`] : []), ...(changes ? [`> 修改：${changes}`] : [])];
  if (meta.length) lines.push("", ...meta);
  return `${lines.join("\n")}\n`;
}

/** The note's new content: the header when it is new (or empty), then the turn after a blank line. */
export function appendTurn(existing: string | null, turn: TranscriptTurn, now: Date): string {
  if (existing === null || existing.trim() === "") return transcriptHeader(now, turn.timeZone) + formatTurn(turn);
  const separator = existing.endsWith("\n\n") ? "" : existing.endsWith("\n") ? "\n" : "\n\n";
  return existing + separator + formatTurn(turn);
}

/** Appends the turn to the note at `path` (creating it), retrying when someone else writes it in between. */
export async function appendTranscript(vault: VaultService, path: string, turn: TranscriptTurn, now: Date): Promise<void> {
  for (let attempt = 0; attempt < TRANSCRIPT_RETRIES; attempt += 1) {
    let current: Awaited<ReturnType<VaultService["read"]>> | null = null;
    try {
      current = await vault.read(path);
    } catch (error) {
      if (!(error instanceof AppError && error.status === 404)) throw error;
    }
    const text = appendTurn(current ? current.body.toString("utf8") : null, turn, now);
    try {
      await vault.write(current?.path ?? path, Buffer.from(text, "utf8"), {
        ...(current ? { ifMatch: current.etag } : { ifNoneMatch: "*" }),
        client: ASSISTANT_CLIENT_ID,
      });
      return;
    } catch (error) {
      if (!(error instanceof AppError && error.status === 412)) throw error;
    }
  }
  throw new AppError(409, "transcript_conflict", `The transcript ${path} kept changing; the turn was not appended`);
}
