import Anthropic from "@anthropic-ai/sdk";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import request from "supertest";
import { describe, expect, it } from "vitest";
import { shared } from "../src/assistant/catalog.js";
import { AnthropicAssistantModel, type AssistantModel, type ModelRequest, type ModelResponse } from "../src/assistant/index.js";
import { DIFFICULTY_CRITERIA, DIFFICULTY_QUESTION, heuristicDifficulty, planRequest, type ModelTier } from "../src/assistant/tiers.js";
import { ROUTE_CRITERIA, ROUTE_QUESTION } from "../src/assistant/routing.js";
import { MemoryVaultStore } from "../src/vault/memory.js";
import { AUTH, setup } from "./helpers.js";

const both = { device: true, cloud: true };

/** Answers every turn with "完成" and records the requests. */
class TieredModel implements AssistantModel {
  readonly requests: ModelRequest[] = [];
  readonly model = "claude-opus-test";
  modelFor(tier: ModelTier): string {
    return { small: "claude-haiku-test", medium: "claude-sonnet-test", large: "claude-opus-test" }[tier];
  }
  async create(request: ModelRequest): Promise<ModelResponse> {
    this.requests.push(request);
    return { content: [{ type: "text", text: "完成", citations: null } as never], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } };
  }
  async downloadFile(): Promise<{ filename: string; body: Buffer }> {
    throw new Error("unused");
  }
}

async function tieredApp(jev?: TypeSafeClient) {
  const store = new MemoryVaultStore();
  await store.write("Inbox.md", Buffer.from("# Inbox\n", "utf8"), { mtime: 1_760_000_000_000, contentType: "text/markdown" });
  const model = new TieredModel();
  const { app } = await setup({ vault: store, assistant: { model, ...(jev ? { jev, jevModel: "jev-latest" } : {}) } });
  return { app, model };
}

