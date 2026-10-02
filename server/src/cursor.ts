import { AppError } from "./errors.js";

/**
 * Keyset position for scan listing. Sync mode (`updatedAt` ascending) is the contract in API.md;
 * the `createdAt` variant lets the default newest-first listing page as well.
 */
export type ScanCursor =
  | { kind: "updated"; updatedAt: string; id: string }
  | { kind: "created"; createdAt: string; id: string };

export function encodeCursor(cursor: ScanCursor): string {
  const payload =
    cursor.kind === "updated"
      ? { updatedAt: cursor.updatedAt, id: cursor.id }
      : { createdAt: cursor.createdAt, id: cursor.id };
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

const invalidCursor = () => new AppError(400, "invalid_cursor", "cursor is malformed; pass back nextCursor unchanged");

const isIsoDate = (value: unknown): value is string =>
  typeof value === "string" && !Number.isNaN(Date.parse(value));

export function decodeCursor(raw: string): ScanCursor {
  let payload: unknown;
  try {
    payload = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"));
  } catch {
    throw invalidCursor();
  }
  if (typeof payload !== "object" || payload === null) throw invalidCursor();
  const { updatedAt, createdAt, id } = payload as Record<string, unknown>;
  if (typeof id !== "string" || id.length === 0) throw invalidCursor();
  if (isIsoDate(updatedAt)) return { kind: "updated", updatedAt: new Date(updatedAt).toISOString(), id };
  if (isIsoDate(createdAt)) return { kind: "created", createdAt: new Date(createdAt).toISOString(), id };
  throw invalidCursor();
}
