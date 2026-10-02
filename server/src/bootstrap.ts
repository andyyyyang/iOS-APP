import type { Store } from "./store/types.js";
import { TemplateService } from "./services/templates.js";

/** Runs migrations and seeds missing built-in templates. Safe to call on every startup. */
export async function bootstrapStore(store: Store, logger: Pick<Console, "info"> = console): Promise<void> {
  await store.init();
  const inserted = await new TemplateService(store).seedBuiltins();
  if (inserted.length) logger.info(`[startup] seeded built-in templates: ${inserted.join(", ")}`);
}
