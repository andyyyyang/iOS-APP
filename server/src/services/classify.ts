import { ClassifierError, type Classifier, type ClassifierResult } from "../classifier/types.js";
import { AppError } from "../errors.js";
import { classifyRequestSchema } from "../schemas.js";
import type { Store } from "../store/types.js";
import { parse } from "./parse.js";

export class ClassifyService {
  constructor(
    private readonly store: Store,
    private readonly classifier: Classifier | null,
  ) {}

  get available(): boolean {
    return this.classifier !== null;
  }

  /** Picks the best template for `text` among all templates, or only `templateIds` when given. */
  async classify(body: unknown): Promise<ClassifierResult> {
    if (!this.classifier) {
      throw new AppError(
        503,
        "jev_not_configured",
        "Server-side classification is not configured (set JEV_API_KEY); use an on-device classifier instead",
      );
    }
    const request = parse(classifyRequestSchema, body);

    const templates = await this.store.listTemplates();
    let candidates = templates;
    if (request.templateIds) {
      const byId = new Map(templates.map((template) => [template.id, template]));
      const unknown = request.templateIds.filter((id) => !byId.has(id));
      if (unknown.length) {
        throw new AppError(400, "unknown_template", `Unknown templateIds: ${unknown.join(", ")}`);
      }
      candidates = [...new Set(request.templateIds)].map((id) => byId.get(id)!);
    }
    if (candidates.length === 0) {
      throw new AppError(400, "no_templates", "There are no templates to classify against");
    }
    if (candidates.length === 1) {
      const only = candidates[0]!.id;
      return { templateId: only, confidence: 1, probabilities: { [only]: 1 }, provider: this.classifier.provider };
    }

    let result: ClassifierResult;
    try {
      result = await this.classifier.classify(
        request.text,
        candidates.map(({ id, name, description }) => ({ id, name, description })),
      );
    } catch (error) {
      if (error instanceof ClassifierError) throw new AppError(502, "classifier_error", error.message);
      throw error;
    }
    if (!candidates.some((candidate) => candidate.id === result.templateId)) {
      throw new AppError(502, "classifier_error", `Classifier returned an unknown template: ${result.templateId}`);
    }
    return result;
  }
}
