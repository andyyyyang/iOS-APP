import Anthropic from "@anthropic-ai/sdk";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import type { Express } from "express";
import request from "supertest";
import { describe, expect, it } from "vitest";
import {
  AnthropicAssistantModel,
  AssistantModelError,
  type AssistantModel,
  type ModelRequest,
  type ModelResponse,
} from "../src/assistant/index.js";
import type { ModelContentBlock } from "../src/assistant/model.js";
import { SYSTEM_PROMPT } from "../src/assistant/prompt.js";
import { ROUTE_CRITERIA, ROUTE_QUESTION } from "../src/assistant/routing.js";
import type { AssistantOptions } from "../src/assistant/service.js";
import { loadConfig } from "../src/config.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import { AUTH, setup } from "./helpers.js";

type Step = (request: ModelRequest, signal: AbortSignal) => ModelResponse | Promise<ModelResponse>;

/** A model that replays scripted responses and records every request (no network). */
class ScriptedModel implements AssistantModel {
  readonly model = "claude-test-model";
  readonly requests: ModelRequest[] = [];
  readonly files = new Map<string, { filename: string; body: Buffer }>();
  constructor(private readonly steps: Step[]) {}

  async create(request: ModelRequest, { signal }: { signal: AbortSignal }): Promise<ModelResponse> {
    this.requests.push({ ...request, messages: [...request.messages], tools: [...request.tools] });
    const step = this.steps.shift();
    if (!step) throw new Error("no scripted response left");
    return step(request, signal);
  }

  async downloadFile(fileId: string): Promise<{ filename: string; body: Buffer }> {
    const file = this.files.get(fileId);
    if (!file) throw new AssistantModelError(404, "file not found");
    return file;
  }
}

const block = (value: Record<string, unknown>) => value as unknown as ModelContentBlock;
const text = (value: string) => block({ type: "text", text: value, citations: null });
const toolUse = (id: string, name: string, input: Record<string, unknown>) => block({ type: "tool_use", id, name, input });
const reply = (content: ModelContentBlock[], stop_reason: ModelResponse["stop_reason"] = "end_turn", extra: Partial<ModelResponse> = {}): ModelResponse => ({
  content,
  stop_reason,
  usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 50, cache_creation_input_tokens: 0 },
  ...extra,
});
const respond =
  (content: ModelContentBlock[], stop_reason: ModelResponse["stop_reason"] = "end_turn", extra: Partial<ModelResponse> = {}): Step =>
  () =>
    reply(content, stop_reason, extra);

const FIXED_NOW = Date.UTC(2026, 9, 14, 12, 5, 3); // 2026-10-14 20:05:03 in Asia/Taipei

async function seed(store: MemoryVaultStore, files: Record<string, string>) {
  for (const [path, body] of Object.entries(files)) {
    await store.write(path, Buffer.from(body, "utf8"), { mtime: 1_760_000_000_000, contentType: "text/markdown" });
  }
}

async function readText(store: MemoryVaultStore, path: string): Promise<string | null> {
  const file = await store.read(path);
  return file ? file.body.toString("utf8") : null;
}

async function assistantApp(
  files: Record<string, string>,
  assistant: Partial<AssistantOptions> & { model: AssistantModel | null },
  options: { now?: () => number } = {},
) {
  const store = new MemoryVaultStore();
  await seed(store, files);
  const { app } = await setup({ vault: store, assistant, now: options.now });
  return { app, store };
}

async function start(app: Express, body: Record<string, unknown>): Promise<string> {
  const res = await request(app).post("/v1/assistant/runs").set(AUTH).send(body).expect(202);
  return res.body.id as string;
}

/** Long-polls the run until it leaves "running"; returns the final view with every event. */
async function finish(app: Express, id: string) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const res = await request(app).get(`/v1/assistant/runs/${id}`).query({ after: 0, wait: 0 }).set(AUTH).expect(200);
    if (res.body.status !== "running") return res.body;
    const last = res.body.events.at(-1)?.seq ?? 0;
    await request(app).get(`/v1/assistant/runs/${id}`).query({ after: last, wait: 2 }).set(AUTH).expect(200);
  }
  throw new Error("run did not finish");
}

/** tool_use_id → tool_result of the request's last (user) message. */
function toolResults(model: ScriptedModel, index: number): Record<string, { content: string; is_error?: boolean }> {
  const last = model.requests[index]!.messages.at(-1)!;
  const content = last.content as { type: string; tool_use_id: string; content: string; is_error?: boolean }[];
  return Object.fromEntries(content.filter((item) => item.type === "tool_result").map((item) => [item.tool_use_id, item]));
}

async function waitFor(condition: () => boolean) {
  for (let attempt = 0; attempt < 200 && !condition(); attempt += 1) await new Promise((resolve) => setTimeout(resolve, 5));
  if (!condition()) throw new Error("condition not met");
}

