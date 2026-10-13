import type { VaultConfig } from "../config.js";
import { S3VaultStore } from "./s3.js";
import type { VaultStore } from "./types.js";

export type { VaultEntry, VaultFile, VaultListing, VaultStore, VaultWriteOptions } from "./types.js";
export { VaultStorageError } from "./types.js";
export { MemoryVaultStore } from "./memory.js";
export { S3VaultStore, createS3Client } from "./s3.js";

/** The S3 store when VAULT_S3_* is fully configured, otherwise null (vault endpoints answer 503). */
export function createVaultStore(config: VaultConfig | null): VaultStore | null {
  return config ? S3VaultStore.fromConfig(config) : null;
}
