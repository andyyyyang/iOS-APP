import { invalidRequest, notFound } from "../errors.js";
import { templateIdSchema, templateInputSchema } from "../schemas.js";
import type { Store, WriteResult } from "../store/types.js";
import { BUILTIN_TEMPLATES } from "../templates/builtin.js";
import type { Template } from "../types.js";
import { parse } from "./parse.js";

export class TemplateService {
  constructor(private readonly store: Store) {}

  parseId(rawId: unknown): string {
    return parse(templateIdSchema, rawId, "id: ");
  }

  list(): Promise<Template[]> {
    return this.store.listTemplates();
  }

  async get(rawId: unknown): Promise<Template> {
    const id = this.parseId(rawId);
    const template = await this.store.getTemplate(id);
    if (!template) throw notFound("Template", id);
    return template;
  }

  /** Create-or-replace; the store bumps `version` and sets `updatedAt`. */
  async put(rawId: unknown, body: unknown): Promise<WriteResult<Template>> {
    const id = this.parseId(rawId);
    const input = parse(templateInputSchema, body);
    if (input.id !== undefined && input.id !== id) {
      throw invalidRequest("Body id does not match the URL id");
    }
    return this.store.putTemplate({
      id,
      name: input.name,
      description: input.description,
      keywords: input.keywords ?? [],
      sample: input.sample,
      instructions: input.instructions ?? null,
      rules: input.rules ?? [],
    });
  }

  async delete(rawId: unknown): Promise<void> {
    const id = this.parseId(rawId);
    if (!(await this.store.deleteTemplate(id))) throw notFound("Template", id);
  }

  /** Inserts built-in templates that are missing; returns the ids inserted. */
  async seedBuiltins(): Promise<string[]> {
    const inserted: string[] = [];
    for (const template of BUILTIN_TEMPLATES) {
      if (await this.store.insertTemplateIfMissing(template)) inserted.push(template.id);
    }
    return inserted;
  }
}
