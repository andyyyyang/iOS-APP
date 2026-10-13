import type { VaultConfig } from "../config.js";

// Settings for the Obsidian plugin Remotely Save (https://github.com/remotely-save/remotely-save),
// imported on a device through its own settings URI. Values follow its settings dropdowns (src/settings.ts).

/** "Schedule For Auto Run": "every 5 minutes" (options: -1, 1, 5, 10, 30 minutes). */
export const REMOTELY_SAVE_AUTO_RUN_MS = 5 * 60 * 1000;
/** "Run Once On Start Up Automatically": "sync once after 10 seconds of start up" (options: -1, 1 s, 10 s, 30 s). */
export const REMOTELY_SAVE_INIT_RUN_MS = 10 * 1000;
/** "Sync On Save": 1000 is the only "Enable" value; any value > 0 enables it (a sync ~3 s after the edit). */
export const REMOTELY_SAVE_SYNC_ON_SAVE_MS = 1000;
/** The URI's `version` (Remotely Save puts its plugin version there; its import only reads `func`, `vault`, `data`). */
export const REMOTELY_SAVE_URI_VERSION = "localocr";

/** Remotely Save's S3Config (src/baseTypes.ts). */
export interface RemotelySaveS3Config {
  s3Endpoint: string;
  s3Region: string;
  s3AccessKeyID: string;
  s3SecretAccessKey: string;
  s3BucketName: string;
  partsConcurrency: number;
  forcePathStyle: boolean;
  remotePrefix: string;
  useAccurateMTime: boolean;
  reverseProxyNoSignUrl: string;
  generateFolderObject: boolean;
  bypassCorsLocally: boolean;
}

/** The part of RemotelySavePluginSettings we set; everything else keeps the device's current value. */
export interface RemotelySaveSettings {
  serviceType: "s3";
  s3: RemotelySaveS3Config;
  autoRunEveryMilliseconds: number;
  initRunAfterMilliseconds: number;
  syncOnSaveAfterMilliseconds: number;
  /** Without it Remotely Save shows its "new sync algorithm" dialog and starts no automatic sync on launch. */
  agreeToUseSyncV3: true;
  /** "Sync _ files or folders": off by default, which would leave `_attachments/`-style folders out of the shared vault. */
  syncUnderscoreItems: true;
}

/**
 * Remotely Save imports with `Object.assign({}, this.settings, parsed)`, a shallow merge,
 * so `s3` must be complete: the device's old S3 settings are replaced as a whole.
 * Contains the bucket keys: never log the result.
 */
export function remotelySaveSettings(config: VaultConfig): RemotelySaveSettings {
  return {
    serviceType: "s3",
    s3: {
      s3Endpoint: config.endpoint,
      s3Region: config.region,
      s3AccessKeyID: config.accessKeyId,
      s3SecretAccessKey: config.secretAccessKey,
      s3BucketName: config.bucket,
      partsConcurrency: 20, // its default
      forcePathStyle: config.forcePathStyle,
      remotePrefix: config.prefix, // "" or "x/": the form Remotely Save's simpleTransRemotePrefix produces
      useAccurateMTime: true, // reads the MTime metadata the server also writes
      reverseProxyNoSignUrl: "",
      generateFolderObject: false,
      bypassCorsLocally: true,
    },
    autoRunEveryMilliseconds: REMOTELY_SAVE_AUTO_RUN_MS,
    initRunAfterMilliseconds: REMOTELY_SAVE_INIT_RUN_MS,
    syncOnSaveAfterMilliseconds: REMOTELY_SAVE_SYNC_ON_SAVE_MS,
    agreeToUseSyncV3: true,
    syncUnderscoreItems: true, // the whole vault syncs (the app reads every folder); only . items stay local
  };
}

/**
 * `obsidian://remotely-save?func=settings&…`, built like Remotely Save's own `exportQrCodeUri`.
 * Its import rejects a URI whose `vault` differs from the vault it is opened in.
 */
export function remotelySaveUri(settings: RemotelySaveSettings, vaultName: string): string {
  const version = encodeURIComponent(REMOTELY_SAVE_URI_VERSION);
  const vault = encodeURIComponent(vaultName);
  const data = encodeURIComponent(JSON.stringify(settings));
  return `obsidian://remotely-save?func=settings&version=${version}&vault=${vault}&data=${data}`;
}