describe("POST /v1/assistant/route", () => {
  it("uses the keyword heuristic without Jev", async () => {
    const { app } = await assistantApp({}, { model: new ScriptedModel([]) });
    const route = async (body: object) => (await request(app).post("/v1/assistant/route").set(AUTH).send(body).expect(200)).body;
    expect(await route({ text: "幫我整理這個資料夾" })).toEqual({
      kind: "task",
      route: "cloud",
      confidence: 0.6,
      provider: "heuristic",
      cloudAvailable: true,
    });
    expect(await route({ text: "建立一個新資料夾放照片" })).toMatchObject({ kind: "task", route: "cloud" });
    expect(await route({ text: "記下明天十點開會", context: "Inbox.md" })).toMatchObject({ kind: "edit", route: "device" });
    expect(await route({ text: "上週的會議說了什麼？" })).toMatchObject({ kind: "question", route: "device", confidence: 0.6 });
    const invalid = await request(app).post("/v1/assistant/route").set(AUTH).send({ text: "  " }).expect(400);
    expect(invalid.body.error.code).toBe("invalid_request");
    await request(app).post("/v1/assistant/route").send({ text: "x" }).expect(401);

    const offline = await setup({ vault: new MemoryVaultStore() });
    const res = await request(offline.app).post("/v1/assistant/route").set(AUTH).send({ text: "把所有會議紀錄彙整成表格" }).expect(200);
    expect(res.body).toEqual({ kind: "task", route: "device", confidence: 0.6, provider: "heuristic", cloudAvailable: false });
  });

  it("asks Jev and falls back to the heuristic when Jev fails", async () => {
    const bodies: any[] = [];
    let answer: { choice: string; confidence: number } | null = { choice: "task", confidence: 0.4 };
    const jev = new TypeSafeClient({
      apiKey: "test",
      logLevel: "off",
      retry: { maxRetries: 0 },
      fetch: async (_url, init) => {
        bodies.push(JSON.parse(String(init?.body)));
        if (!answer) return new Response(JSON.stringify({ error: "boom" }), { status: 500 });
        return new Response(
          JSON.stringify({
            model: "jev-latest",
            answers: { kind: { type: "choice", ...answer, probabilities: { question: 0.1, edit: 0.1, task: 0.8 } } },
            usage: { input_tokens: 1, output_tokens: 1 },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });
    const { app } = await assistantApp({}, { model: new ScriptedModel([]), jev, jevModel: "jev-latest" });
    const route = async (body: object) => (await request(app).post("/v1/assistant/route").set(AUTH).send(body).expect(200)).body;

    expect(await route({ text: "整理這個資料夾", context: "Projects/" })).toEqual({
      kind: "task",
      route: "device",
      confidence: 0.4,
      provider: "jev",
      cloudAvailable: true,
    });
    expect(bodies[0]).toEqual({
      model: "jev-latest",
      state: { request: "整理這個資料夾", context: "Projects/" },
      questions: { kind: { type: "choice", instructions: ROUTE_QUESTION, criteria: ROUTE_CRITERIA } },
    });
    answer = { choice: "task", confidence: 0.8 };
    expect(await route({ text: "這些筆記" })).toMatchObject({ kind: "task", route: "cloud", provider: "jev", confidence: 0.8 });
    answer = { choice: "question", confidence: 0.9 };
    expect(await route({ text: "整理" })).toMatchObject({ kind: "question", route: "device", provider: "jev" });
    answer = null;
    expect(await route({ text: "幫我分類這些筆記" })).toEqual({
      kind: "task",
      route: "cloud",
      confidence: 0.6,
      provider: "heuristic",
      cloudAvailable: true,
    });
  });
});

describe("assistant runs: configuration and validation", () => {
  it("answers 503 without an API key or a vault, 400 for bad bodies and 404 for unknown runs", async () => {
    const noKey = await setup({ vault: new MemoryVaultStore() });
    const res = await request(noKey.app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "整理" }).expect(503);
    expect(res.body.error).toEqual({ code: "assistant_not_configured", message: "Cloud AI is not configured (set ANTHROPIC_API_KEY)" });
    const health = await request(noKey.app).get("/health").expect(200);
    expect(health.body.assistant).toBe(false);

    const noVault = await setup({ assistant: { model: new ScriptedModel([]) } });
    const vaultRes = await request(noVault.app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "整理" }).expect(503);
    expect(vaultRes.body.error.code).toBe("vault_not_configured");
    expect((await request(noVault.app).get("/health")).body.assistant).toBe(false);

    const { app } = await assistantApp({}, { model: new ScriptedModel([]) });
    expect((await request(app).get("/health")).body.assistant).toBe(true);
    for (const body of [
      {},
      { prompt: "" },
      { prompt: 5 },
      { prompt: "x", history: [{ role: "system", text: "x" }] },
      { prompt: "x", timeZone: "Mars/Olympus" },
      { prompt: "x", rulesPath: 3 },
    ]) {
      const bad = await request(app).post("/v1/assistant/runs").set(AUTH).send(body);
      expect(bad.status, JSON.stringify(body)).toBe(400);
      expect(bad.body.error.code).toBe("invalid_request");
    }
    const badPath = await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "x", transcriptPath: "../x.md" }).expect(400);
    expect(badPath.body.error.code).toBe("invalid_path");
    await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "x", transcriptPath: ".obsidian/chat.md" }).expect(400);

    const missing = await request(app).get("/v1/assistant/runs/nope").set(AUTH).expect(404);
    expect(missing.body.error.code).toBe("not_found");
    await request(app).post("/v1/assistant/runs/nope/cancel").set(AUTH).expect(404);
    await request(app).post("/v1/assistant/runs/nope/undo").set(AUTH).send({}).expect(404);
    await request(app).get("/v1/assistant/runs/nope").expect(401);
  });
});

