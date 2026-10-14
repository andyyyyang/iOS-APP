import { TypeSafeClient } from "@typesafe-ai/sdk";
import type { Config } from "../config.js";
import { AnthropicAssistantModel } from "./model.js";
import type { AssistantOptions } from "./service.js";

export { AnthropicAssistantModel, AssistantModelError } from "./model.js";
export type { AssistantModel, ModelRequest, ModelResponse } from "./model.js";
export { AssistantService } from "./service.js";
export type { AssistantOptions } from "./service.js";
export { ASSISTANT_CLIENT_ID } from "./tools.js";

/** Cloud AI from the environment: the Anthropic model when ANTHROPIC_API_KEY is set, Jev for routing when JEV_API_KEY is. */
export function createAssistantOptions(
  config: Pick<
    Config,
    "anthropicApiKey" | "assistantModel" | "assistantMaxTurns" | "assistantCodeExecution" | "assistantWebSearch" | "jevApiKey" | "jevModel"
  >,
): AssistantOptions {
  return {
    model: config.anthropicApiKey ? new AnthropicAssistantModel({ apiKey: config.anthropicApiKey, model: config.assistantModel }) : null,
    jev: config.jevApiKey ? new TypeSafeClient({ apiKey: config.jevApiKey, defaultModel: config.jevModel }) : null,
    jevModel: config.jevModel,
    maxTurns: config.assistantMaxTurns,
    codeExecution: config.assistantCodeExecution,
    webSearch: config.assistantWebSearch,
  };
}
