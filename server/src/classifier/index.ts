import { JevClassifier } from "./jev.js";
import type { Classifier } from "./types.js";

export type { Classifier, ClassificationCandidate, ClassifierResult } from "./types.js";
export { ClassifierError } from "./types.js";
export { JevClassifier } from "./jev.js";

/** Picks the configured provider, or null when server-side classification is unavailable. */
export function createClassifier(config: { jevApiKey: string | undefined; jevModel: string }): Classifier | null {
  if (config.jevApiKey) return new JevClassifier({ apiKey: config.jevApiKey, model: config.jevModel });
  return null;
}