describe("assistant runs", () => {
  it("runs the agent loop and long-polls events", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const model = new ScriptedModel([
      respond([text("先搜尋相關筆記。"), toolUse("t1", "search_notes", { query: "會議" })], "tool_use"),
      async () => {
        await gate;
        return reply([text("找到了 [[週會]]"), text("，重點如下。")]);
      },
    ]);
    const { app } = await assistantApp({ "工作/週會.md": "本週會議紀錄" }, { model });

    const started = await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "會議說了什麼？", openNote: "工作/週會.md" }).expect(202);
    expect(started.body).toEqual({ id: expect.any(String), status: "running", model: "claude-test-model" });
    const id = started.body.id;

    await waitFor(() => model.requests.length === 2);
    const first = await request(app).get(`/v1/assistant/runs/${id}`).set(AUTH).expect(200);
    expect(first.body).toMatchObject({ id, status: "running", model: "claude-test-model", answer: null, error: null, edits: [] });
    expect(first.body.events).toEqual([
      { seq: 1, at: expect.stringMatching(/^\d{4}-\d\d-\d\dT/), type: "message", text: "先搜尋相關筆記。" },
      { seq: 2, at: expect.any(String), type: "tool", name: "search_notes", summary: "搜尋「會議」" },
    ]);

    // nothing new: held for `wait` seconds, then answered with no events
    const idle = Date.now();
    const empty = await request(app).get(`/v1/assistant/runs/${id}`).query({ after: 2, wait: 0.2 }).set(AUTH).expect(200);
    expect(Date.now() - idle).toBeGreaterThanOrEqual(150);
    expect(empty.body).toMatchObject({ status: "running", events: [] });

    // a held poll is answered as soon as the next event arrives
    setTimeout(release, 100);
    const held = Date.now();
    const next = await request(app).get(`/v1/assistant/runs/${id}`).query({ after: 2, wait: 10 }).set(AUTH).expect(200);
    expect(Date.now() - held).toBeLessThan(5000);
    expect(next.body.events[0]).toMatchObject({ seq: 3, type: "message", text: "找到了 [[週會]]，重點如下。" });

    const done = await finish(app, id);
    expect(done).toMatchObject({
      status: "completed",
      answer: "找到了 [[週會]]，重點如下。",
      error: null,
      sources: ["工作/週會.md"],
      usage: { inputTokens: 300, outputTokens: 40 },
    });
    expect(done.events.map((event: { seq: number }) => event.seq)).toEqual([1, 2, 3]);

    // what the model saw
    const [request1, request2] = model.requests;
    expect(request1!.system).toBe(SYSTEM_PROMPT);
    expect(request1!.context).toContain("今天是");
    expect(request1!.context).toContain("[[週會]]（路徑 工作/週會.md）");
    expect(request1!.codeExecution).toBe(true);
    expect(request1!.webSearch).toBe(false);
    expect(request1!.tools.map((tool) => tool.name)).toEqual([
      "list_files", "read_file", "search_notes", "get_links", "write_file", "edit_file", "move_file", "delete_file", "save_output",
    ]);
    expect(request1!.messages).toEqual([{ role: "user", content: "會議說了什麼？" }]);
    expect(request2!.messages).toHaveLength(3);
    expect(request2!.messages[1]!.role).toBe("assistant");
    const results = toolResults(model, 1);
    expect(JSON.parse(results.t1!.content).items[0]).toMatchObject({ path: "工作/週會.md" });
  });

  it("caps the history it sends", async () => {
    const model = new ScriptedModel([respond([text("好")])]);
    const { app } = await assistantApp({}, { model });
    const history = Array.from({ length: 15 }, (_, index) => ({
      role: index % 2 === 0 ? "user" : "assistant",
      text: index === 13 ? "長".repeat(5000) : `turn ${index}`,
    }));
    const id = await start(app, { prompt: "繼續", history, rulesPath: null });
    await finish(app, id);
    const messages = model.requests[0]!.messages;
    // the newest 12 turns (3–14) minus the leading assistant turn 3, then the prompt
    expect(messages.map((message) => message.content).slice(0, 2)).toEqual(["turn 4", "turn 5"]);
    expect(messages[0]!.role).toBe("user");
    expect(messages).toHaveLength(12);
    expect(messages.at(-3)!.content).toHaveLength(4000);
    expect(messages.at(-1)).toEqual({ role: "user", content: "繼續" });
  });

  it("executes vault tools, retargets links on move, and undoes everything", async () => {
    const files = {
      "Projects/Plan.md": "---\naliases: [計畫]\n---\n# Plan\nGoals here\n",
      "A.md": "See [[Plan]] and [[Projects/Plan#Goals|目標]]\n![[Projects/Plan]]\n",
      "B.md": "alias [[計畫]] and [[plan|別名]]\n",
      "Notes/Todo.md": "- [ ] one\n- [ ] two\n",
      "old.md": "old content",
    };
    const model = new ScriptedModel([
      respond(
        [
          toolUse("w0", "write_file", { path: "Notes/Todo.md", content: "x" }),
          toolUse("r1", "read_file", { path: "Notes/Todo.md" }),
          toolUse("bad", "read_file", { path: "/abs.md" }),
        ],
        "tool_use",
      ),
      respond(
        [
          toolUse("e1", "edit_file", { path: "Notes/Todo.md", old_text: "- [ ]", new_text: "- [x]" }),
          toolUse("e2", "edit_file", { path: "Notes/Todo.md", old_text: "- [ ]", new_text: "- [x]", replace_all: true }),
          toolUse("e3", "edit_file", { path: "Notes/Todo.md", old_text: "missing", new_text: "y" }),
          toolUse("w1", "write_file", { path: "Notes/New.md", content: "# New\n" }),
        ],
        "tool_use",
      ),
      respond(
        [
          text("接著搬移計畫並清掉舊檔。"),
          toolUse("m1", "move_file", { from: "Projects/Plan.md", to: "Archive/Plan 2026.md" }),
          toolUse("d1", "delete_file", { path: "old.md" }),
          toolUse("h1", "write_file", { path: ".obsidian/x.md", content: "x" }),
          toolUse("l1", "get_links", { path: "Archive/Plan 2026.md" }),
          toolUse("ls", "list_files", {}),
        ],
        "tool_use",
      ),
      respond([text("完成：整理了 [[Todo]]。")]),
    ]);
    const { app, store } = await assistantApp(files, { model });
    const before = (await request(app).get("/v1/vault/changes").set(AUTH).expect(200)).body.cursor;

    const id = await start(app, { prompt: "整理筆記" });
    const done = await finish(app, id);
    expect(done.status).toBe("completed");

    const step1 = toolResults(model, 1);
    expect(step1.w0).toMatchObject({ is_error: true, content: expect.stringContaining("read_file") });
    expect(step1.r1!.is_error).toBeUndefined();
    expect(step1.r1!.content).toContain("- [ ] one\n- [ ] two");
    expect(step1.bad).toMatchObject({ is_error: true, content: expect.stringContaining("invalid_path") });
    const step2 = toolResults(model, 2);
    expect(step2.e1).toMatchObject({ is_error: true, content: expect.stringContaining("出現 2 次") });
    expect(step2.e2!.content).toContain("取代 2 處");
    expect(step2.e3).toMatchObject({ is_error: true, content: expect.stringContaining("找不到") });
    const step3 = toolResults(model, 3);
    expect(step3.m1!.content).toContain("已更新 2 則筆記中的連結");
    expect(step3.h1).toMatchObject({ is_error: true });
    expect(JSON.parse(step3.l1!.content)).toEqual({ path: "Archive/Plan 2026.md", outgoing: [], backlinks: ["A.md", "B.md"] });
    expect(JSON.parse(step3.ls!.content)).toEqual({
      folder: "/",
      folders: ["Archive/", "Notes/"],
      files: [expect.objectContaining({ path: "A.md" }), expect.objectContaining({ path: "B.md" })],
    });

    expect(await readText(store, "Notes/Todo.md")).toBe("- [x] one\n- [x] two\n");
    expect(await readText(store, "Notes/New.md")).toBe("# New\n");
    expect(await readText(store, "Projects/Plan.md")).toBeNull();
    expect(await readText(store, "Archive/Plan 2026.md")).toBe(files["Projects/Plan.md"]);
    expect(await readText(store, "A.md")).toBe("See [[Plan 2026]] and [[Archive/Plan 2026#Goals|目標]]\n![[Archive/Plan 2026]]\n");
    expect(await readText(store, "B.md")).toBe("alias [[計畫]] and [[Plan 2026|別名]]\n");
    expect(await readText(store, "old.md")).toBeNull();
    expect(await readText(store, ".trash/old.md")).toBe("old content");

    expect(done.edits).toEqual([
      { id: "e1", op: "update", path: "Notes/Todo.md", summary: "修改 Notes/Todo.md", undone: false },
      { id: "e2", op: "create", path: "Notes/New.md", summary: "新增 Notes/New.md", undone: false },
      { id: "e3", op: "move", path: "Archive/Plan 2026.md", from: "Projects/Plan.md", summary: "搬移 Projects/Plan.md → Archive/Plan 2026.md", undone: false },
      { id: "e4", op: "update", path: "A.md", summary: "更新 A.md 中指向 Plan 2026 的連結", undone: false },
      { id: "e5", op: "update", path: "B.md", summary: "更新 B.md 中指向 Plan 2026 的連結", undone: false },
      { id: "e6", op: "delete", path: "old.md", summary: "刪除 old.md（移到 .trash）", undone: false },
    ]);
    const kinds = done.events.map((event: any) =>
      event.type === "tool" ? `tool:${event.summary}` : event.type === "edit" ? `edit:${event.edit.id}` : event.type,
    );
    expect(kinds).toEqual([
      "tool:寫入 Notes/Todo.md",
      "tool:讀取 Notes/Todo.md",
      "tool:讀取 /abs.md",
      "tool:修改 Notes/Todo.md",
      "tool:修改 Notes/Todo.md",
      "edit:e1",
      "tool:修改 Notes/Todo.md",
      "tool:寫入 Notes/New.md",
      "edit:e2",
      "message",
      "tool:搬移 Projects/Plan.md → Archive/Plan 2026.md",
      "edit:e3",
      "edit:e4",
      "edit:e5",
      "tool:刪除 old.md",
      "edit:e6",
      "tool:寫入 .obsidian/x.md",
      "tool:查看 Archive/Plan 2026.md 的連結",
      "tool:列出 根目錄",
      "message",
    ]);
    expect(done.sources).toEqual(["Notes/Todo.md"]);

    // every write went through the change feed as "assistant"
    const changes = (await request(app).get("/v1/vault/changes").query({ since: before }).set(AUTH).expect(200)).body.changes;
    expect(changes.length).toBeGreaterThan(0);
    expect(new Set(changes.map((change: { client: string }) => change.client))).toEqual(new Set(["assistant"]));

    // undo everything, newest first
    const undo = await request(app).post(`/v1/assistant/runs/${id}/undo`).set(AUTH).send({}).expect(200);
    expect(undo.body).toEqual({ undone: ["e6", "e5", "e4", "e3", "e2", "e1"], failed: [] });
    for (const [path, body] of Object.entries(files)) expect(await readText(store, path)).toBe(body);
    expect(await readText(store, "Notes/New.md")).toBeNull();
    expect(await readText(store, "Archive/Plan 2026.md")).toBeNull();
    expect(await readText(store, ".trash/old.md")).toBeNull();
    const after = await request(app).get(`/v1/assistant/runs/${id}`).set(AUTH).expect(200);
    expect(after.body.edits.every((edit: { undone: boolean }) => edit.undone)).toBe(true);

    const again = await request(app).post(`/v1/assistant/runs/${id}/undo`).set(AUTH).send({ editIds: ["e1", "zz"] }).expect(200);
    expect(again.body).toEqual({
      undone: [],
      failed: [
        { id: "zz", reason: "找不到這個修改" },
        { id: "e1", reason: "已經復原過了" },
      ],
    });
  });

  it("refuses to undo over changes made after the AI's edit", async () => {
    const model = new ScriptedModel([
      respond(
        [
          toolUse("w1", "write_file", { path: "AI.md", content: "AI draft" }),
          toolUse("e1", "edit_file", { path: "Note.md", old_text: "v1", new_text: "v2" }),
        ],
        "tool_use",
      ),
      respond([text("done")]),
    ]);
    const { app, store } = await assistantApp({ "Note.md": "v1" }, { model });
    const id = await start(app, { prompt: "寫草稿" });
    await finish(app, id);
    await request(app).put("/v1/vault/file").query({ path: "AI.md" }).set(AUTH).set("Content-Type", "text/plain").send("user edited").expect(200);

    const refused = await request(app).post(`/v1/assistant/runs/${id}/undo`).set(AUTH).send({ editIds: ["e1", "e2"] }).expect(200);
    expect(refused.body.undone).toEqual(["e2"]);
    expect(refused.body.failed).toEqual([{ id: "e1", reason: expect.stringContaining("又被修改過") }]);
    expect(await readText(store, "AI.md")).toBe("user edited");
    expect(await readText(store, "Note.md")).toBe("v1");
  });

  it("cancels a run in flight and records the turn in the transcript", async () => {
    const model = new ScriptedModel([
      (_request, signal) =>
        new Promise<ModelResponse>((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true })),
    ]);
    const { app, store } = await assistantApp({}, { model }, { now: () => FIXED_NOW });
    const id = await start(app, { prompt: "做很久的事", transcriptPath: "AI/對話.md" });
    await waitFor(() => model.requests.length === 1);

    const cancelled = await request(app).post(`/v1/assistant/runs/${id}/cancel`).set(AUTH).expect(200);
    expect(cancelled.body).toEqual({ status: "cancelled" });
    const done = await finish(app, id);
    expect(done).toMatchObject({ status: "cancelled", answer: null, error: { code: "cancelled", message: "已取消" } });
    // the transcript is appended once the aborted model call has unwound
    for (let attempt = 0; attempt < 100 && (await readText(store, "AI/對話.md")) === null; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect(await readText(store, "AI/對話.md")).toBe(
      "---\ntype: ai-chat\ncreated: 2026-10-14T20:05:03+08:00\ntags: [ai-chat]\n---\n\n" +
        "## 🙋 2026-10-14 20:05\n做很久的事\n\n## 🤖 雲端 AI\n（沒有完成：已取消）\n",
    );
    expect((await request(app).post(`/v1/assistant/runs/${id}/cancel`).set(AUTH).expect(200)).body).toEqual({ status: "cancelled" });
  });

  it("appends each turn to the transcript in the documented format", async () => {
    const model = new ScriptedModel([
      respond(
        [
          toolUse("r1", "read_file", { path: "工作/週報.md" }),
          toolUse("w1", "write_file", { path: "整理/摘要.md", content: "摘要" }),
          toolUse("e1", "edit_file", { path: "工作/週報.md", old_text: "草稿", new_text: "定稿" }),
          toolUse("m1", "move_file", { from: "舊/a.md", to: "新/b.md" }),
          toolUse("d1", "delete_file", { path: "垃圾.md" }),
        ],
        "tool_use",
      ),
      respond([text("已整理完成，參考 [[週報]]。")]),
      respond([text("答案二")]),
      () => {
        throw new AssistantModelError(500, "overloaded");
      },
    ]);
    const { app, store } = await assistantApp(
      { "工作/週報.md": "草稿", "舊/a.md": "a", "垃圾.md": "x" },
      { model },
      { now: () => FIXED_NOW },
    );
    const transcriptPath = "AI 對話/2026-10-14.md";
    await finish(app, await start(app, { prompt: "整理一下", transcriptPath, timeZone: "Asia/Taipei" }));
    const first =
      "---\ntype: ai-chat\ncreated: 2026-10-14T20:05:03+08:00\ntags: [ai-chat]\n---\n\n" +
      "## 🙋 2026-10-14 20:05\n整理一下\n\n## 🤖 雲端 AI\n已整理完成，參考 [[週報]]。\n\n" +
      "> 來源：[[週報]]\n> 修改：新增 [[摘要]]；修改 [[週報]]；搬移 [[a]] → [[b]]；刪除 [[垃圾]]\n";
    expect(await readText(store, transcriptPath)).toBe(first);

    await finish(app, await start(app, { prompt: "第二個問題", transcriptPath }));
    const second = `${first}\n## 🙋 2026-10-14 20:05\n第二個問題\n\n## 🤖 雲端 AI\n答案二\n`;
    expect(await readText(store, transcriptPath)).toBe(second);

    const failed = await finish(app, await start(app, { prompt: "第三個", transcriptPath, timeZone: "America/New_York" }));
    expect(failed).toMatchObject({ status: "failed", answer: null, error: { code: "model_error" } });
    expect(failed.events.at(-1)).toMatchObject({ type: "error", message: failed.error.message });
    expect(await readText(store, transcriptPath)).toBe(
      `${second}\n## 🙋 2026-10-14 08:05\n第三個\n\n## 🤖 雲端 AI\n（沒有完成：${failed.error.message}）\n`,
    );
    expect(failed.error.message).toContain("HTTP 500");
  });

  it("resumes pause_turn responses and saves sandbox output files", async () => {
    const model = new ScriptedModel([
      respond(
        [text("先算一下。"), block({ type: "server_tool_use", id: "srv1", name: "bash_code_execution", input: { command: "python make.py" } })],
        "pause_turn",
        { container: { id: "cnt_1" } },
      ),
      respond(
        [
          block({
            type: "bash_code_execution_tool_result",
            tool_use_id: "srv1",
            content: {
              type: "bash_code_execution_result",
              stdout: "ok",
              stderr: "",
              return_code: 0,
              content: [{ type: "bash_code_execution_output", file_id: "file_abc" }],
            },
          }),
          toolUse("s0", "save_output", { file_id: "file_other", path: "報表/x.csv" }),
          toolUse("s1", "save_output", { file_id: "file_abc", path: "報表/out.csv" }),
        ],
        "tool_use",
      ),
      respond([text("完成")]),
    ]);
    model.files.set("file_abc", { filename: "out.csv", body: Buffer.from([0xef, 0xbb, 0xbf, 0x61, 0x2c, 0x62, 0x00]) });
    const { app, store } = await assistantApp({}, { model });
    const done = await finish(app, await start(app, { prompt: "做報表" }));
    expect(done.status).toBe("completed");

    // pause_turn: the paused assistant turn goes back as is, with no extra user message
    const resumed = model.requests[1]!;
    expect(resumed.messages).toHaveLength(2);
    expect(resumed.messages[1]!.role).toBe("assistant");
    expect(resumed.container).toBe("cnt_1");
    expect(toolResults(model, 2).s0).toMatchObject({ is_error: true, content: expect.stringContaining("Unknown file_id") });

    const saved = await store.read("報表/out.csv");
    expect(saved!.body).toEqual(Buffer.from([0xef, 0xbb, 0xbf, 0x61, 0x2c, 0x62, 0x00]));
    const summary = done.events.map((event: any) => [event.type, event.summary ?? event.text ?? event.path ?? event.edit?.op]);
    expect(summary).toEqual([
      ["message", "先算一下。"],
      ["tool", "執行程式"],
      ["tool", "儲存 報表/x.csv"],
      ["tool", "儲存 報表/out.csv"],
      ["file", "報表/out.csv"],
      ["edit", "create"],
      ["message", "完成"],
    ]);
  });

  it("retries once without server tools when the API rejects one", async () => {
    const model = new ScriptedModel([
      () => {
        throw new AssistantModelError(400, "tools.9: code_execution_20260521 is not available for this model");
      },
      respond([text("ok")]),
    ]);
    const { app } = await assistantApp({}, { model, webSearch: true });
    const done = await finish(app, await start(app, { prompt: "算一下" }));
    expect(done).toMatchObject({ status: "completed", answer: "ok" });
    expect(model.requests.map((req) => [req.codeExecution, req.webSearch])).toEqual([
      [true, true],
      [false, false],
    ]);
    expect(model.requests[1]!.tools.some((tool) => tool.name === "save_output")).toBe(false);
    expect(model.requests[1]!.context).toContain("沒有程式沙盒");

    const other = new ScriptedModel([
      () => {
        throw new AssistantModelError(400, "messages: invalid");
      },
    ]);
    const failing = await assistantApp({}, { model: other });
    const failed = await finish(failing.app, await start(failing.app, { prompt: "x" }));
    expect(failed).toMatchObject({ status: "failed", error: { code: "model_error" } });
    expect(other.requests).toHaveLength(1);
  });

  it("stops after ASSISTANT_MAX_TURNS model calls", async () => {
    const loop = () => reply([toolUse(`t${Math.random()}`, "list_files", {})], "tool_use");
    const model = new ScriptedModel([loop, loop, loop]);
    const { app } = await assistantApp({}, { model, maxTurns: 2, codeExecution: false });
    const done = await finish(app, await start(app, { prompt: "一直列" }));
    expect(done).toMatchObject({ status: "failed", error: { code: "max_turns" } });
    expect(model.requests).toHaveLength(2);
    expect(model.requests[0]!.tools.some((tool) => tool.name === "save_output")).toBe(false);
  });

  it("loads the vault's editing rules into the prompt", async () => {
    const rules = { "AGENTS.md": "日期一律寫成 YYYY-MM-DD", "docs/rules.md": "自訂規則", "我的寫作規則.md": "備用規則" };
    const contexts = async (files: Record<string, string>, body: Record<string, unknown>) => {
      const model = new ScriptedModel([respond([text("好")])]);
      const { app } = await assistantApp(files, { model });
      await finish(app, await start(app, { prompt: "x", ...body }));
      return model.requests[0]!.context;
    };
    const auto = await contexts(rules, {});
    expect(auto).toContain('<vault_rules path="AGENTS.md">\n日期一律寫成 YYYY-MM-DD\n</vault_rules>');
    expect(auto).toContain("必須遵守");
    expect(await contexts(rules, { rulesPath: null })).not.toContain("vault_rules");
    expect(await contexts(rules, { rulesPath: "docs/rules.md" })).toContain("自訂規則");
    expect(await contexts({ "我的寫作規則.md": "備用規則", "Other.md": "x" }, {})).toContain('<vault_rules path="我的寫作規則.md">');
    expect(await contexts({ "_VAULT 規範.md": "命名規範", "Other.md": "x" }, {})).toContain('<vault_rules path="_VAULT 規範.md">');
    const long = await contexts({ "rules.md": "規".repeat(25_000) }, {});
    expect(long).toContain("只列出前面的部分");
    expect(long.match(/規/g)!.length).toBeGreaterThanOrEqual(20_000);
    expect(long.match(/規/g)!.length).toBeLessThan(20_010);
  });
});

