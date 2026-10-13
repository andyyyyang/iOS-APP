import type { Classifier } from "../classifier/types.js";
import type { Store } from "../store/types.js";
import type { VaultStore } from "../vault/types.js";
import { ClassifyService } from "./classify.js";
import { ScanService } from "./scans.js";
import { TemplateService } from "./templates.js";
import { ValidateService } from "./validate.js";
import { VaultService } from "./vault.js";

/** Business logic shared by the REST routes and the MCP tools. */
export interface Services {
  store: Store;
  scans: ScanService;
  templates: TemplateService;
  classify: ClassifyService;
  validate: ValidateService;
  vault: VaultService;
}

export function createServices({
  store,
  classifier,
  vault = null,
}: {
  store: Store;
  classifier: Classifier | null;
  /** null when VAULT_S3_* is not configured (vault calls answer 503). */
  vault?: VaultStore | null;
}): Services {
  return {
    store,
    scans: new ScanService(store),
    templates: new TemplateService(store),
    classify: new ClassifyService(store, classifier),
    validate: new ValidateService(store),
    vault: new VaultService(vault),
  };
}

export { ClassifyService, ScanService, TemplateService, ValidateService, VaultService };
