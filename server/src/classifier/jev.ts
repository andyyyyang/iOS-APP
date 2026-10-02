import { APIError, TypeSafeClient, TypeSafeError, choice } from "@typesafe-ai/sdk";
import {
  ClassifierError,
  type ClassificationCandidate,
  type Classifier,
  type ClassifierResult,
} from "./types.js";

export const MAX_STATE_CHARS = 8000;
const QUESTION = "這份文件屬於哪一種情境？";

/** Truncates to `max` Unicode code points without splitting surrogate pairs. */
export function truncateText(text: string, max = MAX_STATE_CHARS): string {
  if (text.length <= max) return text;
  return Array.from(text).slice(0, max).join("");
}

export interface JevClassifierOptions {
  apiKey: string;
  model: string;
  /** Overrides for tests or custom transports. */
  client?: TypeSafeClient;
}

/** Jev (TypeSafe AI System One) choice classifier over template descriptions. */
export class JevClassifier implements Classifier {
  readonly provider = "jev";
  private readonly client: TypeSafeClient;
  private readonly model: string;

  constructor(options: JevClassifierOptions) {
    this.model = options.model;
    this.client = options.client ?? new TypeSafeClient({ apiKey: options.apiKey, defaultModel: options.model });
  }

  async classify(text: string, candidates: ClassificationCandidate[]): Promise<ClassifierResult> {
    const criteria: Record<string, string> = {};
    for (const candidate of candidates) criteria[candidate.id] = candidate.description;

    try {
      const response = await this.client.systemOne({
        model: this.model,
        state: { document: truncateText(text) },
        questions: { template: choice(QUESTION, criteria) },
      });
      const answer = response.answers.template;
      return {
        templateId: answer.choice,
        confidence: answer.confidence,
        probabilities: { ...answer.probabilities },
        provider: this.provider,
      };
    } catch (error) {
      const detail =
        error instanceof APIError
          ? `Jev API error ${error.status}`
          : error instanceof TypeSafeError
            ? error.message
            : "unexpected error";
      throw new ClassifierError(`Jev classification failed: ${detail}`, { cause: error });
    }
  }
}