describe("budget tiers", () => {
  it("keeps easy requests on the device at every budget and only spends more on harder ones", () => {
    for (const budget of ["low", "medium", "high"] as const) {
      expect(planRequest(budget, "question", "simple", both)).toEqual({ placement: "device", effort: null });
      expect(planRequest(budget, "edit", "simple", both).placement).toBe("device");
    }
    // low: the device whenever it can cope, then the cheapest tier
    expect(planRequest("low", "question", "moderate", both).placement).toBe("device");
    expect(planRequest("low", "question", "hard", both)).toEqual({ placement: "small", effort: "medium" });
    expect(planRequest("low", "task", "simple", both).placement).toBe("device");
    expect(planRequest("low", "task", "hard", both)).toEqual({ placement: "medium", effort: "medium" });
    // medium: tiers rise with difficulty
    expect(planRequest("medium", "task", "simple", both)).toEqual({ placement: "small", effort: "low" });
    expect(planRequest("medium", "task", "moderate", both)).toEqual({ placement: "medium", effort: "medium" });
    expect(planRequest("medium", "task", "hard", both)).toEqual({ placement: "large", effort: "high" });
    // high: better models sooner
    expect(planRequest("high", "question", "moderate", both).placement).toBe("medium");
    expect(planRequest("high", "task", "moderate", both)).toEqual({ placement: "large", effort: "medium" });
  });

  it("falls back when the device or the cloud is missing", () => {
    expect(planRequest("low", "question", "simple", { device: false, cloud: true })).toEqual({ placement: "small", effort: "low" });
    expect(planRequest("high", "task", "hard", { device: true, cloud: false })).toEqual({ placement: "device", effort: null });
  });

  it("guesses difficulty from keywords without Jev", () => {
    expect(heuristicDifficulty("上週的會議說了什麼？", "question")).toBe("simple");
    expect(heuristicDifficulty("幫我摘要這三則會議紀錄", "question")).toBe("moderate");
    expect(heuristicDifficulty("整理這個資料夾", "task")).toBe("moderate");
    expect(heuristicDifficulty("把所有會議紀錄彙整成表格", "task")).toBe("hard");
    expect(heuristicDifficulty("分析今年每個客戶的出貨量", "task")).toBe("hard");
  });

  it("routes by budget with the keyword heuristic and names the tier's model", async () => {
    const { app } = await tieredApp();
    const route = async (body: object) => (await request(app).post("/v1/assistant/route").set(AUTH).send(body).expect(200)).body;
    expect(await route({ text: "上週的會議說了什麼？", budget: "high" })).toEqual({
      kind: "question",
      route: "device",
      confidence: 0.6,
      provider: "heuristic",
      cloudAvailable: true,
      difficulty: "simple",
      budget: "high",
      tier: "device",
      model: null,
      effort: null,
    });
    expect(await route({ text: "把所有會議紀錄彙整成表格", budget: "medium" })).toMatchObject({
      kind: "task",
      route: "cloud",
      difficulty: "hard",
      tier: "large",
      model: "claude-opus-test",
      effort: "high",
    });
    expect(await route({ text: "把所有會議紀錄彙整成表格", budget: "low" })).toMatchObject({ tier: "medium", model: "claude-sonnet-test" });
    expect(await route({ text: "記下明天十點開會", budget: "low", deviceAvailable: false })).toMatchObject({
      route: "cloud",
      tier: "small",
      model: "claude-haiku-test",
      effort: "low",
    });
    await request(app).post("/v1/assistant/route").set(AUTH).send({ text: "x", budget: "max" }).expect(400);
  });

  it("asks Jev for kind and difficulty together and takes unsure answers one step cheaper", async () => {
    const bodies: any[] = [];
    let answers: Record<string, { choice: string; confidence: number }> = {
      kind: { choice: "task", confidence: 0.9 },
      difficulty: { choice: "hard", confidence: 0.9 },
    };
    const jev = new TypeSafeClient({
      apiKey: "test",
      logLevel: "off",
      retry: { maxRetries: 0 },
      fetch: async (_url, init) => {
        bodies.push(JSON.parse(String(init?.body)));
        const body = Object.fromEntries(Object.entries(answers).map(([key, value]) => [key, { type: "choice", ...value, probabilities: {} }]));
        return new Response(JSON.stringify({ model: "jev-latest", answers: body, usage: { input_tokens: 1, output_tokens: 1 } }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      },
    });
    const { app } = await tieredApp(jev);
    const route = async (body: object) => (await request(app).post("/v1/assistant/route").set(AUTH).send(body).expect(200)).body;

    expect(await route({ text: "這些筆記", budget: "medium" })).toMatchObject({ provider: "jev", kind: "task", difficulty: "hard", tier: "large" });
    expect(bodies[0].questions).toEqual({
      kind: { type: "choice", instructions: ROUTE_QUESTION, criteria: ROUTE_CRITERIA },
      difficulty: { type: "choice", instructions: DIFFICULTY_QUESTION, criteria: DIFFICULTY_CRITERIA },
    });

    answers = { kind: { choice: "task", confidence: 0.9 }, difficulty: { choice: "hard", confidence: 0.3 } };
    expect(await route({ text: "這些筆記", budget: "medium" })).toMatchObject({ difficulty: "moderate", tier: "medium" });

    answers = { kind: { choice: "task", confidence: 0.3 }, difficulty: { choice: "simple", confidence: 0.9 } };
    expect(await route({ text: "這些筆記", budget: "medium" })).toMatchObject({ kind: "edit", tier: "device" });
  });

  it("starts a run on the tier's model with the chosen effort", async () => {
    const { app, model } = await tieredApp();
    const started = await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "整理", tier: "small", effort: "low" }).expect(202);
    expect(started.body.model).toBe("claude-haiku-test");
    for (let i = 0; i < 50 && model.requests.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 10));
    expect(model.requests[0]).toMatchObject({ model: "claude-haiku-test", effort: "low" });

    const defaults = await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "整理" }).expect(202);
    expect(defaults.body.model).toBe("claude-opus-test");
    await request(app).post("/v1/assistant/runs").set(AUTH).send({ prompt: "整理", tier: "huge" }).expect(400);

    const health = await request(app).get("/health").expect(200);
    expect(health.body.assistantModels).toEqual({ small: "claude-haiku-test", medium: "claude-sonnet-test", large: "claude-opus-test" });
  });

  it("drops an optional feature only for the model that rejected it", async () => {
    const bodies: any[] = [];
    const fetch = async (_url: string | URL | Request, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      bodies.push(body);
      if (body.model === "claude-haiku-test" && body.output_config) {
        return new Response(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "output_config.effort is not supported" } }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "stop here" } }), {
        status: 529,
        headers: { "content-type": "application/json" },
      });
    };
    const client = new Anthropic({ apiKey: "test-key", fetch: fetch as typeof globalThis.fetch, maxRetries: 0 });
    const model = new AnthropicAssistantModel({ client, model: "claude-opus-test", tiers: { small: "claude-haiku-test" } });
    const base = { system: "", context: "", tools: [], codeExecution: false, webSearch: false, messages: [{ role: "user" as const, content: "x" }] };
    const signal = new AbortController().signal;
    await expect(model.create({ ...base, model: model.modelFor("small"), effort: "low" }, { signal })).rejects.toMatchObject({ status: 529 });
    expect(bodies.map((body) => [body.model, body.output_config?.effort ?? null])).toEqual([
      ["claude-haiku-test", "low"],
      ["claude-haiku-test", null],
    ]);
    await expect(model.create({ ...base, effort: "medium" }, { signal })).rejects.toMatchObject({ status: 529 });
    expect(bodies[2]).toMatchObject({ model: "claude-opus-test", output_config: { effort: "medium" } });
  });

  it("shares one catalog fetch between tiers and retries after a failure", async () => {
    let calls = 0;
    let fail = true;
    let clock = 0;
    const load = shared(
      async () => {
        calls += 1;
        if (fail) throw new Error("down");
        return calls;
      },
      1000,
      () => clock,
    );
    await expect(load()).rejects.toThrow("down");
    fail = false;
    expect(await load()).toBe(2);
    expect(await load()).toBe(2);
    clock = 2000;
    expect(await load()).toBe(3);
  });
});

