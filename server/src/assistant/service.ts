import { randomUUID } from "node:crypto";
import type Anthropic from "@anthropic-ai/sdk";
import type { TypeSafeClient } from "@typesafe-ai/sdk";
import { truncateText } from "../classifier/jev.js";
import { AppError, notFound } from "../errors.js";
import { parse } from "../services/parse.js";
import type { VaultIndexService } from "../services/vault-index.js";
import { isHiddenPath } from "../services/vault-index.js";
import type { VaultService } from "../services/vault.js";
import { extractAllLinks } from "../vault/markdown.js";
import { vaultPath } from "../vault/paths.js";
import type { VaultFile } from "../vault/types.js";
import { AssistantModelError, type AssistantModel, type ModelMessage, type ModelResponse } from "./model.js";
import { SYSTEM_PROMPT, buildRunContext, loadVaultRules } from "./prompt.js";
import { RequestRouter } from "./routing.js";
import type { Effort } from "./tiers.js";
import { MAX_HISTORY_TEXT, MAX_HISTORY_TURNS, routeRequestSchema, runQuerySchema, runRequestSchema, undoRequestSchema, type RunRequest } from "./schemas.js";
import { DEFAULT_TIME_ZONE } from "./time.js";
import { ASSISTANT_CLIENT_ID, AssistantToolbox, sha1, type EditRecord, type NewEdit, type ToolHost } from "./tools.js";
import { appendTranscript } from "./transcript.js";
import type {
  AssistantEdit,
  AssistantEvent,
  AssistantEventBody,
  RouteDecision,
  RunError,
  RunStatus,
  RunUsage,
  RunView,
  UndoResult,
} from "./types.js";

/** Runs are kept in memory this long after they start. */
export const RUN_TTL_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_MAX_TURNS = 40;
/** A progress note standing in for work cut off by max_tokens (not shown to the user). */
const INTERRUPTED_NOTE = "This part of the response was interrupted before it finished.";
/** An HTTP 400 naming a server tool: the run is retried once without server tools. */
const SERVER_TOOL_REJECTED = /code[_ ]?execution|web[_ ]?search|server[_ ]tool/i;

export interface AssistantOptions {
  /** The model; null = cloud runs are off (503 assistant_not_configured). */
  model: AssistantModel | null;
  /** Jev for POST /v1/assistant/route; null = keyword heuristic. */
  jev?: Pick<TypeSafeClient, "systemOne"> | null;
  jevModel?: string;
  maxTurns?: number;
  codeExecution?: boolean;
  webSearch?: boolean;
}

class RunFailure extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

class UndoRefused extends Error {}

class Run {
  status: RunStatus = "running";
  /** Set while the transcript is written: the status the run is about to get. */
  pendingStatus: RunStatus | null = null;
  readonly events: AssistantEvent[] = [];
  answer: string | null = null;
  error: RunError | null = null;
  readonly sources: string[] = [];
  readonly edits: EditRecord[] = [];
  readonly usage: RunUsage = { inputTokens: 0, outputTokens: 0 };
  readonly outputFileIds = new Set<string>();
  readonly abort = new AbortController();
  /** Thinking effort chosen by the route (undefined = the model default, high). */
  effort: Effort | undefined;
  /** The agent loop (always resolves). */
  done: Promise<void> = Promise.resolve();
  /** Undo requests run one at a time. */
  undoChain: Promise<unknown> = Promise.resolve();
  private readonly listeners = new Set<() => void>();

  constructor(
    readonly id: string,
    readonly model: string,
    readonly createdAt: number,
    private readonly now: () => number,
  ) {}

  emit(body: AssistantEventBody): void {
    this.events.push({ seq: this.events.length + 1, at: new Date(this.now()).toISOString(), ...body } as AssistantEvent);
    this.notify();
  }

  addSource(path: string): void {
    if (!this.sources.includes(path)) this.sources.push(path);
  }

  notify(): void {
    for (const listener of [...this.listeners]) listener();
  }

