/** A file in the vault. `path` is relative to the vault root (no VAULT_PREFIX). */
export interface VaultEntry {
  path: string;
  size: number;
  /** Milliseconds since the epoch. */
  mtime: number;
  /** Bare entity tag without quotes (an MD5 hex digest for single-part uploads). */
  etag: string;
}

export interface VaultFile extends VaultEntry {
  body: Buffer;
}

export interface VaultListing {
  items: VaultEntry[];
  /** Child folders ("Notes/Daily/"), only for non-recursive listings. */
  folders: string[];
}

export interface VaultWriteOptions {
  /** Milliseconds; stored as Remotely Save's MTime/CTime metadata (seconds). */
  mtime: number;
  contentType: string;
}

/**
 * Plain-file storage for the Obsidian vault. Paths are already validated and normalized
 * (see `vaultPath`); implementations add their own key prefix.
 */
export interface VaultStore {
  readonly kind: "s3" | "memory";
  /** Key prefix in front of every path ("" or ending with "/"). */
  readonly prefix: string;
  /** `folder` is "" (root) or ends with "/". Non-recursive listings also return child folders. */
  list(folder: string, options: { recursive: boolean }): Promise<VaultListing>;
  stat(path: string): Promise<VaultEntry | null>;
  read(path: string): Promise<VaultFile | null>;
  write(path: string, body: Buffer, options: VaultWriteOptions): Promise<VaultEntry>;
  /** Deleting a missing file is not an error. */
  delete(path: string): Promise<void>;
}

/** A backend failure (network, credentials, bucket); the service turns it into 502 vault_storage_error. */
export class VaultStorageError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "VaultStorageError";
  }
}