describe("AnthropicAssistantModel (official SDK, fake transport)", () => {
  const sse = (events: Record<string, unknown>[]) =>
    events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("");

  it("streams a request with caching, server tools and betas, dropping a rejected optional feature", async () => {
    const calls: { url: string; headers: Headers; body: any }[] = [];
    const fetch = async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
      if (calls.length === 1) {
        return new Response(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "fallbacks: not supported" } }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(
        sse([
          {
            type: "message_start",
            message: {
              id: "msg_1",
              type: "message",
              role: "assistant",
              model: "claude-opus-5-5",
              content: [],
              stop_reason: null,
              stop_sequence: null,
              usage: { input_tokens: 10, output_tokens: 1 },
            },
          },
          { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
          { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "你好" } },
          { type: "content_block_stop", index: 0 },
          { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } },
          { type: "message_stop" },
        ]),
        { status: 200, headers: { "content-type": "text/event-stream" } },
      );
    };
    const client = new Anthropic({ apiKey: "test-key", fetch: fetch as typeof globalThis.fetch, maxRetries: 0 });
    const model = new AnthropicAssistantModel({ model: "claude-opus-5-5", client });
    const response = await model.create(
      {
        system: "fixed",
        context: "today",
        tools: [{ name: "read_file", description: "d", input_schema: { type: "object", properties: {} } }],
        codeExecution: true,
        webSearch: true,
        messages: [{ role: "user", content: "hi" }],
        container: "cnt_9",
      },
      { signal: new AbortController().signal },
    );
    expect(response.stop_reason).toBe("end_turn");
    expect(response.content).toEqual([expect.objectContaining({ type: "text", text: "你好" })]);

    expect(calls).toHaveLength(2);
    const [rejected, sent] = calls;
    expect(rejected!.body.fallbacks).toBe("default");
    expect(rejected!.headers.get("anthropic-beta")).toContain("server-side-fallback-2026-07-01");
    expect(sent!.url).toContain("/v1/messages");
    expect(sent!.body.fallbacks).toBeUndefined();
    expect(sent!.headers.get("anthropic-beta")).toBe("thinking-display-updates-2026-08-18");
    expect(sent!.body).toMatchObject({
      model: "claude-opus-5-5",
      stream: true,
      max_tokens: 32000,
      thinking: { type: "adaptive", display: "updates" },
      output_config: { effort: "high" },
      cache_control: { type: "ephemeral" },
      system: [
        { type: "text", text: "fixed", cache_control: { type: "ephemeral" } },
        { type: "text", text: "today" },
      ],
      container: "cnt_9",
      messages: [{ role: "user", content: "hi" }],
    });
    expect(sent!.body.tools.map((tool: { name: string; type?: string }) => tool.type ?? tool.name)).toEqual([
      "read_file",
      "code_execution_20260521",
      "web_search_20250305",
    ]);
    expect(model.params({ system: "", context: "", tools: [], codeExecution: false, webSearch: true, messages: [] }).tools).toEqual([
      { type: "web_search_20260209", name: "web_search", max_uses: 10 },
    ]);

    // other API errors surface as AssistantModelError
    const failing = new AnthropicAssistantModel({
      model: "claude-opus-5-5",
      client: new Anthropic({
        apiKey: "test-key",
        maxRetries: 0,
        fetch: (async () =>
          new Response(JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "busy" } }), {
            status: 529,
            headers: { "content-type": "application/json" },
          })) as typeof globalThis.fetch,
      }),
    });
    await expect(
      failing.create({ system: "", context: "", tools: [], codeExecution: false, webSearch: false, messages: [{ role: "user", content: "x" }] }, {
        signal: new AbortController().signal,
      }),
    ).rejects.toMatchObject({ name: "AssistantModelError", status: 529 });
  });

  it("downloads sandbox files through the Files API", async () => {
    const urls: string[] = [];
    const fetch = async (url: string | URL | Request) => {
      urls.push(String(url));
      if (String(url).endsWith("/content")) return new Response(Buffer.from("a,b\n"), { status: 200 });
      return new Response(
        JSON.stringify({ id: "file_1", type: "file", filename: "out.csv", mime_type: "text/csv", size_bytes: 4, created_at: "2026-10-14T00:00:00Z" }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    };
    const model = new AnthropicAssistantModel({
      model: "claude-opus-5-5",
      client: new Anthropic({ apiKey: "test-key", fetch: fetch as typeof globalThis.fetch, maxRetries: 0 }),
    });
    const file = await model.downloadFile("file_1");
    expect(file).toEqual({ filename: "out.csv", body: Buffer.from("a,b\n") });
    expect(urls.sort()).toEqual([expect.stringMatching(/\/v1\/files\/file_1$/), expect.stringMatching(/\/v1\/files\/file_1\/content$/)]);
  });
});