  /** Resolves on the next event or status change, after `ms`, or when `signal` aborts. */
  waitForChange(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve) => {
      const finish = () => {
        clearTimeout(timer);
        this.listeners.delete(finish);
        signal?.removeEventListener("abort", finish);
        resolve();
      };
      const timer = setTimeout(finish, ms);
      this.listeners.add(finish);
      signal?.addEventListener("abort", finish, { once: true });
    });
  }

  view(after: number): RunView {
    return {
      id: this.id,
      status: this.status,
      model: this.model,
      events: this.events.filter((event) => event.seq > after),
      answer: this.answer,
      error: this.error,
      sources: [...this.sources],
      edits: this.edits.map((record) => ({ ...record.edit })),
      usage: { ...this.usage },
    };
  }
}

/** Short Traditional Chinese description of a server tool call. */
function serverToolSummary(name: string, input: unknown): string {
  if (name === "web_search") {
    const query = (input as { query?: unknown } | null)?.query;
    return typeof query === "string" ? `搜尋網路「${truncateText(query, 40)}」` : "搜尋網路";
  }
  if (name === "web_fetch") return "讀取網頁";
  if (name.includes("code_execution")) return "執行程式";
  return "使用工具";
}

/** Every `file_id` inside a server tool result block (files the code-execution sandbox produced). */
function collectFileIds(value: unknown, into: Set<string>, depth = 0): void {
  if (depth > 8 || value === null || typeof value !== "object") return;
  if (Array.isArray(value)) {
    for (const item of value) collectFileIds(item, into, depth + 1);
    return;
  }
  for (const [key, item] of Object.entries(value)) {
    if (key === "file_id" && typeof item === "string") into.add(item);
    else collectFileIds(item, into, depth + 1);
  }
}

function historyMessages(history: RunRequest["history"]): ModelMessage[] {
  const messages: ModelMessage[] = (history ?? [])
    .filter((turn) => turn.text.trim() !== "")
    .slice(-MAX_HISTORY_TURNS)
    .map((turn) => ({ role: turn.role, content: truncateText(turn.text, MAX_HISTORY_TEXT) }));
  while (messages[0]?.role === "assistant") messages.shift(); // the conversation must start with the user
  return messages;
}

const notConfigured = () =>
  new AppError(503, "assistant_not_configured", "Cloud AI is not configured (set ANTHROPIC_API_KEY)");
const vaultNotConfigured = () =>
  new AppError(503, "vault_not_configured", "Vault storage is not configured (set VAULT_S3_* variables)");

/** Cloud AI runs over the vault: routing, the agent loop, long-polled events, cancel and undo. */
export class AssistantService {
  private readonly runs = new Map<string, Run>();
  private readonly router: RequestRouter;
  private readonly model: AssistantModel | null;
  private readonly maxTurns: number;
  private readonly codeExecution: boolean;
  private readonly webSearch: boolean;

  constructor(
    private readonly deps: { vault: VaultService; vaultIndex: VaultIndexService; now?: () => number },
    options: AssistantOptions = { model: null },
  ) {
    this.model = options.model;
    this.router = new RequestRouter(options.jev ?? null, options.jevModel ?? "jev-latest");
    this.maxTurns = options.maxTurns ?? DEFAULT_MAX_TURNS;
    this.codeExecution = options.codeExecution ?? true;
    this.webSearch = options.webSearch ?? false;
  }

  private now(): number {
    return (this.deps.now ?? Date.now)();
  }

  /** An API key is configured and the vault is there: cloud runs can start. */
  /** The model a new run would use (null when cloud runs are off). */
  get modelName(): string | null {
    return this.model?.model ?? null;
  }

  /** The model behind each cloud tier right now. */
  get tierModels(): Record<"small" | "medium" | "large", string> | null {
    const model = this.model;
    if (!model) return null;
    const of = (tier: "small" | "medium" | "large") => model.modelFor?.(tier) ?? model.model;
    return { small: of("small"), medium: of("medium"), large: of("large") };
  }

