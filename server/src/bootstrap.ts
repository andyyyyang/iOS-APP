import { TemplateService } from "./services/templates.js";
import type { Store } from "./store/types.js";
import {
  DEFAULT_MANAGED_TEMPLATES_DIR,
  syncManagedTemplates,
  type ManagedLogger,
  type ManagedSyncResult,
} from "./templates/managed.js";

export interface BootstrapOptions {
  logger?: ManagedLogger;
  /** Directory of repo-managed template JSON files; `null` disables syncing. */
  managedTemplatesDir?: string | null;
}

/**
 * Runs migrations, seeds missing built-in templates, then syncs repo-managed templates.
 * Safe to call on every startup and from several instances at once.
 */
export async function bootstrapStore(
  store: Store,
  { logger = console, managedTemplatesDir = DEFAULT_MANAGED_TEMPLATES_DIR }: BootstrapOptions = {},
): Promise<{ seeded: string[]; managed: ManagedSyncResult | null }> {
  await store.init();
  return store.runExclusive(async () => {
    const seeded = await new TemplateService(store).seedBuiltins();
    if (seeded.length) logger.info(`[startup] seeded built-in templates: ${seeded.join(", ")}`);
    const managed = managedTemplatesDir ? await syncManagedTemplates(store, managedTemplatesDir, logger) : null;
    return { seeded, managed };
  });
}