describe("OpenAPI", () => {
  it("describes the index and assistant endpoints with resolvable refs", async () => {
    const { app } = await setup();
    const res = await request(app).get("/v1/openapi.json").set(AUTH).expect(200);
    for (const path of [
      "/v1/vault/index",
      "/v1/assistant/route",
      "/v1/assistant/runs",
      "/v1/assistant/runs/{id}",
      "/v1/assistant/runs/{id}/cancel",
      "/v1/assistant/runs/{id}/undo",
    ]) {
      expect(res.body.paths[path], path).toBeDefined();
    }
    expect(res.body.components.schemas.Health.properties.assistant).toBeDefined();
    const refs = JSON.stringify(res.body).match(/"#\/components\/schemas\/[^"]+"/g) ?? [];
    for (const ref of new Set(refs)) {
      expect(res.body.components.schemas[ref.slice(22, -1)], ref).toBeDefined();
    }
  });
});

describe("assistant config", () => {
  it("reads the ASSISTANT_* variables", () => {
    const quiet = { warn() {} };
    expect(loadConfig({ NODE_ENV: "test" }, quiet)).toMatchObject({
      anthropicApiKey: undefined,
      assistantModel: "claude-opus-5-5",
      assistantMaxTurns: 40,
      assistantCodeExecution: true,
      assistantWebSearch: false,
    });
    expect(
      loadConfig(
        {
          NODE_ENV: "test",
          ANTHROPIC_API_KEY: " sk-test ",
          ASSISTANT_MODEL: "claude-sonnet-5-5",
          ASSISTANT_MAX_TURNS: "5",
          ASSISTANT_CODE_EXECUTION: "0",
          ASSISTANT_WEB_SEARCH: "1",
        },
        quiet,
      ),
    ).toMatchObject({
      anthropicApiKey: "sk-test",
      assistantModel: "claude-sonnet-5-5",
      assistantMaxTurns: 5,
      assistantCodeExecution: false,
      assistantWebSearch: true,
    });
    expect(() => loadConfig({ NODE_ENV: "test", ASSISTANT_MAX_TURNS: "0" }, quiet)).toThrow(/ASSISTANT_MAX_TURNS/);
  });
});
