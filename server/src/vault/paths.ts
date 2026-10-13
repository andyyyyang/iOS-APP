import { AppError } from "../errors.js";

export const MAX_PATH_BYTES = 1024;

// C0 controls and DEL
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

const invalidPath = (reason: string) => new AppError(400, "invalid_path", `Invalid path: ${reason}`);

function checkSegments(path: string): void {
  if (path.startsWith("/")) throw invalidPath('must not start with "/"');
  if (path.includes("\\")) throw invalidPath("must not contain backslashes");
  if (CONTROL_CHARS.test(path)) throw invalidPath("must not contain control characters");
  if (Buffer.byteLength(path, "utf8") > MAX_PATH_BYTES) throw invalidPath(`must be at most ${MAX_PATH_BYTES} bytes`);
  for (const segment of path.split("/")) {
    if (segment === "") throw invalidPath('must not contain empty segments ("//")');
    if (segment === "." || segment === "..") throw invalidPath('must not contain "." or ".." segments');
  }
}

/**
 * Validates a vault-relative file path ("Notes/Daily/2026-10-13.md") and returns it NFC-normalized.
 * Throws 400 invalid_path.
 */
export function vaultPath(raw: unknown): string {
  if (raw === undefined || raw === "") throw invalidPath("path is required");
  if (typeof raw !== "string") throw invalidPath("path must be a string");
  const path = raw.normalize("NFC");
  if (path.endsWith("/")) throw invalidPath('a file path must not end with "/"');
  checkSegments(path);
  return path;
}

/** Validates an optional folder prefix: "" (root) or a folder path, returned with a trailing "/". */
export function vaultFolder(raw: unknown): string {
  if (raw === undefined || raw === "") return "";
  if (typeof raw !== "string") throw invalidPath("prefix must be a string");
  const folder = raw.normalize("NFC");
  const trimmed = folder.endsWith("/") ? folder.slice(0, -1) : folder;
  if (trimmed === "") throw invalidPath('must not start with "/"');
  checkSegments(trimmed);
  return `${trimmed}/`;
}

const CONTENT_TYPES: Record<string, string> = {
  md: "text/markdown; charset=utf-8",
  txt: "text/plain; charset=utf-8",
  json: "application/json",
  canvas: "application/json",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  heic: "image/heic",
  pdf: "application/pdf",
};

export function extensionOf(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/** Content-Type guessed from the extension (Obsidian files carry no type of their own). */
export function contentTypeFor(path: string): string {
  return CONTENT_TYPES[extensionOf(path)] ?? "application/octet-stream";
}

/** Strips a weak prefix and quotes so `"abc"`, `abc` and `W/"abc"` compare equal. */
export function normalizeEtag(value: string): string {
  return value.trim().replace(/^W\//i, "").replace(/^"(.*)"$/, "$1");
}