  get available(): boolean {
    return this.model !== null && this.deps.vault.status().configured;
  }

  async route(body: unknown): Promise<RouteDecision> {
    const { text, context, budget, deviceAvailable } = parse(routeRequestSchema, body ?? {});
    const model = this.model;
    return this.router.route(text, context, {
      cloudAvailable: this.available,
      budget,
      deviceAvailable,
      modelFor: model ? (tier) => model.modelFor?.(tier) ?? model.model : undefined,
    });
  }

  start(body: unknown): { id: string; status: RunStatus; model: string } {
    const model = this.model;
    if (!model) throw notConfigured();
    if (!this.deps.vault.status().configured) throw vaultNotConfigured();
    const request = parse(runRequestSchema, body ?? {});
    if (typeof request.rulesPath === "string") request.rulesPath = vaultPath(request.rulesPath);
    if (request.openNote !== undefined) request.openNote = vaultPath(request.openNote);
    if (request.transcriptPath !== undefined) {
      request.transcriptPath = vaultPath(request.transcriptPath);
      if (isHiddenPath(request.transcriptPath)) {
        throw new AppError(400, "invalid_path", "Invalid path: transcriptPath must not be in a dot folder");
      }
    }
    this.prune();
    const run = new Run(randomUUID(), model.modelFor?.(request.tier ?? "large") ?? model.model, this.now(), () => this.now());
    run.effort = request.effort;
    this.runs.set(run.id, run);
    run.done = this.execute(run, model, request).catch((error) => {
      // execute handles its own failures; this only guards against a bug leaving a rejected promise behind
      console.error("[assistant] run crashed", error);
      run.error ??= { code: "internal_error", message: "伺服器內部錯誤" };
      if (run.status === "running") run.status = "failed";
      run.notify();
    });
    return { id: run.id, status: run.status, model: run.model };
  }

  /** The run with the events after `after`, held up to `wait` seconds while there is nothing new. */
  async get(id: string, query: unknown, signal?: AbortSignal): Promise<RunView> {
    const run = this.find(id);
    const { after, wait } = parse(runQuerySchema, query ?? {});
    const hasNews = () => run.events.length > after || run.status !== "running";
    if (!hasNews() && wait > 0) await run.waitForChange(wait * 1000, signal);
    return run.view(after);
  }

  cancel(id: string): { status: RunStatus } {
    const run = this.find(id);
    if (run.status !== "running") return { status: run.status };
    if (run.pendingStatus) return { status: run.pendingStatus };
    run.status = "cancelled";
    run.error = { code: "cancelled", message: "已取消" };
    run.abort.abort();
    run.notify();
    return { status: run.status };
  }

  /** Undoes the run's edits (all, or `editIds`), newest first, never overwriting changes made after them. */
  async undo(id: string, body: unknown): Promise<UndoResult> {
    const run = this.find(id);
    const { editIds } = parse(undoRequestSchema, body ?? {});
    const work = run.undoChain.then(() => this.undoEdits(run, editIds));
    run.undoChain = work.catch(() => {});
    return work;
  }

  /** Resolves when the run's loop (and transcript) is done; for tests and shutdown. */
  async settled(id: string): Promise<void> {
    await this.find(id).done;
  }

  private find(id: string): Run {
    this.prune();
    const run = this.runs.get(id);
    if (!run) throw notFound("Run", id);
    return run;
  }

  private prune(): void {
    const cutoff = this.now() - RUN_TTL_MS;
    for (const [id, run] of this.runs) {
      if (run.createdAt >= cutoff) continue;
      run.abort.abort();
      this.runs.delete(id);
    }
  }

