import type { Classifier } from "../classifier/types.js";
import type { VaultConfig } from "../config.js";
import type { Store } from "../store/types.js";
import type { VaultStore } from "../vault/types.js";
import { ClassifyService } from "./classify.js";
import { ObsidianPluginService } from "./obsidian-plugin.js";
import { PairingService } from "./pairing.js";
import { ScanService } from "./scans.js";
import { TemplateService } from "./templates.js";
import { ValidateService } from "./validate.js";
import { VaultService } from "./vault.js";
import { VaultChangeFeed } from "./vault-changes.js";

/** Business logic shared by the REST routes and the MCP tools. */
export interface Services {
  store: Store;
  scans: ScanService;
  templates: TemplateService;
  classify: ClassifyService;
  validate: ValidateService;
  vault: VaultService;
  /** Recent vault changes behind GET /v1/vault/changes (fed by `vault`). */
  vaultChanges: VaultChangeFeed;
  pairing: PairingService;
  obsidianPlugin: ObsidianPluginService;
}

export function createServices({
  store,
  classifier,
  vault = null,
  vaultConfig = null,
  vaultChanges = new VaultChangeFeed(),
  obsidianPlugin,
  now = Date.now,
}: {
  store: Store;
  classifier: Classifier | null;
  /** null when VAULT_S3_* is not configured (vault calls answer 503). */
  vault?: VaultStore | null;
  /** Bucket credentials for GET /v1/vault/remotely-save; null answers 503 there. */
  vaultConfig?: VaultConfig | null;
  /** In-memory vault change log (index.ts passes the one it closes on shutdown); default: a new one. */
  vaultChanges?: VaultChangeFeed;
  /** Plugin release mirror (index.ts builds it to schedule mirroring); default: one over `store` and `vault` with fetch(). */
  obsidianPlugin?: ObsidianPluginService;
  /** Clock in milliseconds (pairing code expiry). */
  now?: () => number;
}): Services {
  return {
    store,
    scans: new ScanService(store),
    templates: new TemplateService(store),
    classify: new ClassifyService(store, classifier),
    validate: new ValidateService(store),
    vault: new VaultService(vault, vaultConfig, vaultChanges),
    vaultChanges,
    pairing: new PairingService({ now }),
    obsidianPlugin: obsidianPlugin ?? new ObsidianPluginService({ store, vault, now }),
  };
}

export {
  ClassifyService,
  ObsidianPluginService,
  PairingService,
  ScanService,
  TemplateService,
  ValidateService,
  VaultChangeFeed,
  VaultService,
};
