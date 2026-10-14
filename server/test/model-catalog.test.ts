import { describe, expect, it } from "vitest";
import { LatestModel, modelChoices, parseModelSetting, parseModelsDev, pickLatest } from "../src/assistant/catalog.js";
import { AnthropicAssistantModel } from "../src/assistant/model.js";

// A slice of models.dev's api.json (shape as published; values made up).
const MODELS_DEV = {
  openai: { id: "openai", models: { "gpt-x": { id: "gpt-x", family: "gpt", release_date: "2026-10-01", tool_call: true } } },
  anthropic: {
    id: "anthropic",
    models: {
      "claude-opus-5-5": { id: "claude-opus-5-5", family: "claude-opus", release_date: "2026-09-22", tool_call: true },
      "claude-opus-5": { id: "claude-opus-5", family: "claude-opus", release_date: "2026-07-24", tool_call: true },
      "claude-sonnet-5-5": { id: "claude-sonnet-5-5", family: "claude-sonnet", release_date: "2026-09-28", tool_call: true },
      "claude-haiku-5-5": { id: "claude-haiku-5-5", family: "claude-haiku", release_date: "2026-10-07", tool_call: true },
      "claude-opus-6-preview": { id: "claude-opus-6-preview", family: "claude-opus", release_date: "2026-10-10", tool_call: true, experimental: true },
      broken: { name: "no id" },
    },
  },
};

describe("which model cloud runs use", () => {
  it("reads ASSISTANT_MODEL", () => {
    expect(parseModelSetting("latest")).toEqual({ family: "claude-opus" });
    expect(parseModelSetting("latest-sonnet")).toEqual({ family: "claude-sonnet" });
    expect(parseModelSetting("LATEST-claude-haiku")).toEqual({ family: "claude-haiku" });
    expect(parseModelSetting(" claude-opus-5 ")).toEqual({ fixed: "claude-opus-5" });
  });

  it("parses Anthropic's models from models.dev and skips malformed entries", () => {
    const entries = parseModelsDev(MODELS_DEV);
    expect(entries.map((entry) => entry.id).sort()).toEqual([
      "claude-haiku-5-5",
      "claude-opus-5",
      "claude-opus-5-5",
      "claude-opus-6-preview",
      "claude-sonnet-5-5",
    ]);
    expect(parseModelsDev(null)).toEqual([]);
    expect(parseModelsDev({ anthropic: { models: "nope" } })).toEqual([]);
  });

  it("picks the newest released model of the family, skipping experimental ones", () => {
    const catalog = parseModelsDev(MODELS_DEV);
    expect(pickLatest("claude-opus", catalog, null)).toBe("claude-opus-5-5");
    expect(pickLatest("claude-sonnet", catalog, null)).toBe("claude-sonnet-5-5");
    expect(pickLatest("claude-unknown", catalog, null)).toBeNull();
  });

  it("only uses models the API key can call, and sees releases models.dev doesn't list yet", () => {
    const catalog = parseModelsDev(MODELS_DEV);
    // the key can't call 5.5 yet
    expect(pickLatest("claude-opus", catalog, [{ id: "claude-opus-5", createdAt: "2026-07-24T00:00:00Z" }])).toBe("claude-opus-5");
    // a brand-new release the API already serves
    const available = [
      { id: "claude-opus-5-5", createdAt: "2026-09-22T00:00:00Z" },
      { id: "claude-opus-5-6", createdAt: "2026-10-13T00:00:00Z" },
      { id: "claude-opus-6-preview", createdAt: "2026-10-10T00:00:00Z" },
    ];
    expect(pickLatest("claude-opus", catalog, available)).toBe("claude-opus-5-6");
    // models.dev unreachable: newest by the API's creation time (the experimental one stays out only via the catalog)
    expect(pickLatest("claude-opus", [], available.slice(0, 2))).toBe("claude-opus-5-6");
  });

  it("refreshes to the newest model and keeps the current one when the sources fail", async () => {
    const logger = { info: () => {}, warn: () => {} };
    const latest = new LatestModel("latest", {
      fetchCatalog: async () => parseModelsDev(MODELS_DEV),
      listAvailable: async () => [{ id: "claude-opus-5-5", createdAt: "2026-09-22T00:00:00Z" }],
      fallback: "claude-opus-5",
      logger,
    });
    expect(latest.id).toBe("claude-opus-5");
    expect(await latest.refresh()).toBe("claude-opus-5-5");

    const offline = new LatestModel("latest", {
      fetchCatalog: async () => {
        throw new Error("network down");
      },
      listAvailable: async () => {
        throw new Error("network down");
      },
      fallback: "claude-opus-5",
      logger,
    });
    expect(await offline.refresh()).toBe("claude-opus-5");

    const fixed = new LatestModel("claude-sonnet-5", { fetchCatalog: async () => parseModelsDev(MODELS_DEV), logger });
    expect(fixed.followsLatest).toBe(false);
    expect(await fixed.refresh()).toBe("claude-sonnet-5");
  });

  it("keeps a run on the model it started with", () => {
    let current = "claude-opus-5-5";
    const model = new AnthropicAssistantModel({ apiKey: "test", model: () => current });
    const request = { system: "s", context: "c", tools: [], codeExecution: false, webSearch: false, messages: [] };
    expect(model.params(request).model).toBe("claude-opus-5-5");
    current = "claude-opus-5-6";
    expect(model.model).toBe("claude-opus-5-6");
    expect(model.params({ ...request, model: "claude-opus-5-5" }).model).toBe("claude-opus-5-5");
  });
});

describe("modelChoices", () => {
  it("lists the models the key can call, newest first, with family and date, leaving out experimental ones", () => {
    const catalog = parseModelsDev(MODELS_DEV);
    const available = [
      { id: "claude-opus-5-5", createdAt: "2026-09-22T00:00:00Z", displayName: "Claude Opus 5.5" },
      { id: "claude-haiku-5-5", createdAt: "2026-10-07T00:00:00Z", displayName: "Claude Haiku 5.5" },
      { id: "claude-opus-6-preview", createdAt: "2026-10-10T00:00:00Z" },
      { id: "claude-sonnet-5-6", createdAt: "2026-10-12T00:00:00Z" },
    ];
    expect(modelChoices(catalog, available)).toEqual([
      { id: "claude-sonnet-5-6", name: "claude-sonnet-5-6", family: "claude-sonnet", releaseDate: "2026-10-12" },
      { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", family: "claude-haiku", releaseDate: "2026-10-07" },
      { id: "claude-opus-5-5", name: "Claude Opus 5.5", family: "claude-opus", releaseDate: "2026-09-22" },
    ]);
    expect(modelChoices([], [{ id: "claude-x", createdAt: "2026-01-01T00:00:00Z" }])).toEqual([
      { id: "claude-x", name: "claude-x", family: null, releaseDate: "2026-01-01" },
    ]);
  });
});
