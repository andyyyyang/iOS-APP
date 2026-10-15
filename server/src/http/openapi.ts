import {
  MAX_TEMPLATE_RULES,
  MAX_VAULT_CHANGE_PATHS,
  MAX_VAULT_CHANGES_WAIT_SECONDS,
  MAX_VAULT_CLIENT_LENGTH,
  MAX_VAULT_SEARCH_LIMIT,
  RULE_TARGET_PATTERN,
} from "../schemas.js";
import { PLUGIN_CONTENT_TYPES, PLUGIN_FOLDER } from "../services/obsidian-plugin.js";
import { MCP_CLIENT_ID, VAULT_CHANGES_CAPACITY, VAULT_CHANGES_MAX_RESPONSE } from "../services/vault-changes.js";
import { VAULT_CLIENT_HEADER } from "../services/vault.js";
import { CLASSIFICATION_PROVIDERS, PLUGIN_FILES, SCAN_SOURCES } from "../types.js";
import { MAX_PATH_BYTES } from "../vault/paths.js";
import {
  VAULT_STREAM_AUTH_TIMEOUT_MS,
  VAULT_STREAM_BATCH_MS,
  VAULT_STREAM_CLOSE_NOT_CONFIGURED,
  VAULT_STREAM_CLOSE_UNAUTHORIZED,
  VAULT_STREAM_HEARTBEAT_MS,
  VAULT_STREAM_PATH,
} from "./vault-stream.js";
import {
  REMOTELY_SAVE_AUTO_RUN_MS,
  REMOTELY_SAVE_INIT_RUN_MS,
  REMOTELY_SAVE_SYNC_ON_SAVE_MS,
} from "../vault/remotely-save.js";
import { VERSION } from "../version.js";
import { assistantPaths, assistantSchemas } from "./openapi-assistant.js";
import { logisticsPaths, logisticsSchemas } from "./openapi-logistics.js";

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const json = (schema: object) => ({ content: { "application/json": { schema } } });
const response = (schema: object, description = "OK") => ({ description, ...json(schema) });
const requestBody = (schema: object) => ({ required: true, ...json(schema) });
const errorResponse = (description: string) => response(ref("Error"), description);

const scanIdParam = {
  name: "id",
  in: "path",
  required: true,
  description: "Scan UUID (case-insensitive; stored uppercase)",
  schema: { type: "string", format: "uuid" },
};
const templateIdParam = {
  name: "id",
  in: "path",
  required: true,
  schema: { type: "string", pattern: "^[a-z0-9][a-z0-9_-]{0,63}$" },
};

const commonErrors = {
  "400": errorResponse("Invalid request"),
  "401": errorResponse("Missing or invalid API key"),
};

const binary = { type: "string", format: "binary" };
const vaultPathParam = {
  name: "path",
  in: "query",
  required: true,
  description:
    "File path relative to the vault root, e.g. Daily/2026-10-13.md (NFC-normalized). Rejected with invalid_path: empty, " +
    'leading or trailing "/", "." or ".." segments, "//", backslashes, control characters, more than 1024 UTF-8 bytes.',
  schema: { type: "string", maxLength: MAX_PATH_BYTES },
};
const vaultPrefixParam = {
  name: "prefix",
  in: "query",
  description: 'Folder relative to the vault root, e.g. Daily/ (a missing trailing "/" is added). Default: the vault root.',
  schema: { type: "string" },
};
const ifMatchHeader = (description: string) => ({ name: "If-Match", in: "header", description, schema: { type: "string" } });
const vaultClientHeader = {
  name: VAULT_CLIENT_HEADER,
  in: "header",
  description:
    "Free-form id of the calling device or app (e.g. ipad-3F2A…, obsidian-k3j9…), trimmed; empty = none. " +
    "Recorded with the change in GET /v1/vault/changes, and changes made with the same id are left out of that client's own feed. " +
    "Accepted on every /v1/vault request; longer than 100 characters answers 400 invalid_request where it is used.",
  schema: { type: "string", maxLength: MAX_VAULT_CLIENT_LENGTH },
};
const vaultErrors = {
  "400": errorResponse("Invalid path (invalid_path) or parameter (invalid_request)"),
  "401": commonErrors["401"],
  "502": errorResponse("The storage bucket failed (vault_storage_error)"),
  "503": errorResponse("Vault storage is not configured (vault_not_configured)"),
};
const preconditionFailed = response(ref("PreconditionFailed"), "Precondition failed (precondition_failed)");
const noStoreHeader = { "Cache-Control": { description: "no-store", schema: { type: "string", const: "no-store" } } };
const pairingCode = { type: "string", pattern: "^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$", examples: ["K7QM-3XPA"] };

const pluginFileParam = { name: "file", in: "path", required: true, schema: { type: "string", enum: [...PLUGIN_FILES] } };
const pluginFileResponse = (cacheControl: string) => ({
  description: "The file's bytes, verified against the SHA-256 recorded in the database",
  headers: {
    ETag: { description: "The file's SHA-256 in quotes (If-None-Match answers 304)", schema: { type: "string" } },
    "Cache-Control": { schema: { type: "string", const: cacheControl } },
    "Content-Disposition": { schema: { type: "string", examples: ['attachment; filename="main.js"'] } },
  },
  content: Object.fromEntries(PLUGIN_FILES.map((name) => [PLUGIN_CONTENT_TYPES[name].split(";")[0], { schema: binary }])),
});
const pluginErrors = {
  "404": errorResponse("Unknown version or file, or nothing mirrored yet (not_found)"),
  "502": errorResponse(
    "The bucket copy is missing or does not match its recorded SHA-256 (integrity_error), or the bucket failed (vault_storage_error)",
  ),
  "503": errorResponse("Vault storage is not configured (vault_not_configured)"),
};

