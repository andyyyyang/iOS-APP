import Anthropic from "@anthropic-ai/sdk";
import type { Effort, ModelTier } from "./tiers.js";

// The model behind cloud runs, behind an interface so tests can script responses without network.

export type ModelMessage = Anthropic.Beta.BetaMessageParam;
export type ModelContentBlock = Anthropic.Beta.BetaContentBlock;
export type ModelTool = Anthropic.Beta.BetaTool;

export interface ModelRequest {
  /** Instructions that are the same for every run (cached together with the tool definitions). */
  system: string;
  /** This run's context: date, open note, vault rules (the same on every turn of the run). */
  context: string;
  /** Our own (client-executed) tools. */
  tools: ModelTool[];
  /** Anthropic's code-execution sandbox (server tool). */
  codeExecution: boolean;
  /** Anthropic's web search (server tool). */
  webSearch: boolean;
  messages: ModelMessage[];
  /** The code-execution container of an earlier turn, so sandbox files survive between turns. */
  container?: string;
  /** The model this run started on (a run keeps its model even when a newer one is picked up mid-run). */
  model?: string;
  /** Thinking effort chosen by the route (default high). */
  effort?: Effort;
}

/** The part of a Messages API response a run uses (a real `BetaMessage` fits). */
export interface ModelResponse {
  content: ModelContentBlock[];
  stop_reason: Anthropic.Beta.BetaStopReason | null;
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_creation_input_tokens?: number | null;
    cache_read_input_tokens?: number | null;
  };
  container?: { id: string } | null;
}

export interface AssistantModel {
  /** Model id for a new run (may change when ASSISTANT_MODEL follows the latest release). */
  readonly model: string;
  /** Model id of a cloud tier (small/medium/large); without it every tier uses `model`. */
  modelFor?(tier: ModelTier): string;
  /** One Messages API call; rejects with AssistantModelError (API errors) or an abort error after `signal` fires. */
  create(request: ModelRequest, options: { signal: AbortSignal }): Promise<ModelResponse>;
  /** A file the code-execution sandbox produced (Files API). */
  downloadFile(fileId: string, options?: { signal?: AbortSignal }): Promise<{ filename: string; body: Buffer }>;
}

/** An API failure; `status` is the HTTP status when there was a response. Messages never contain the API key. */
export class AssistantModelError extends Error {
  constructor(
    readonly status: number | null,
    message: string,
  ) {
    super(message);
    this.name = "AssistantModelError";
  }
}

/** Latest code-execution tool in @anthropic-ai/sdk (CodeExecutionTool20260521); needs no beta header. */
export const CODE_EXECUTION_TOOL = { type: "code_execution_20260521", name: "code_execution" } as const;
/** Web search with dynamic filtering; it runs its own code sandbox, so it is only used without code execution. */
export const WEB_SEARCH_TOOL = { type: "web_search_20260209", name: "web_search", max_uses: 10 } as const;
/** Basic web search, used next to the code-execution tool (one sandbox instead of two). */
export const WEB_SEARCH_TOOL_BASIC = { type: "web_search_20250305", name: "web_search", max_uses: 10 } as const;

export const MAX_OUTPUT_TOKENS = 32_000;

/**
 * Optional request features. Each is dropped for a model (for the life of the process) when the API answers 400
 * naming it, e.g. a smaller model that does not support it; other models keep it.
 */
type FeatureName = "fallbacks" | "progressUpdates" | "effort";
interface OptionalFeature {
  readonly name: FeatureName;
  readonly beta?: string;
  readonly rejected: RegExp;
}

/** Claude through the official SDK (`client.beta.messages.stream(...).finalMessage()`). */
export class AnthropicAssistantModel implements AssistantModel {
  private readonly currentModel: () => string;
  private readonly tiers: Partial<Record<ModelTier, () => string>>;
  private readonly client: Anthropic;
  private readonly features: Record<FeatureName, OptionalFeature> = {
    // a refusal is re-run on Anthropic's recommended fallback model instead of ending the run
    fallbacks: { name: "fallbacks", beta: "server-side-fallback-2026-07-01", rejected: /fallback/i },
    // the short notes written between tool calls come back as text (the run's "message" events)
    progressUpdates: { name: "progressUpdates", beta: "thinking-display-updates-2026-08-18", rejected: /display|updates/i },
    effort: { name: "effort", rejected: /effort|output_config/i },
  };
  /** Features the API rejected, per model id. */
  private readonly rejected = new Map<string, Set<FeatureName>>();

