import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fromZodError } from "../errors.js";
import { templateIdSchema, templateInputSchema } from "../schemas.js";
import type { Store, TemplateWrite } from "../store/types.js";
import type { Template } from "../types.js";

/**
 * `server/templates/managed/`. The relative hop is the same from `src/templates/` (tsx, vitest)
 * and `dist/templates/` (production build), and the JSON files ship as-is (not compiled).
 */
export const DEFAULT_MANAGED_TEMPLATES_DIR = fileURLToPath(new URL("../../templates/managed/", import.meta.url));

/** A managed file is a full template object; unlike PUT, the id comes from the file. */
const managedTemplateSchema = templateInputSchema.extend({ id: templateIdSchema });

export type ManagedLogger = Pick<Console, "info" | "error">;

export interface SkippedFile {
  file: string;
  reason: string;
}

export interface ManagedSyncResult {
  created: string[];
  updated: string[];
  unchanged: string[];
  skipped: SkippedFile[];
}

/** Reads and validates every `*.json` in `dir` (sorted by file name). Invalid files are logged and skipped. */
export async function loadManagedTemplates(
  dir: string,
  logger: ManagedLogger = console,
): Promise<{ templates: TemplateWrite[]; skipped: SkippedFile[] }> {
  const templates: TemplateWrite[] = [];
  const skipped: SkippedFile[] = [];

  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      logger.error(`[managed] cannot read ${dir}: ${(error as Error).message}`);
    }
    return { templates, skipped };
  }

  const definedIn = new Map<string, string>();
  for (const file of entries.filter((name) => name.endsWith(".json")).sort()) {
    try {
      const raw = (await readFile(path.join(dir, file), "utf8")).replace(/^﻿/, "");
      let json: unknown;
      try {
        json = JSON.parse(raw);
      } catch (error) {
        throw new Error(`invalid JSON (${(error as Error).message})`);
      }
      const parsed = managedTemplateSchema.safeParse(json);
      if (!parsed.success) throw new Error(fromZodError(parsed.error).message);
      const input = parsed.data;
      const previous = definedIn.get(input.id);
      if (previous) throw new Error(`duplicate id "${input.id}" (already defined in ${previous})`);
      definedIn.set(input.id, file);
      templates.push({
        id: input.id,
        name: input.name,
        description: input.description,
        keywords: input.keywords ?? [],
        sample: input.sample,
        instructions: input.instructions ?? null,
        rules: input.rules ?? [],
      });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      logger.error(`[managed] skipping ${file}: ${reason}`);
      skipped.push({ file, reason });
    }
  }
  return { templates, skipped };
}

/** True when any repo-controlled field differs; JSON fields are compared as serialized text (key order matters). */
export function managedTemplateDiffers(stored: Template, wanted: TemplateWrite): boolean {
  const text = JSON.stringify;
  return (
    stored.name !== wanted.name ||
    stored.description !== wanted.description ||
    text(stored.keywords) !== text(wanted.keywords) ||
    text(stored.sample) !== text(wanted.sample) ||
    stored.instructions !== wanted.instructions ||
    text(stored.rules) !== text(wanted.rules)
  );
}

/**
 * Makes the store match the repo files: creates missing templates and replaces drifted ones
 * (bumping `version`). Never throws for bad files or per-template failures; they are logged.
 */
export async function syncManagedTemplates(
  store: Store,
  dir: string,
  logger: ManagedLogger = console,
): Promise<ManagedSyncResult> {
  const { templates, skipped } = await loadManagedTemplates(dir, logger);
  const result: ManagedSyncResult = { created: [], updated: [], unchanged: [], skipped };

  for (const template of templates) {
    try {
      const stored = await store.getTemplate(template.id);
      if (!stored) {
        await store.putTemplate(template);
        result.created.push(template.id);
      } else if (managedTemplateDiffers(stored, template)) {
        await store.putTemplate(template);
        result.updated.push(template.id);
      } else {
        result.unchanged.push(template.id);
      }
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      logger.error(`[managed] failed to sync ${template.id}: ${reason}`);
      result.skipped.push({ file: `${template.id} (store)`, reason });
    }
  }

  if (templates.length || skipped.length) {
    const list = (ids: string[]) => (ids.length ? ids.join(", ") : "-");
    logger.info(
      `[managed] templates: created ${list(result.created)}; updated ${list(result.updated)}; ` +
        `unchanged ${list(result.unchanged)}${skipped.length ? `; skipped ${skipped.length} invalid file(s)` : ""}`,
    );
  }
  return result;
}