  private async execute(run: Run, model: AssistantModel, request: RunRequest): Promise<void> {
    const { vault, vaultIndex } = this.deps;
    const signal = run.abort.signal;
    const timeZone = request.timeZone ?? DEFAULT_TIME_ZONE;
    const askedAt = new Date(run.createdAt);
    let codeExecution = this.codeExecution;
    let webSearch = this.webSearch;
    const host: ToolHost = {
      emit: (event) => run.emit(event),
      addEdit: (edit) => this.addEdit(run, edit),
      addSource: (path) => run.addSource(path),
      outputFileIds: run.outputFileIds,
      signal,
    };
    const toolbox = new AssistantToolbox({ vault, vaultIndex, model }, host, { codeExecution });
    let status: RunStatus = "completed";
    try {
      const rules = await loadVaultRules(vault, request.rulesPath);
      const messages: ModelMessage[] = [...historyMessages(request.history), { role: "user", content: request.prompt }];
      let container: string | undefined;
      let retriedWithoutServerTools = false;
      let lastMessage: string | null = null;
      for (let turn = 0; ; turn += 1) {
        if (signal.aborted) throw signal.reason;
        if (turn >= this.maxTurns) {
          throw new RunFailure("max_turns", `已達到最多 ${this.maxTurns} 輪模型呼叫，工作沒有完成。`);
        }
        const context = buildRunContext({ now: askedAt, timeZone, openNote: request.openNote, rules, codeExecution, webSearch });
        let response: ModelResponse;
        try {
          response = await model.create(
            { system: SYSTEM_PROMPT, context, tools: toolbox.definitions(), codeExecution, webSearch, messages, container, model: run.model, effort: run.effort },
            { signal },
          );
        } catch (error) {
          if (signal.aborted) throw error;
          const serverTools = codeExecution || webSearch;
          if (
            serverTools &&
            !retriedWithoutServerTools &&
            error instanceof AssistantModelError &&
            error.status === 400 &&
            SERVER_TOOL_REJECTED.test(error.message)
          ) {
            console.warn("[assistant] the API rejected a server tool; retrying the run without server tools");
            retriedWithoutServerTools = true;
            codeExecution = false;
            webSearch = false;
            toolbox.setCodeExecution(false);
            turn -= 1;
            continue;
          }
          throw error;
        }
        this.addUsage(run, response);
        if (response.container?.id) container = response.container.id;
        messages.push({ role: "assistant", content: response.content as Anthropic.Beta.BetaContentBlockParam[] });

        const toolResults: Anthropic.Beta.BetaToolResultBlockParam[] = [];
        let texts: string[] = [];
        const flush = () => {
          const text = texts.join("").trim();
          texts = [];
          if (!text) return;
          lastMessage = text;
          run.emit({ type: "message", text });
        };
        for (const block of response.content) {
          if (block.type === "text") {
            texts.push(block.text);
            continue;
          }
          flush();
          if (block.type === "thinking") {
            // with display "updates", a non-empty thinking block is a progress note written between tool calls
            const note = block.thinking.trim();
            if (note && note !== INTERRUPTED_NOTE) run.emit({ type: "message", text: note });
          } else if (block.type === "server_tool_use") {
            run.emit({ type: "tool", name: block.name, summary: serverToolSummary(block.name, block.input) });
          } else if (block.type.endsWith("_tool_result")) {
            collectFileIds(block, run.outputFileIds);
          } else if (block.type === "tool_use") {
            if (response.stop_reason === "max_tokens" || signal.aborted) {
              toolResults.push({
                type: "tool_result",
                tool_use_id: block.id,
                is_error: true,
                content: signal.aborted
                  ? "cancelled"
                  : "The tool input was cut off (max_tokens). Retry with smaller input, e.g. several edit_file calls.",
              });
              continue;
            }
            run.emit({ type: "tool", name: block.name, summary: toolbox.summary(block.name, block.input) });
            const result = await toolbox.execute(block.name, block.input);
            toolResults.push({
              type: "tool_result",
              tool_use_id: block.id,
              content: result.content,
              ...(result.isError ? { is_error: true } : {}),
            });
          }
        }
        flush();
        if (signal.aborted) throw signal.reason;
        if (toolResults.length) {
          messages.push({ role: "user", content: toolResults });
          continue;
        }
        // a long server-side tool loop paused: send the turn back unchanged and the API resumes it
        if (response.stop_reason === "pause_turn") continue;
        if (response.stop_reason === "refusal") throw new RunFailure("refused", "模型拒絕了這個要求。");
        if (response.stop_reason === "model_context_window_exceeded") {
          throw new RunFailure("context_window_exceeded", "內容超過模型能處理的長度，請把工作拆小一點。");
        }
        const answer = response.content
          .flatMap((block) => (block.type === "text" ? [block.text] : []))
          .join("")
          .trim();
        run.answer = answer || lastMessage || "";
        break;
      }
      await this.addCitedSources(run);
    } catch (error) {
      status = this.recordFailure(run, error);
    }
    await this.finish(run, status, request);
  }

