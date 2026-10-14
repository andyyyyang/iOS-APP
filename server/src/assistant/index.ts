import Anthropic from "@anthropic-ai/sdk";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import type { Config } from "../config.js";
import { LatestModel, fetchModelsDev, listAnthropicModels, modelChoices, shared, type CatalogEntry, type ModelChoice } from "./catalog.js";
import { AnthropicAssistantModel, describeApiError } from "./model.js";
import type { AssistantOptions } from "./service.js";

export { AnthropicAssistantModel, AssistantModelError } from "./model.js";
export type { AssistantModel, ModelRequest, ModelResponse } from "./model.js";
export { AssistantService } from "./service.js";
export { LatestModel, modelChoices, pickLatest, parseModelsDev, parseModelSetting } from "./catalog.js";
export type { ModelChoice } from "./catalog.js";
export type { AssistantOptions } from "./service.js";
export { ASSISTANT_CLIENT_ID } from "./tools.js";

/**
 * Cloud AI from the environment: the Anthropic model when ANTHROPIC_API_KEY is set, Jev for routing when JEV_API_KEY is.
 * Three cloud tiers (small/medium/large = newest Haiku/Sonnet/Opus by default) follow new releases
 * (models.dev + the Models API, every 6 hours); the route picks a tier by budget and difficulty. The app's settings
 * can pin a tier to a listed model and switch the server tools per run (GET /v1/assistant/models).
 */
export function createAssistantOptions(
  config: Pick<
    Config,
    | "anthropicApiKey"
    | "anthropicWorkspaceId"
    | "assistantModel"
    | "assistantModelMedium"
    | "assistantModelSmall"
    | "assistantMaxTurns"
    | "assistantCodeExecution"
    | "assistantWebSearch"
    | "jevApiKey"
    | "jevModel"
  >,
): AssistantOptions {
  let model: AnthropicAssistantModel | null = null;
  let issue: string | null = null;
  let listModels: (() => Promise<ModelChoice[]>) | undefined;
  if (config.anthropicApiKey) {
    const client = new Anthropic({
      apiKey: config.anthropicApiKey,
      // an organization-level key must name the workspace each request belongs to
      ...(config.anthropicWorkspaceId ? { defaultHeaders: { "anthropic-workspace-id": config.anthropicWorkspaceId } } : {}),
    });
    // the Models API call doubles as a key check: its error (e.g. "needs a workspace id") is shown on /health
    const listAvailable = shared(async () => {
      try {
        const models = await listAnthropicModels(client);
        issue = null;
        return models;
      } catch (error) {
        if (error instanceof Anthropic.APIError && error.status !== undefined && error.status < 500) issue = describeApiError(error.message);
        throw error;
      }
    });
    const sources = { fetchCatalog: shared(() => fetchModelsDev()), listAvailable };
    const large = new LatestModel(config.assistantModel, sources);
    const medium = new LatestModel(config.assistantModelMedium, sources);
    const small = new LatestModel(config.assistantModelSmall, sources);
    for (const tier of [large, medium, small]) tier.start();
    model = new AnthropicAssistantModel({ client, model: () => large.id, tiers: { medium: () => medium.id, small: () => small.id } });
    listModels = async () => {
      const [catalog, available] = await Promise.all([sources.fetchCatalog().catch((): CatalogEntry[] => []), listAvailable()]);
      return modelChoices(catalog, available);
    };
  }
  return {
    model,
    issue: () => issue,
    listModels,
    jev: config.jevApiKey ? new TypeSafeClient({ apiKey: config.jevApiKey, defaultModel: config.jevModel }) : null,
    jevModel: config.jevModel,
    maxTurns: config.assistantMaxTurns,
    codeExecution: config.assistantCodeExecution,
    webSearch: config.assistantWebSearch,
  };
}
