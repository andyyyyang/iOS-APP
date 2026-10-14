import Anthropic from "@anthropic-ai/sdk";

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
  /** Model id reported on runs. */
  readonly model: string;
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
 * Optional request features. Each is dropped (once, for the life of the process) when the API answers 400 naming it,
 * e.g. for a configured model that does not support it.
 */
interface OptionalFeature {
  readonly name: string;
  readonly beta?: string;
  readonly rejected: RegExp;
  enabled: boolean;
}

/** Claude through the official SDK (`client.beta.messages.stream(...).finalMessage()`). */
export class AnthropicAssistantModel implements AssistantModel {
  readonly model: string;
  private readonly client: Anthropic;
  private readonly features: Record<"fallbacks" | "progressUpdates" | "effort", OptionalFeature> = {
    // a refusal is re-run on Anthropic's recommended fallback model instead of ending the run
    fallbacks: { name: "fallbacks", beta: "server-side-fallback-2026-07-01", rejected: /fallback/i, enabled: true },
    // the short notes written between tool calls come back as text (the run's "message" events)
    progressUpdates: { name: "progressUpdates", beta: "thinking-display-updates-2026-08-18", rejected: /display|updates/i, enabled: true },
    effort: { name: "effort", rejected: /effort|output_config/i, enabled: true },
  };

  constructor({ apiKey, model, client }: { apiKey?: string; model: string; client?: Anthropic }) {
    this.model = model;
    this.client = client ?? new Anthropic({ apiKey });
  }

  /** The request body (exported shape for tests and debugging; contains no credentials). */
  params(request: ModelRequest): Anthropic.Beta.MessageCreateParamsNonStreaming & { betas: string[] } {
    const { fallbacks, progressUpdates, effort } = this.features;
    const serverTools: Anthropic.Beta.BetaToolUnion[] = [];
    if (request.codeExecution) serverTools.push({ ...CODE_EXECUTION_TOOL });
    if (request.webSearch) serverTools.push({ ...(request.codeExecution ? WEB_SEARCH_TOOL_BASIC : WEB_SEARCH_TOOL) });
    return {
      model: this.model,
      max_tokens: MAX_OUTPUT_TOKENS,
      betas: Object.values(this.features).flatMap((feature) => (feature.enabled && feature.beta ? [feature.beta] : [])),
      ...(fallbacks.enabled ? { fallbacks: "default" as const } : {}),
      thinking: progressUpdates.enabled ? { type: "adaptive", display: "updates" } : { type: "adaptive" },
      ...(effort.enabled ? { output_config: { effort: "high" as const } } : {}),
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
          const feature = Object.values(this.features).find((item) => item.enabled && item.rejected.test(error.message));
          if (feature) {
            console.warn(`[assistant] the API rejected optional feature ${feature.name}; continuing without it`);
            feature.enabled = false;
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
