import { createHash } from "node:crypto";
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import type { VaultConfig } from "../config.js";
import { normalizeEtag } from "./paths.js";
import {
  VaultStorageError,
  type VaultEntry,
  type VaultFile,
  type VaultListing,
  type VaultStore,
  type VaultWriteOptions,
} from "./types.js";

/** The part of S3Client the store uses, so tests can inject a fake. */
export type S3Sender = Pick<S3Client, "send">;

export interface S3VaultStoreOptions {
  bucket: string;
  /** "" or ending with "/". */
  prefix: string;
  client: S3Sender;
}

/** S3 client for an S3-compatible bucket (Railway Storage Buckets / Tigris: region "auto", virtual-hosted URLs). */
export function createS3Client(config: VaultConfig): S3Client {
  return new S3Client({
    endpoint: config.endpoint,
    region: config.region,
    forcePathStyle: config.forcePathStyle,
    credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey },
    // S3-compatible services do not all accept the SDK's default CRC checksum headers
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
    requestHandler: { connectionTimeout: 5_000, requestTimeout: 30_000 },
  });
}

const md5 = (body: Buffer) => createHash("md5").update(body).digest("hex");

interface SdkError {
  name?: string;
  message?: string;
  $metadata?: { httpStatusCode?: number };
}

function isNotFound(error: unknown): boolean {
  const { name, $metadata } = (error ?? {}) as SdkError;
  if (name === "NoSuchBucket") return false;
  return name === "NotFound" || name === "NoSuchKey" || $metadata?.httpStatusCode === 404;
}

/** Keeps the S3 error name, status and message (never credentials) for logs and the 502 response. */
function storageError(error: unknown): VaultStorageError {
  const { name, message, $metadata } = (error ?? {}) as SdkError;
  const status = $metadata?.httpStatusCode ? ` (HTTP ${$metadata.httpStatusCode})` : "";
  const detail = message && message !== name ? `: ${message.slice(0, 200)}` : "";
  return new VaultStorageError(`Vault storage request failed: ${name ?? "Error"}${status}${detail}`, { cause: error });
}

/**
 * Remotely Save stores the file's mtime as `MTime` metadata in seconds (older versions: milliseconds).
 * S3 returns metadata keys lowercased, so the lookup ignores case.
 */
export function metadataMtime(metadata: Record<string, string> | undefined): number | null {
  const raw = Object.entries(metadata ?? {}).find(([key]) => key.toLowerCase() === "mtime")?.[1];
  const value = raw === undefined ? Number.NaN : Number.parseFloat(raw);
  if (!Number.isFinite(value) || value <= 0) return null;
  return Math.round(value >= 1e12 ? value : value * 1000);
}

/**
 * Vault files as plain objects keyed `<prefix><vault path>`, the layout Remotely Save (S3 mode) syncs.
 * Folder marker objects (keys ending with "/") are never reported as files.
 */
export class S3VaultStore implements VaultStore {
  readonly kind = "s3" as const;
  readonly prefix: string;
  private readonly bucket: string;
  private readonly client: S3Sender;

  constructor({ bucket, prefix, client }: S3VaultStoreOptions) {
    this.bucket = bucket;
    this.prefix = prefix;
    this.client = client;
  }

  static fromConfig(config: VaultConfig): S3VaultStore {
    return new S3VaultStore({ bucket: config.bucket, prefix: config.prefix, client: createS3Client(config) });
  }

  private key(path: string): string {
    return this.prefix + path;
  }

  private async call<T>(fn: () => Promise<T>): Promise<T> {
    try {
      return await fn();
    } catch (error) {
      throw storageError(error);
    }
  }

  private async callOrNull<T>(fn: () => Promise<T>): Promise<T | null> {
    try {
      return await fn();
    } catch (error) {
      if (isNotFound(error)) return null;
      throw storageError(error);
    }
  }

  /** Listings report LastModified as mtime (ListObjectsV2 carries no metadata), like Remotely Save. */
  async list(folder: string, { recursive }: { recursive: boolean }): Promise<VaultListing> {
    const items: VaultEntry[] = [];
    const folders: string[] = [];
    const prefix = this.key(folder);
    let token: string | undefined;
    do {
      const page = await this.call(() =>
        this.client.send(
          new ListObjectsV2Command({
            Bucket: this.bucket,
            ...(prefix ? { Prefix: prefix } : {}),
            ...(recursive ? {} : { Delimiter: "/" }),
            ...(token ? { ContinuationToken: token } : {}),
          }),
        ),
      );
      for (const object of page.Contents ?? []) {
        const key = object.Key;
        if (!key || key.endsWith("/") || !key.startsWith(this.prefix)) continue;
        items.push({
          path: key.slice(this.prefix.length),
          size: object.Size ?? 0,
          mtime: object.LastModified?.getTime() ?? 0,
          etag: normalizeEtag(object.ETag ?? ""),
        });
      }
      for (const common of page.CommonPrefixes ?? []) {
        if (common.Prefix?.startsWith(this.prefix)) folders.push(common.Prefix.slice(this.prefix.length));
      }
      token = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (token);
    return { items, folders };
  }

  async stat(path: string): Promise<VaultEntry | null> {
    const head = await this.callOrNull(() =>
      this.client.send(new HeadObjectCommand({ Bucket: this.bucket, Key: this.key(path) })),
    );
    if (!head) return null;
    return {
      path,
      size: head.ContentLength ?? 0,
      mtime: metadataMtime(head.Metadata) ?? head.LastModified?.getTime() ?? 0,
      etag: normalizeEtag(head.ETag ?? ""),
    };
  }

  async read(path: string): Promise<VaultFile | null> {
    return this.callOrNull(async () => {
      const object = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: this.key(path) }));
      const body = object.Body ? Buffer.from(await object.Body.transformToByteArray()) : Buffer.alloc(0);
      return {
        path,
        size: body.length,
        mtime: metadataMtime(object.Metadata) ?? object.LastModified?.getTime() ?? 0,
        etag: object.ETag ? normalizeEtag(object.ETag) : md5(body),
        body,
      };
    });
  }

  /** Sets MTime/CTime metadata in seconds exactly like Remotely Save, so its next sync sees the right times. */
  async write(path: string, body: Buffer, { mtime, contentType }: VaultWriteOptions): Promise<VaultEntry> {
    const seconds = String(mtime / 1000);
    const output = await this.call(() =>
      this.client.send(
        new PutObjectCommand({
          Bucket: this.bucket,
          Key: this.key(path),
          Body: body,
          ContentType: contentType,
          Metadata: { MTime: seconds, CTime: seconds },
        }),
      ),
    );
    return { path, size: body.length, mtime, etag: output.ETag ? normalizeEtag(output.ETag) : md5(body) };
  }

  async delete(path: string): Promise<void> {
    await this.call(() => this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: this.key(path) })));
  }
}