  /**
   * `model`: the large tier (and the default), a fixed id or a function giving the current one (LatestModel).
   * `tiers`: the small and medium tiers (missing tiers use `model`).
   */
  constructor({
    apiKey,
    model,
    tiers = {},
    client,
  }: {
    apiKey?: string;
    model: string | (() => string);
    tiers?: Partial<Record<ModelTier, string | (() => string)>>;
    client?: Anthropic;
  }) {
    this.currentModel = typeof model === "string" ? () => model : model;
    this.tiers = Object.fromEntries(
      Object.entries(tiers).map(([tier, value]) => [tier, typeof value === "string" ? () => value : value]),
    ) as Partial<Record<ModelTier, () => string>>;
    this.client = client ?? new Anthropic({ apiKey });
  }

  get model(): string {
    return this.currentModel();
  }

  modelFor(tier: ModelTier): string {
    return (this.tiers[tier] ?? this.currentModel)();
  }

  private enabled(model: string, feature: FeatureName): boolean {
    return !this.rejected.get(model)?.has(feature);
  }

  /** The request body (exported shape for tests and debugging; contains no credentials). */
  params(request: ModelRequest): Anthropic.Beta.MessageCreateParamsNonStreaming & { betas: string[] } {
    const model = request.model ?? this.model;
    const on = (feature: FeatureName) => this.enabled(model, feature);
    const serverTools: Anthropic.Beta.BetaToolUnion[] = [];
    if (request.codeExecution) serverTools.push({ ...CODE_EXECUTION_TOOL });
    if (request.webSearch) serverTools.push({ ...(request.codeExecution ? WEB_SEARCH_TOOL_BASIC : WEB_SEARCH_TOOL) });
    return {
      model,
      max_tokens: MAX_OUTPUT_TOKENS,
      betas: Object.values(this.features).flatMap((feature) => (on(feature.name) && feature.beta ? [feature.beta] : [])),
      ...(on("fallbacks") ? { fallbacks: "default" as const } : {}),
      thinking: on("progressUpdates") ? { type: "adaptive", display: "updates" } : { type: "adaptive" },
      ...(on("effort") ? { output_config: { effort: request.effort ?? ("high" as const) } } : {}),
      // explicit breakpoint after the tools + fixed instructions; automatic caching for the growing conversation
      cache_control: { type: "ephemeral" },
      system: [
        { type: "text", text: request.system, cache_control: { type: "ephemeral" } },
        { type: "text", text: request.context },
      ],
      tools: [...request.tools, ...serverTools],
      messages: request.messages,
      ...(request.container && request.codeExecution ? { container: request.container } : {}),
    };
  }

  async create(request: ModelRequest, { signal }: { signal: AbortSignal }): Promise<ModelResponse> {
    for (;;) {
      try {
        // Streaming (collected with finalMessage) keeps long turns clear of HTTP timeouts.
        return await this.client.beta.messages.stream(this.params(request), { signal }).finalMessage();
      } catch (error) {
        if (error instanceof Anthropic.APIUserAbortError) throw error;
        if (error instanceof Anthropic.BadRequestError) {
          const model = request.model ?? this.model;
          const feature = Object.values(this.features).find((item) => this.enabled(model, item.name) && item.rejected.test(error.message));
          if (feature) {
            console.warn(`[assistant] the API rejected optional feature ${feature.name} for ${model}; continuing without it`);
            const rejected = this.rejected.get(model) ?? new Set<FeatureName>();
            rejected.add(feature.name);
            this.rejected.set(model, rejected);
            continue;
          }
        }
        if (error instanceof Anthropic.APIError) throw new AssistantModelError(error.status ?? null, error.message);
        throw error;
      }
    }
  }

  async downloadFile(fileId: string, { signal }: { signal?: AbortSignal } = {}): Promise<{ filename: string; body: Buffer }> {
    try {
      const [metadata, response] = await Promise.all([
        this.client.files.retrieveMetadata(fileId, {}, { signal }),
        this.client.files.download(fileId, {}, { signal }),
      ]);
      return { filename: metadata.filename, body: Buffer.from(await response.arrayBuffer()) };
    } catch (error) {
      if (error instanceof Anthropic.APIError && !(error instanceof Anthropic.APIUserAbortError)) {
        throw new AssistantModelError(error.status ?? null, error.message);
      }
      throw error;
    }
  }
}