describe("API key problems", () => {
  it("explains errors the user fixes in Railway and unwraps the API's JSON", async () => {
    const { describeApiError } = await import("../src/assistant/model.js");
    const workspace =
      '400 {"type":"error","error":{"type":"invalid_request_error","message":"This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header"}}';
    expect(describeApiError(workspace)).toContain("ANTHROPIC_WORKSPACE_ID");
    expect(describeApiError('401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')).toContain("ANTHROPIC_API_KEY");
    expect(describeApiError('400 {"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too \\"big\\""}}')).toBe('max_tokens: too "big"');
    expect(describeApiError("socket hang up")).toBe("socket hang up");
  });

  it("sends the workspace id header when ANTHROPIC_WORKSPACE_ID is set", async () => {
    const { loadConfig } = await import("../src/config.js");
    expect(loadConfig({ NODE_ENV: "test", ANTHROPIC_WORKSPACE_ID: " wrkspc_123 " }, { warn() {} })).toMatchObject({ anthropicWorkspaceId: "wrkspc_123" });
    const headers: (string | null)[] = [];
    const client = new Anthropic({
      apiKey: "test-key",
      maxRetries: 0,
      defaultHeaders: { "anthropic-workspace-id": "wrkspc_123" },
      fetch: (async (_url: string | URL | Request, init?: RequestInit) => {
        headers.push(new Headers(init?.headers).get("anthropic-workspace-id"));
        return new Response(JSON.stringify({ data: [], has_more: false, first_id: null, last_id: null }), { status: 200, headers: { "content-type": "application/json" } });
      }) as typeof globalThis.fetch,
    });
    const { listAnthropicModels } = await import("../src/assistant/catalog.js");
    expect(await listAnthropicModels(client)).toEqual([]);
    expect(headers).toEqual(["wrkspc_123"]);
  });
});