  /** Records why the run stopped; returns its final status. */
  private recordFailure(run: Run, error: unknown): RunStatus {
    if (run.abort.signal.aborted) {
      run.error ??= { code: "cancelled", message: "已取消" };
      return "cancelled";
    }
    let failure: RunError;
    if (error instanceof RunFailure) failure = { code: error.code, message: error.message };
    else if (error instanceof AssistantModelError) {
      failure = { code: "model_error", message: `雲端 AI 呼叫失敗${error.status ? `（HTTP ${error.status}）` : ""}：${truncateText(error.message, 300)}` };
    } else if (error instanceof AppError) failure = { code: error.code, message: error.message };
    else {
      console.error("[assistant] run failed", error);
      failure = { code: "internal_error", message: "伺服器內部錯誤" };
    }
    run.error = failure;
    run.emit({ type: "error", message: failure.message });
    return "failed";
  }

  private async finish(run: Run, status: RunStatus, request: RunRequest): Promise<void> {
    run.pendingStatus = run.status === "running" ? status : run.status;
    if (request.transcriptPath) {
      try {
        await appendTranscript(
          this.deps.vault,
          request.transcriptPath,
          {
            prompt: request.prompt,
            answer: run.pendingStatus === "completed" ? run.answer : null,
            error: run.error,
            sources: run.sources,
            edits: run.edits.map((record) => record.edit),
            askedAt: new Date(run.createdAt),
            timeZone: request.timeZone ?? DEFAULT_TIME_ZONE,
          },
          new Date(this.now()),
        );
      } catch (error) {
        console.error("[assistant] transcript append failed", error instanceof Error ? error.message : error);
        run.emit({ type: "error", message: `對話紀錄沒有寫入 ${request.transcriptPath}` });
      }
    }
    if (run.status === "running") run.status = run.pendingStatus;
    if (run.status !== "completed") run.answer = null;
    run.pendingStatus = null;
    run.notify();
  }

  private addUsage(run: Run, response: ModelResponse): void {
    const { usage } = response;
    run.usage.inputTokens += usage.input_tokens + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
    run.usage.outputTokens += usage.output_tokens;
  }

  /** [[links]] cited in the answer, resolved to vault paths, count as sources too. */
  private async addCitedSources(run: Run): Promise<void> {
    const links = extractAllLinks(run.answer ?? "");
    if (!links.length) return;
    try {
      const { resolver } = await this.deps.vaultIndex.snapshot();
      for (const target of links) {
        const path = resolver.resolve(target);
        if (path) run.addSource(path);
      }
    } catch (error) {
      console.warn("[assistant] could not resolve cited links", error instanceof Error ? error.message : error);
    }
  }

  private addEdit(run: Run, { op, path, from, summary, ...undo }: NewEdit): AssistantEdit {
    const edit: AssistantEdit = { id: `e${run.edits.length + 1}`, op, path, ...(from !== undefined ? { from } : {}), summary, undone: false };
    run.edits.push({ edit, ...undo });
    run.emit({ type: "edit", edit: { ...edit } });
    return edit;
  }

