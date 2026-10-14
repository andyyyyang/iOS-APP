import Anthropic from "@anthropic-ai/sdk";
import { TypeSafeClient } from "@typesafe-ai/sdk";
import type { Config } from "../config.js";
import { LatestModel, fetchModelsDev, listAnthropicModels, shared } from "./catalog.js";
import { AnthropicAssistantModel } from "./model.js";
import type { AssistantOptions } from "./service.js";

export { AnthropicAssistantModel, AssistantModelError } from "./model.js";
export type { AssistantModel, ModelRequest, ModelResponse } from "./model.js";
export { AssistantService } from "./service.js";
export { LatestModel, pickLatest, parseModelsDev, parseModelSetting } from "./catalog.js";
export type { AssistantOptions } from "./service.js";
export { ASSISTANT_CLIENT_ID } from "./tools.js";

/**
 * Cloud AI from the environment: the Anthropic model when ANTHROPIC_API_KEY is set, Jev for routing when JEV_API_KEY is.
 * Three cloud tiers (small/medium/large = newest Haiku/Sonnet/Opus by default) follow new releases
 * (models.dev + the Models API, every 6 hours); the route picks a tier by budget and difficulty.
 */
export function createAssistantOptions(
  config: Pick<
    Config,
    | "anthropicApiKey"
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
  if (config.anthropicApiKey) {
    const client = new Anthropic({ apiKey: config.anthropicApiKey });
    const sources = { fetchCatalog: shared(() => fetchModelsDev()), listAvailable: shared(() => listAnthropicModels(client)) };
    const large = new LatestModel(config.assistantModel, sources);
    const medium = new LatestModel(config.assistantModelMedium, sources);
    const small = new LatestModel(config.assistantModelSmall, sources);
    for (const tier of [large, medium, small]) tier.start();
    model = new AnthropicAssistantModel({ client, model: () => large.id, tiers: { medium: () => medium.id, small: () => small.id } });
  }
  return {
    model,
    jev: config.jevApiKey ? new TypeSafeClient({ apiKey: config.jevApiKey, defaultModel: config.jevModel }) : null,
    jevModel: config.jevModel,
    maxTurns: config.assistantMaxTurns,
    codeExecution: config.assistantCodeExecution,
    webSearch: config.assistantWebSearch,
  };
}
