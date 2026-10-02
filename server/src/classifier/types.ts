/** A template offered to the classifier as one possible answer. */
export interface ClassificationCandidate {
  id: string;
  name: string;
  description: string;
}

export interface ClassifierResult {
  templateId: string;
  confidence: number;
  probabilities: Record<string, number>;
  /** Provider name reported to clients, e.g. "jev". */
  provider: string;
}

/**
 * Server-side text classifier. Implement this to add another provider, then return it from
 * `createClassifier` (src/classifier/index.ts).
 */
export interface Classifier {
  readonly provider: string;
  classify(text: string, candidates: ClassificationCandidate[]): Promise<ClassifierResult>;
}

/** Thrown by providers when the upstream service fails; mapped to HTTP 502. */
export class ClassifierError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "ClassifierError";
  }
}