  private async undoEdits(run: Run, editIds: string[] | undefined): Promise<UndoResult> {
    const result: UndoResult = { undone: [], failed: [] };
    const selected: EditRecord[] = [];
    for (const id of editIds ?? run.edits.map((record) => record.edit.id)) {
      const record = run.edits.find((item) => item.edit.id === id);
      if (!record) result.failed.push({ id, reason: "找不到這個修改" });
      else if (!selected.includes(record)) selected.push(record);
    }
    selected.sort((a, b) => run.edits.indexOf(b) - run.edits.indexOf(a)); // newest first
    for (const record of selected) {
      const { id } = record.edit;
      if (record.edit.undone) {
        result.failed.push({ id, reason: "已經復原過了" });
        continue;
      }
      try {
        await this.undoOne(record);
        record.edit.undone = true;
        result.undone.push(id);
      } catch (error) {
        if (!(error instanceof UndoRefused || error instanceof AppError)) console.error("[assistant] undo failed", error);
        const reason = error instanceof UndoRefused || error instanceof AppError ? error.message : "復原時發生內部錯誤";
        result.failed.push({ id, reason });
      }
    }
    return result;
  }

  private async readOrNull(path: string): Promise<VaultFile | null> {
    try {
      return await this.deps.vault.read(path);
    } catch (error) {
      if (error instanceof AppError && error.status === 404) return null;
      throw error;
    }
  }

  private async undoOne({ edit, previous, previousMtime, result, trash }: EditRecord): Promise<void> {
    const { vault } = this.deps;
    const client = ASSISTANT_CLIENT_ID;
    const unchanged = (file: VaultFile) => !!result && (file.etag === result.etag || sha1(file.body) === result.hash);
    switch (edit.op) {
      case "create": {
        const current = await this.readOrNull(edit.path);
        if (!current) throw new UndoRefused(`${edit.path} 已經不存在`);
        if (!unchanged(current)) throw new UndoRefused(`${edit.path} 在 AI 建立之後又被修改過，為避免覆蓋這些修改，沒有刪除`);
        await vault.delete(current.path, { ifMatch: current.etag, client });
        return;
      }
      case "update": {
        const current = await this.readOrNull(edit.path);
        if (!current) throw new UndoRefused(`${edit.path} 已經不存在`);
        if (!unchanged(current)) throw new UndoRefused(`${edit.path} 在 AI 修改之後又被修改過，為避免覆蓋這些修改，沒有復原`);
        await vault.write(current.path, previous ?? Buffer.alloc(0), { ifMatch: current.etag, client });
        return;
      }
      case "move": {
        const from = edit.from!;
        const current = await this.readOrNull(edit.path);
        if (!current) throw new UndoRefused(`${edit.path} 已經不存在`);
        if (!unchanged(current)) throw new UndoRefused(`${edit.path} 在搬移之後又被修改過，為避免覆蓋這些修改，沒有搬回`);
        if (await this.readOrNull(from)) throw new UndoRefused(`原本的位置 ${from} 已經有其他檔案，沒有搬回`);
        const restored = await vault.write(from, current.body, { ifNoneMatch: "*", mtime: current.mtime, client });
        try {
          await vault.delete(current.path, { ifMatch: current.etag, client });
        } catch (error) {
          await vault.delete(restored.value.path, { ifMatch: restored.value.etag, client }).catch(() => {});
          throw error;
        }
        return;
      }
      case "delete": {
        if (await this.readOrNull(edit.path)) throw new UndoRefused(`原本的位置 ${edit.path} 已經有其他檔案，沒有還原`);
        const copy = trash ? await this.readOrNull(trash.path) : null;
        const copyIntact = !!copy && !!trash && (copy.etag === trash.etag || sha1(copy.body) === trash.hash);
        const body = copyIntact ? copy.body : previous;
        if (!body) throw new UndoRefused(`找不到 ${edit.path} 刪除前的內容`);
        await vault.write(edit.path, body, { ifNoneMatch: "*", ...(previousMtime ? { mtime: previousMtime } : {}), client });
        if (copyIntact) await vault.delete(copy.path, { ifMatch: copy.etag, client }).catch(() => {});
        return;
      }
    }
  }
}
