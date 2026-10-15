import { AssistantService, type AssistantOptions } from "../assistant/service.js";
import type { Classifier } from "../classifier/types.js";
import { LogisticsService, type LogisticsOptions } from "../logistics/service.js";
import type { VaultConfig } from "../config.js";
import type { Store } from "../store/types.js";
import type { VaultStore } from "../vault/types.js";
import { ClassifyService } from "./classify.js";
import { ObsidianPluginService } from "./obsidian-plugin.js";
import { PairingService } from "./pairing.js";
import { DEFAULT_RECORD_OUTPUTS, ScanRecordExporter, type RecordOutput } from "./scan-records.js";
import { ScanService } from "./scans.js";
import { TemplateService } from "./templates.js";
import { ValidateService } from "./validate.js";
import { VaultService } from "./vault.js";
import { VaultChangeFeed } from "./vault-changes.js";
import { VaultIndexService } from "./vault-index.js";

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
  /** Parsed links, tags and tasks of every note (GET /v1/vault/index, vault_links, the assistant's link tools). */
  vaultIndex: VaultIndexService;
  /** Cloud AI runs over the vault (/v1/assistant). */
  assistant: AssistantService;
  /** The logistics tracker over the vault's watch list (/v1/logistics). */
  logistics: LogisticsService;
}

export function createServices({
  store,
  classifier,
  vault = null,
  vaultConfig = null,
  vaultChanges = new VaultChangeFeed(),
  obsidianPlugin,
  assistant = { model: null },
  recordOutputs = DEFAULT_RECORD_OUTPUTS,
  logistics = {},
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
  /** Cloud AI (model, Jev routing, limits); default: off. */
  assistant?: AssistantOptions;
  /** Scans → JSON record files in the vault (SCAN_RECORD_OUTPUTS); default: the FV60 record file, when it exists. */
  recordOutputs?: RecordOutput[];
  /** Logistics tracker: courier API keys, watch list path, background refresh; default: T-Cat/SF only, no refresh. */
  logistics?: LogisticsOptions;
  /** Clock in milliseconds (pairing code expiry). */
  now?: () => number;
}): Services {
  const vaultService = new VaultService(vault, vaultConfig, vaultChanges);
  const vaultIndex = new VaultIndexService(vaultService, vaultChanges);
  return {
    store,
    scans: new ScanService(store, recordOutputs.length ? new ScanRecordExporter(vaultService, recordOutputs) : null),
    templates: new TemplateService(store),
    classify: new ClassifyService(store, classifier),
    validate: new ValidateService(store),
    vault: vaultService,
    vaultChanges,
    pairing: new PairingService({ now }),
    obsidianPlugin: obsidianPlugin ?? new ObsidianPluginService({ store, vault, now }),
    vaultIndex,
    assistant: new AssistantService({ vault: vaultService, vaultIndex, now }, assistant),
    logistics: new LogisticsService({ vault: vaultService, vaultIndex, now }, logistics),
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
