import { notFound } from "../errors.js";
import { validateRequestSchema } from "../schemas.js";
import type { Store } from "../store/types.js";
import type { ValidationResult } from "../types.js";
import { validateAgainstSample } from "../validate.js";
import { parse } from "./parse.js";

export class ValidateService {
  constructor(private readonly store: Store) {}

  /** Checks `data` against the structure of a template's `sample`. */
  async validate(body: unknown): Promise<ValidationResult> {
    const { templateId, data } = parse(validateRequestSchema, body);
    const template = await this.store.getTemplate(templateId);
    if (!template) throw notFound("Template", templateId);
    return validateAgainstSample(data, template.sample);
  }
}