/** Hand-written OpenAPI 3.1 description of the REST API. */
export function buildOpenApi(serverUrl?: string) {
  return {
    openapi: "3.1.0",
    info: {
      title: "LocalOCR API",
      version: VERSION,
      description:
        "Scans from the LocalOCR iOS app, scenario templates, server-side classification, and the user's Obsidian vault " +
        "(plain files in an S3-compatible bucket synced by Remotely Save). " +
        "MCP (Streamable HTTP, stateless) is served at /mcp with the same API keys. " +
        "New devices pair with POST /v1/pairing (creates a code) and POST /pair (redeems it for the API key). " +
        "The Obsidian plugin's releases, mirrored into the vault bucket, are served without auth under /obsidian-plugin.",
    },
    ...(serverUrl ? { servers: [{ url: serverUrl }] } : {}),
    security: [{ bearerAuth: [] }, { apiKeyQuery: [] }],
    paths: {
      "/health": {
        get: {
          operationId: "getHealth",
          summary: "Health check (no auth)",
          security: [],
          responses: { "200": response(ref("Health"), "Service status") },
        },
      },
      "/v1/scans": {
        get: {
          operationId: "listScans",
          summary: "List scans",
          description:
            "With updatedAfter or cursor: ascending by (updatedAt, id) for incremental sync. Otherwise newest first by createdAt.",
          parameters: [
            { name: "limit", in: "query", schema: { type: "integer", minimum: 1, maximum: 200, default: 50 } },
            { name: "templateId", in: "query", schema: { type: "string" } },
            { name: "q", in: "query", description: "Case-insensitive text search", schema: { type: "string" } },
            { name: "updatedAfter", in: "query", schema: { type: "string", format: "date-time" } },
            { name: "cursor", in: "query", description: "Opaque nextCursor from a previous page", schema: { type: "string" } },
          ],
          responses: { "200": response(ref("ScanList"), "A page of scans"), ...commonErrors },
        },
      },
      "/v1/scans/{id}": {
        parameters: [scanIdParam],
        get: {
          operationId: "getScan",
          summary: "Get a scan",
          responses: { "200": response(ref("Scan")), ...commonErrors, "404": errorResponse("Not found") },
        },
        put: {
          operationId: "putScan",
          summary: "Create or replace a scan (idempotent)",
          description: "updatedAt is set by the server on every write; createdAt is kept from the first write.",
          requestBody: requestBody(ref("ScanInput")),
          responses: {
            "200": response(ref("Scan"), "Updated"),
            "201": response(ref("Scan"), "Created"),
            ...commonErrors,
          },
        },
        patch: {
          operationId: "patchScan",
          summary: "Partially update templateId, data and/or classification",
          requestBody: requestBody(ref("ScanPatch")),
          responses: { "200": response(ref("Scan")), ...commonErrors, "404": errorResponse("Not found") },
        },
        delete: {
          operationId: "deleteScan",
          summary: "Delete a scan",
          responses: { "204": { description: "Deleted" }, ...commonErrors, "404": errorResponse("Not found") },
        },
      },
      "/v1/templates": {
        get: {
          operationId: "listTemplates",
          summary: "List templates",
          responses: { "200": response(ref("TemplateList")), "401": commonErrors["401"] },
        },
      },
      "/v1/templates/{id}": {
        parameters: [templateIdParam],
        get: {
          operationId: "getTemplate",
          summary: "Get a template",
          responses: { "200": response(ref("Template")), ...commonErrors, "404": errorResponse("Not found") },
        },
        put: {
          operationId: "putTemplate",
          summary: "Create or replace a template (version auto-increments)",
          requestBody: requestBody(ref("TemplateInput")),
          responses: {
            "200": response(ref("Template"), "Updated"),
            "201": response(ref("Template"), "Created"),
            ...commonErrors,
          },
        },
        delete: {
          operationId: "deleteTemplate",
          summary: "Delete a template",
          responses: { "204": { description: "Deleted" }, ...commonErrors, "404": errorResponse("Not found") },
        },
      },
      "/v1/classify": {
        post: {
          operationId: "classify",
          summary: "Classify text into a template (Jev)",
          requestBody: requestBody(ref("ClassifyRequest")),
          responses: {
            "200": response(ref("ClassifyResponse")),
            ...commonErrors,
            "502": errorResponse("Upstream classifier failed (classifier_error)"),
            "503": errorResponse("Classifier not configured (jev_not_configured)"),
          },
        },
      },
      "/v1/validate": {
        post: {
          operationId: "validateData",
          summary: "Validate JSON against a template sample's structure",
          requestBody: requestBody(ref("ValidateRequest")),
          responses: { "200": response(ref("ValidationResult")), ...commonErrors, "404": errorResponse("Template not found") },
        },
      },
      "/v1/vault/status": {
        get: {
          operationId: "getVaultStatus",
          summary: "Whether Obsidian vault storage is configured",
          responses: { "200": response(ref("VaultStatus")), "401": commonErrors["401"] },
        },
      },
      "/v1/vault/files": {
        get: {
          operationId: "listVaultFiles",
          summary: "List vault files",
          description:
            "Files sorted by path. recursive=false (default) lists one folder level and also returns child folders; " +
            "recursive=true lists every file below prefix and omits folders. Folder marker objects are never listed as files. " +
            "mtime here is the bucket's upload time (LastModified); GET /v1/vault/file reports Remotely Save's MTime when present.",
          parameters: [
            vaultPrefixParam,
            { name: "recursive", in: "query", schema: { type: "string", enum: ["true", "false", "1", "0"], default: "false" } },
          ],
          responses: { "200": response(ref("VaultList")), ...vaultErrors },
        },
      },
      "/v1/vault/file": {
        parameters: [vaultPathParam],
        get: {
          operationId: "getVaultFile",
          summary: "Download a vault file (raw bytes)",
          responses: {
            "200": {
              description: "Raw file content; Content-Type is guessed from the extension",
              headers: {
                ETag: { description: "Quoted etag; send it back as If-Match", schema: { type: "string" } },
                "Last-Modified": { description: "HTTP date of the file mtime", schema: { type: "string" } },
                "X-Vault-Mtime": {
                  description: "File mtime in ms (Remotely Save MTime metadata when present, else the upload time)",
                  schema: { type: "integer" },
                },
              },
              content: { "*/*": { schema: binary } },
            },
            ...vaultErrors,
            "404": errorResponse("File not found (not_found)"),
          },
        },
        put: {
          operationId: "putVaultFile",
          summary: "Create or replace a vault file (raw bytes)",
          description:
            "The body is stored byte-for-byte whatever its Content-Type (max 25mb). MTime/CTime metadata are set like Remotely Save " +
            "so its next sync picks the file up. Concurrency: If-Match fails with 412 when the file changed or is missing; " +
            "If-None-Match: * fails with 412 when it already exists.",
          parameters: [
            ifMatchHeader("Etag from a previous read; 412 if the file no longer matches (or is missing)"),
            { name: "If-None-Match", in: "header", description: "* = only create; 412 if the file exists", schema: { type: "string" } },
            {
              name: "X-Vault-Mtime",
              in: "header",
              description: "File mtime in ms since the epoch (default: now)",
              schema: { type: "integer", minimum: 1 },
            },
            vaultClientHeader,
          ],
          requestBody: { required: false, description: "Raw file bytes", content: { "*/*": { schema: binary } } },
          responses: {
            "200": response(ref("VaultEntry"), "Replaced"),
            "201": response(ref("VaultEntry"), "Created"),
            ...vaultErrors,
            "412": preconditionFailed,
            "413": errorResponse("Body exceeds 25mb (payload_too_large)"),
          },
        },
        delete: {
          operationId: "deleteVaultFile",
          summary: "Delete a vault file",
          parameters: [ifMatchHeader("Etag from a previous read; 412 if the file no longer matches"), vaultClientHeader],
          responses: {
            "204": { description: "Deleted" },
            ...vaultErrors,
            "404": errorResponse("File not found (not_found)"),
            "412": preconditionFailed,
          },
        },
      },
      "/v1/vault/search": {
        get: {
          operationId: "searchVault",
          summary: "Search vault notes by name and content",
          description:
            "Case-insensitive match against file names and contents of .md/.txt/.json/.canvas files (dot folders such as .obsidian are skipped), " +
            "newest first. Scans at most the 3000 most recent files; contents of files over 1 MB are not searched.",
          parameters: [
            { name: "q", in: "query", required: true, schema: { type: "string", minLength: 1, maxLength: 500 } },
            vaultPrefixParam,
            { name: "limit", in: "query", schema: { type: "integer", minimum: 1, maximum: MAX_VAULT_SEARCH_LIMIT, default: 20 } },
          ],
          responses: { "200": response(ref("VaultSearchResult")), ...vaultErrors },
        },
      },
      "/v1/vault/changes": {
        get: {
          operationId: "getVaultChanges",
          summary: "Changes to vault files made through this server or reported by devices (long poll)",
          description:
            `An in-memory log of the last ${VAULT_CHANGES_CAPACITY} changes: every write and delete made through /v1/vault and the MCP ` +
            `vault tools (client "${MCP_CLIENT_ID}"), plus "external" reports from devices that upload to the bucket themselves ` +
            "(POST /v1/vault/changes). A move is a delete plus a write. Changes Remotely Save makes directly in the bucket are only " +
            'known when a device reports them. cursor is "<epoch>:<seq>"; the epoch changes when the server restarts. ' +
            "Without since: the current cursor, no changes. A malformed cursor, one from another epoch, or one older than the " +
            "oldest kept change: reset true (reload everything you show), no changes. Otherwise the changes after since whose " +
            "client differs from this request's X-LocalOCR-Client (null-client changes always count; without the header nothing " +
            "is left out). When there are none and wait > 0 the request is held until one arrives or wait seconds pass (then no " +
            `changes). More than ${VAULT_CHANGES_MAX_RESPONSE} changes answer reset true. The returned cursor is always the latest seq, ` +
            "including your own changes, so pass it back as since.",
          parameters: [
            {
              name: "since",
              in: "query",
              description: "Cursor from a previous response",
              schema: { type: "string", examples: ["9f3c2a1b7d4e:42"] },
            },
            {
              name: "wait",
              in: "query",
              description: `Seconds to wait for a change when there is none yet; clamped to 0–${MAX_VAULT_CHANGES_WAIT_SECONDS}`,
              schema: { type: "number", minimum: 0, maximum: MAX_VAULT_CHANGES_WAIT_SECONDS, default: 0 },
            },
            vaultClientHeader,
          ],
          responses: {
            "200": { description: "OK", headers: noStoreHeader, ...json(ref("VaultChanges")) },
            "400": errorResponse("wait is not a number, or X-LocalOCR-Client is too long (invalid_request)"),
            "401": commonErrors["401"],
            "503": vaultErrors["503"],
          },
        },
        post: {
          operationId: "reportVaultChanges",
          summary: "Report files this device uploaded to the bucket itself (e.g. by Remotely Save)",
          description:
            `Records one "external" change per path (duplicates merged), or a single one with path null when paths is missing ` +
            "or empty, under this request's X-LocalOCR-Client, and wakes the other clients' long polls.",
          parameters: [vaultClientHeader],
          requestBody: { required: false, ...json(ref("VaultChangesReport")) },
          responses: {
            "202": response(ref("VaultChangesCursor"), "Recorded"),
            "400": errorResponse(
              `A path is invalid (invalid_path), more than ${MAX_VAULT_CHANGE_PATHS} paths or a bad X-LocalOCR-Client (invalid_request), ` +
                "or bad JSON (invalid_json)",
            ),
            "401": commonErrors["401"],
            "503": vaultErrors["503"],
          },
        },
      },
      [VAULT_STREAM_PATH]: {
        get: {
          operationId: "streamVaultChanges",
          summary: "Vault changes pushed over a WebSocket (instead of long-polling GET /v1/vault/changes)",
          description:
            "A WebSocket upgrade (ws:// or wss://, same host and port; any query string is ignored). Every message is a JSON text frame. " +
            "Browsers cannot set headers on a WebSocket, so the upgrade itself needs no key: the first message authenticates, " +
            `within ${VAULT_STREAM_AUTH_TIMEOUT_MS / 1000} s: {"type":"auth","token":"<API key>","client":"<client id>","since":"<cursor>"} ` +
            "(client: like X-LocalOCR-Client, trimmed and cut to 100 characters; since optional). " +
            `A wrong or missing key answers {"type":"error","code":"unauthorized"} and closes with ${VAULT_STREAM_CLOSE_UNAUTHORIZED} ` +
            `(no auth message in time: close ${VAULT_STREAM_CLOSE_UNAUTHORIZED} only); without vault storage ` +
            `{"type":"error","code":"vault_not_configured"} and close ${VAULT_STREAM_CLOSE_NOT_CONFIGURED}. ` +
            'Then the server sends {"type":"ready","cursor","reset"}: without since the current cursor and reset false; with since ' +
            "the same answer as GET /v1/vault/changes?since= (reset true for a cursor from another epoch, too old, unknown, or " +
            `too many changes behind), followed by {"type":"changes",…} when changes by other clients were missed. ` +
            'From then on every change recorded by another client is pushed as {"type":"changes","cursor","reset":false,"changes":[VaultChange…]} ' +
            `(changes within ${VAULT_STREAM_BATCH_MS} ms come in one message; changes made under this socket's client id are left out, ` +
            "so a batch of only those sends nothing). The client may send " +
            '{"type":"report","paths":[…]} for files it uploaded to the bucket itself (like POST /v1/vault/changes, recorded under its ' +
            `client id; invalid paths are skipped, and no paths or more than ${MAX_VAULT_CHANGE_PATHS} record one change with path null), ` +
            'answered {"type":"ack","cursor"}, and {"type":"ping"}, answered {"type":"pong"}. Unknown messages are ignored. ' +
            `The server sends a WebSocket ping every ${VAULT_STREAM_HEARTBEAT_MS / 1000} s and terminates a socket that missed the ` +
            "previous one; a socket is closed with 1001 when the server shuts down. Servers without this endpoint answer the upgrade with 404.",
          security: [],
          parameters: [
            { name: "Upgrade", in: "header", required: true, schema: { type: "string", const: "websocket" } },
          ],
          responses: {
            "101": { description: "Switching Protocols: the WebSocket is open; send the auth message" },
            "400": { description: "Not a valid WebSocket upgrade request" },
          },
        },
      },
      "/v1/pairing": {
        post: {
          operationId: "createPairingCode",
          summary: "Create a single-use pairing code for a new device",
          description:
            "The code (8 characters from ABCDEFGHJKLMNPQRSTUVWXYZ23456789, shown as XXXX-XXXX) is valid for 10 minutes and redeems, " +
            "once, the API key that authenticated this request (POST /pair). Codes live in server memory (lost on restart); " +
            "at most 20 per key are outstanding, older ones are dropped. pairUrl uses PUBLIC_URL when set, else this request's host.",
          requestBody: { required: false, ...json(ref("PairingCreateRequest")) },
          responses: {
            "201": { description: "Created", headers: noStoreHeader, ...json(ref("PairingCode")) },
            ...commonErrors,
          },
        },
      },
      "/pair": {
        post: {
          operationId: "redeemPairingCode",
          summary: "Redeem a pairing code for the API key (no auth)",
          description:
            "The code is case-insensitive; spaces and hyphens are ignored. A code works once. " +
            "Unknown, expired and already used codes all answer 404 invalid_code. At most 10 attempts per client IP per 10 minutes.",
          security: [],
          requestBody: requestBody(ref("PairClaimRequest")),
          responses: {
            "200": { description: "Paired", headers: noStoreHeader, ...json(ref("PairClaim")) },
            "400": errorResponse("Invalid request"),
            "404": errorResponse("Unknown, expired or used code (invalid_code)"),
            "429": {
              description: "Too many attempts from this IP (rate_limited)",
              headers: { "Retry-After": { description: "Seconds", schema: { type: "integer" } } },
              ...json(ref("Error")),
            },
          },
        },
      },
      "/v1/vault/remotely-save": {
        get: {
          operationId: "getRemotelySaveSettings",
          summary: "Remotely Save settings for this vault's bucket (contains the bucket keys)",
          description:
            "Settings that the Obsidian plugin Remotely Save imports through its own settings URI, so a device syncs the vault " +
            "with one tap or a QR code scan. Remotely Save merges the import shallowly, so s3 is always complete. " +
            "The response contains the S3 secret key: it is never cached or logged.",
          parameters: [
            {
              name: "vault",
              in: "query",
              description: "Obsidian vault name; Remotely Save rejects a URI for another vault. Without it uri is null.",
              schema: { type: "string", maxLength: 200 },
            },
          ],
          responses: {
            "200": { description: "OK", headers: noStoreHeader, ...json(ref("RemotelySaveSetup")) },
            ...commonErrors,
            "503": errorResponse("Vault storage is not configured (vault_not_configured)"),
          },
        },
      },
      "/obsidian-plugin/latest.json": {
        get: {
          operationId: "getLatestPluginRelease",
          summary: "Newest LocalOCR Sync (Obsidian plugin) release mirrored by this server (no auth)",
          description:
            "The plugin's online updater reads this first. The server mirrors GitHub releases obsidian-plugin-<version> into the vault " +
            `bucket (${PLUGIN_FOLDER}<version>/, a dot folder that Remotely Save and the app skip) on startup, every 30 minutes and on ` +
            "POST /v1/obsidian-plugin/refresh. Version, notes and each file's SHA-256 and size come from the database. " +
            "File URLs are absolute (PUBLIC_URL when set, else this request's host).",
          security: [],
          responses: {
            "200": {
              description: "OK",
              headers: { "Cache-Control": { schema: { type: "string", const: "no-cache" } } },
              ...json(ref("PluginRelease")),
            },
            "404": errorResponse("Nothing mirrored yet (not_found)"),
            "503": pluginErrors["503"],
          },
        },
      },
      "/obsidian-plugin/latest/{file}": {
        get: {
          operationId: "getLatestPluginFile",
          summary: "A file of the newest mirrored plugin release (no auth; the manual first-install link)",
          security: [],
          parameters: [pluginFileParam],
          responses: { "200": pluginFileResponse("no-cache"), ...pluginErrors },
        },
      },
      "/obsidian-plugin/releases/{version}/{file}": {
        get: {
          operationId: "getPluginFile",
          summary: "A file of a mirrored plugin release (no auth)",
          description: "Refused with 502 integrity_error when the bucket copy no longer matches the SHA-256 recorded when it was mirrored.",
          security: [],
          parameters: [
            { name: "version", in: "path", required: true, schema: { type: "string", pattern: "^\\d+\\.\\d+\\.\\d+$", examples: ["1.3.0"] } },
            pluginFileParam,
          ],
          responses: { "200": pluginFileResponse("public, max-age=31536000, immutable"), ...pluginErrors },
        },
      },
      "/v1/obsidian-plugin/refresh": {
        post: {
          operationId: "refreshPluginMirror",
          summary: "Mirror new plugin releases from GitHub now",
          description:
            "Downloads every published release obsidian-plugin-x.y.z not mirrored yet, checks GitHub's SHA-256 digest and that " +
            "manifest.json has id localocr-sync and the tag's version, stores the files in the bucket and records them. " +
            "Also restores the newest release's bucket files when they no longer match. Per-version failures are listed in failed.",
          responses: {
            "200": response(ref("PluginMirrorResult")),
            "401": commonErrors["401"],
            "502": errorResponse("The GitHub releases listing failed (github_unavailable)"),
            "503": pluginErrors["503"],
          },
        },
      },
      "/v1/openapi.json": {
        get: {
          operationId: "getOpenApi",
          summary: "This document",
          responses: { "200": response({ type: "object" }), "401": commonErrors["401"] },
        },
      },
      ...assistantPaths,
      ...logisticsPaths,
    },
    components: {
      securitySchemes: {
        bearerAuth: { type: "http", scheme: "bearer", description: "Authorization: Bearer <API_KEY>" },
        apiKeyQuery: { type: "apiKey", in: "query", name: "api_key", description: "Fallback for clients that cannot set headers" },
      },
      schemas: {
        Error: {
          type: "object",
          required: ["error"],
          properties: {
            error: {
              type: "object",
              required: ["code", "message"],
              properties: { code: { type: "string" }, message: { type: "string" } },
            },
          },
        },
        Health: {
          type: "object",
          properties: {
            status: { type: "string", const: "ok" },
            version: { type: "string" },
            database: { type: "string", enum: ["postgres", "memory"] },
            jev: { type: "boolean", description: "Whether server-side classification is configured" },
            assistant: { type: "boolean", description: "Whether cloud AI runs are available (ANTHROPIC_API_KEY and the vault are set)" },
            assistantModel: {
              type: ["string", "null"],
              description: "The model a new cloud run uses (follows the newest release with ASSISTANT_MODEL=latest); null when cloud runs are off",
            },
            assistantModels: {
              type: "object",
              description: "The model behind each cloud tier (present when cloud runs are available)",
              properties: { small: { type: "string" }, medium: { type: "string" }, large: { type: "string" } },
            },
            assistantIssue: {
              type: ["string", "null"],
              description: "A problem with the Anthropic API key found by the last model lookup (e.g. it needs ANTHROPIC_WORKSPACE_ID); null when none",
            },
          },
        },
        Classification: {
          type: "object",
          required: ["templateId", "provider"],
          properties: {
            templateId: { type: "string" },
            confidence: { type: ["number", "null"], minimum: 0, maximum: 1 },
            provider: { type: "string", enum: [...CLASSIFICATION_PROVIDERS] },
            probabilities: { type: "object", additionalProperties: { type: "number" } },
          },
        },
        Scan: {
          type: "object",
          required: ["id", "createdAt", "updatedAt", "source", "text", "templateId", "classification", "data"],
          properties: {
            id: { type: "string", format: "uuid" },
            createdAt: { type: "string", format: "date-time" },
            updatedAt: { type: "string", format: "date-time" },
            source: { type: "string", enum: [...SCAN_SOURCES] },
            text: { type: "string" },
            templateId: { type: ["string", "null"] },
            classification: { oneOf: [ref("Classification"), { type: "null" }] },
            data: { description: "Extracted JSON (any JSON value) or null" },
            lineCount: { type: ["integer", "null"] },
            averageConfidence: { type: ["number", "null"] },
            pageCount: { type: ["integer", "null"] },
            device: { type: ["string", "null"] },
          },
        },
        ScanInput: {
          type: "object",
          required: ["source", "text"],
          properties: {
            id: { type: "string", format: "uuid", description: "Optional; must match the path id" },
            createdAt: { type: "string", format: "date-time", description: "Scan time on the device; defaults to now on create" },
            source: { type: "string", enum: [...SCAN_SOURCES] },
            text: { type: "string" },
            templateId: { type: ["string", "null"] },
            classification: { oneOf: [ref("Classification"), { type: "null" }] },
            data: { description: "Any JSON value or null" },
            lineCount: { type: ["integer", "null"], minimum: 0 },
            averageConfidence: { type: ["number", "null"], minimum: 0, maximum: 1 },
            pageCount: { type: ["integer", "null"], minimum: 0 },
            device: { type: ["string", "null"] },
          },
        },
        ScanPatch: {
          type: "object",
          minProperties: 1,
          properties: {
            templateId: { type: ["string", "null"] },
            data: { description: "Any JSON value or null" },
            classification: { oneOf: [ref("Classification"), { type: "null" }] },
          },
        },
        ScanList: {
          type: "object",
          required: ["items", "nextCursor"],
          properties: {
            items: { type: "array", items: ref("Scan") },
            nextCursor: { type: ["string", "null"] },
          },
        },
        Template: {
          type: "object",
          required: ["id", "name", "description", "keywords", "sample", "instructions", "rules", "version", "updatedAt"],
          properties: {
            id: { type: "string", pattern: "^[a-z0-9][a-z0-9_-]{0,63}$" },
            name: { type: "string" },
            description: { type: "string" },
            keywords: { type: "array", items: { type: "string" } },
            sample: { type: "object", description: "Example output JSON; key order is preserved" },
            instructions: { type: ["string", "null"] },
            rules: { type: "array", maxItems: MAX_TEMPLATE_RULES, items: ref("TemplateRule"), description: "Empty when the template has no rules" },
            version: { type: "integer" },
            updatedAt: { type: "string", format: "date-time" },
          },
        },
        TemplateInput: {
          type: "object",
          required: ["name", "description", "sample"],
          properties: {
            id: { type: "string", description: "Optional; must match the path id" },
            name: { type: "string" },
            description: { type: "string" },
            keywords: { type: ["array", "null"], items: { type: "string" } },
            sample: { type: "object" },
            instructions: { type: ["string", "null"] },
            rules: {
              type: ["array", "null"],
              maxItems: MAX_TEMPLATE_RULES,
              items: ref("TemplateRule"),
              description: "Replaces the stored rules; omitted or null means no rules",
            },
          },
        },
        TemplateRule: {
          type: "object",
          required: ["set"],
          description:
            "Deterministic post-processing step applied by clients after AI extraction (stored verbatim, key order kept; " +
            "the server does not execute rules). Besides set, keys are free-form JSON. Supported ops: value, copy, " +
            'template ("{field}", "{field:,}" for thousands separators), sum ([paths]), join (path + separator), ' +
            'divide ([num, den] as fields or numbers + round), match (regex over the OCR text + separator), today: true, ' +
            'generate: "base36time", lookup (field + table {key: value}), onlyIfEmpty: true. ' +
            'Targets _title / _subtitle name the record in the app and are not output.',
          properties: {
            set: {
              type: "string",
              pattern: RULE_TARGET_PATTERN.source,
              description: "Target path: field or array[].field",
              examples: ["total", "items[].category"],
            },
          },
          additionalProperties: true,
        },
        TemplateList: {
          type: "object",
          required: ["items"],
          properties: { items: { type: "array", items: ref("Template") } },
        },
        ClassifyRequest: {
          type: "object",
          required: ["text"],
          properties: {
            text: { type: "string", description: "Truncated to 8000 characters before classification" },
            templateIds: { type: "array", items: { type: "string" }, minItems: 1 },
          },
        },
        ClassifyResponse: {
          type: "object",
          required: ["templateId", "confidence", "probabilities", "provider"],
          properties: {
            templateId: { type: "string" },
            confidence: { type: "number" },
            probabilities: { type: "object", additionalProperties: { type: "number" } },
            provider: { type: "string" },
          },
        },
        ValidateRequest: {
          type: "object",
          required: ["templateId", "data"],
          properties: { templateId: { type: "string" }, data: { description: "JSON to check" } },
        },
        PreconditionFailed: {
          type: "object",
          required: ["error"],
          properties: {
            error: {
              type: "object",
              required: ["code", "message", "currentEtag"],
              properties: {
                code: { type: "string", const: "precondition_failed" },
                message: { type: "string" },
                currentEtag: { type: ["string", "null"], description: "The file's current etag, or null when it does not exist" },
              },
            },
          },
        },
        VaultStatus: {
          type: "object",
          required: ["configured", "prefix"],
          properties: {
            configured: { type: "boolean", description: "Whether VAULT_S3_* is set; otherwise other vault endpoints return 503" },
            prefix: { type: "string", description: 'Key prefix in the bucket ("" or ending with "/")' },
          },
        },
        VaultEntry: {
          type: "object",
          required: ["path", "size", "mtime", "etag"],
          properties: {
            path: { type: "string", description: "Relative to the vault root", examples: ["Daily/2026-10-13.md"] },
            size: { type: "integer", description: "Bytes" },
            mtime: { type: "integer", description: "Milliseconds since the epoch" },
            etag: { type: "string", description: "Unquoted etag; send it as If-Match" },
          },
        },
        VaultList: {
          type: "object",
          required: ["items"],
          properties: {
            items: { type: "array", items: ref("VaultEntry") },
            folders: {
              type: "array",
              items: { type: "string", examples: ["Daily/"] },
              description: 'Child folders relative to the vault root, ending with "/" (only when recursive=false)',
            },
          },
        },
        VaultSearchResult: {
          type: "object",
          required: ["items"],
          properties: {
            items: {
              type: "array",
              items: {
                type: "object",
                required: ["path", "mtime", "snippet"],
                properties: {
                  path: { type: "string" },
                  mtime: { type: "integer" },
                  snippet: { type: "string", description: "About 120 characters around the first content match (or the start of the file)" },
                },
              },
            },
          },
        },
        VaultChange: {
          type: "object",
          required: ["seq", "path", "op", "client", "at"],
          properties: {
            seq: { type: "integer", minimum: 1 },
            path: { type: ["string", "null"], description: "Relative to the vault root; null for an external report without paths" },
            op: {
              type: "string",
              enum: ["write", "delete", "external"],
              description: "external = a device uploaded the file to the bucket itself (it may be a write or a delete)",
            },
            client: {
              type: ["string", "null"],
              description: `X-LocalOCR-Client of the request that made it, "${MCP_CLIENT_ID}" for MCP tools, null when unknown`,
            },
            at: { type: "string", format: "date-time" },
          },
        },
        VaultChanges: {
          type: "object",
          required: ["cursor", "reset", "changes"],
          properties: {
            cursor: { type: "string", description: '"<epoch>:<latest seq>"; send it back as since' },
            reset: { type: "boolean", description: "The changes since since cannot be listed: reload everything you show" },
            changes: { type: "array", maxItems: VAULT_CHANGES_MAX_RESPONSE, items: ref("VaultChange") },
          },
        },
        VaultChangesReport: {
          type: "object",
          properties: {
            paths: {
              type: "array",
              maxItems: MAX_VAULT_CHANGE_PATHS,
              items: { type: "string", maxLength: MAX_PATH_BYTES },
              description: "Vault-relative files that changed (same rules as the path parameter)",
            },
          },
        },
        VaultChangesCursor: {
          type: "object",
          required: ["cursor"],
          properties: { cursor: { type: "string", description: "The cursor after the recorded changes" } },
        },
        PairingCreateRequest: {
          type: "object",
          properties: {
            vaultName: { type: ["string", "null"], minLength: 1, maxLength: 200, description: "Obsidian vault the device should use" },
            notesFolder: { type: ["string", "null"], minLength: 1, maxLength: 200, examples: ["iPad 筆記"] },
          },
        },
        PairingCode: {
          type: "object",
          required: ["code", "expiresAt", "pairUrl"],
          properties: {
            code: pairingCode,
            expiresAt: { type: "string", format: "date-time" },
            pairUrl: {
              type: "string",
              description: "localocr://pair?server=<encodeURIComponent(base URL)>&code=<code>, for a QR code",
              examples: ["localocr://pair?server=https%3A%2F%2Fxxx.up.railway.app&code=K7QM-3XPA"],
            },
          },
        },
        PairClaimRequest: {
          type: "object",
          required: ["code"],
          properties: { code: { type: "string", maxLength: 100, examples: ["K7QM-3XPA", "k7qm 3xpa"] } },
        },
        PairClaim: {
          type: "object",
          required: ["apiKey", "vaultName", "notesFolder"],
          properties: {
            apiKey: { type: "string", description: "Send as Authorization: Bearer <apiKey>" },
            vaultName: { type: ["string", "null"] },
            notesFolder: { type: ["string", "null"] },
          },
        },
        RemotelySaveSetup: {
          type: "object",
          required: ["settings", "uri"],
          properties: {
            settings: ref("RemotelySaveSettings"),
            uri: {
              type: ["string", "null"],
              description:
                "obsidian://remotely-save?func=settings&version=localocr&vault=<vault>&data=<encodeURIComponent(JSON.stringify(settings))>; " +
                "null without the vault parameter",
            },
          },
        },
        RemotelySaveSettings: {
          type: "object",
          description: "Partial Remotely Save settings; fields not listed keep the device's values",
          required: [
            "serviceType",
            "s3",
            "autoRunEveryMilliseconds",
            "initRunAfterMilliseconds",
            "syncOnSaveAfterMilliseconds",
            "agreeToUseSyncV3",
          ],
          properties: {
            serviceType: { type: "string", const: "s3" },
            s3: {
              type: "object",
              required: [
                "s3Endpoint",
                "s3Region",
                "s3AccessKeyID",
                "s3SecretAccessKey",
                "s3BucketName",
                "partsConcurrency",
                "forcePathStyle",
                "remotePrefix",
                "useAccurateMTime",
                "reverseProxyNoSignUrl",
                "generateFolderObject",
                "bypassCorsLocally",
              ],
              properties: {
                s3Endpoint: { type: "string", description: "VAULT_S3_ENDPOINT" },
                s3Region: { type: "string", description: "VAULT_S3_REGION" },
                s3AccessKeyID: { type: "string", description: "VAULT_S3_ACCESS_KEY_ID" },
                s3SecretAccessKey: { type: "string", description: "VAULT_S3_SECRET_ACCESS_KEY" },
                s3BucketName: { type: "string", description: "VAULT_S3_BUCKET" },
                partsConcurrency: { type: "integer", const: 20 },
                forcePathStyle: { type: "boolean", description: "VAULT_S3_FORCE_PATH_STYLE" },
                remotePrefix: { type: "string", description: "VAULT_PREFIX" },
                useAccurateMTime: { type: "boolean", const: true },
                reverseProxyNoSignUrl: { type: "string", const: "" },
                generateFolderObject: { type: "boolean", const: false },
                bypassCorsLocally: { type: "boolean", const: true },
              },
            },
            autoRunEveryMilliseconds: { type: "integer", const: REMOTELY_SAVE_AUTO_RUN_MS, description: "Schedule For Auto Run: every 5 minutes" },
            initRunAfterMilliseconds: {
              type: "integer",
              const: REMOTELY_SAVE_INIT_RUN_MS,
              description: "Run Once On Start Up Automatically: after 10 seconds",
            },
            syncOnSaveAfterMilliseconds: { type: "integer", const: REMOTELY_SAVE_SYNC_ON_SAVE_MS, description: "Sync On Save: enabled" },
            agreeToUseSyncV3: { type: "boolean", const: true },
          },
        },
        PluginRelease: {
          type: "object",
          required: ["version", "minAppVersion", "notes", "publishedAt", "files"],
          properties: {
            version: { type: "string", examples: ["1.3.0"] },
            minAppVersion: { type: "string", description: "manifest.json's minAppVersion (empty when it has none)", examples: ["1.5.0"] },
            notes: { type: "string", description: "Release notes (the CHANGELOG.md section)" },
            publishedAt: { type: "string", format: "date-time" },
            files: {
              type: "object",
              required: [...PLUGIN_FILES],
              properties: Object.fromEntries(
                PLUGIN_FILES.map((name) => [
                  name,
                  {
                    type: "object",
                    required: ["sha256", "size", "url"],
                    properties: {
                      sha256: { type: "string", pattern: "^[0-9a-f]{64}$" },
                      size: { type: "integer", minimum: 0 },
                      url: { type: "string", format: "uri", description: "GET /obsidian-plugin/releases/{version}/{file}" },
                    },
                  },
                ]),
              ),
            },
          },
        },
        PluginMirrorResult: {
          type: "object",
          required: ["latest", "mirrored", "repaired", "failed"],
          properties: {
            latest: { type: ["string", "null"], description: "Newest mirrored version after this run" },
            mirrored: { type: "array", items: { type: "string" } },
            repaired: { type: "array", items: { type: "string" }, description: "Versions whose bucket files were restored" },
            failed: {
              type: "array",
              items: {
                type: "object",
                required: ["version", "error"],
                properties: { version: { type: "string" }, error: { type: "string" } },
              },
            },
          },
        },
        ValidationResult: {
          type: "object",
          required: ["valid", "issues"],
          properties: {
            valid: { type: "boolean" },
            issues: {
              type: "array",
              items: {
                type: "object",
                required: ["path", "message"],
                properties: { path: { type: "string", examples: ["$.items[0].price"] }, message: { type: "string" } },
              },
            },
          },
        },
        ...assistantSchemas,
        ...logisticsSchemas,
      },
    },
  };
}
