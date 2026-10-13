import { createHash } from "node:crypto";
import type { VaultEntry, VaultFile, VaultListing, VaultStore, VaultWriteOptions } from "./types.js";

interface MemoryFile {
  body: Buffer;
  mtime: number;
  etag: string;
  contentType: string;
}

/**
 * In-process vault for tests and local development without S3. Unlike S3 (where listings report
 * LastModified), listings report the stored mtime.
 */
export class MemoryVaultStore implements VaultStore {
  readonly kind = "memory" as const;
  private readonly files = new Map<string, MemoryFile>();

  constructor(readonly prefix = "") {}

  private entry(path: string, file: MemoryFile): VaultEntry {
    return { path, size: file.body.length, mtime: file.mtime, etag: file.etag };
  }

  async list(folder: string, { recursive }: { recursive: boolean }): Promise<VaultListing> {
    const items: VaultEntry[] = [];
    const folders = new Set<string>();
    for (const [path, file] of this.files) {
      if (!path.startsWith(folder)) continue;
      const slash = path.indexOf("/", folder.length);
      if (!recursive && slash !== -1) folders.add(path.slice(0, slash + 1));
      else items.push(this.entry(path, file));
    }
    return { items, folders: [...folders] };
  }

  async stat(path: string): Promise<VaultEntry | null> {
    const file = this.files.get(path);
    return file ? this.entry(path, file) : null;
  }

  async read(path: string): Promise<VaultFile | null> {
    const file = this.files.get(path);
    return file ? { ...this.entry(path, file), body: Buffer.from(file.body) } : null;
  }

  async write(path: string, body: Buffer, { mtime, contentType }: VaultWriteOptions): Promise<VaultEntry> {
    const file = { body: Buffer.from(body), mtime, etag: createHash("md5").update(body).digest("hex"), contentType };
    this.files.set(path, file);
    return this.entry(path, file);
  }

  async delete(path: string): Promise<void> {
    this.files.delete(path);
  }
}
