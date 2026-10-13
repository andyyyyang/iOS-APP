import { MAX_TEMPLATE_RULES, MAX_VAULT_SEARCH_LIMIT, RULE_TARGET_PATTERN } from "../schemas.js";
import { CLASSIFICATION_PROVIDERS, SCAN_SOURCES } from "../types.js";
import { MAX_PATH_BYTES } from "../vault/paths.js";
import { VERSION } from "../version.js";

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
const vaultErrors = {
  "400": errorResponse("Invalid path (invalid_path) or parameter (invalid_request)"),
  "401": commonErrors["401"],
  "502": errorResponse("The storage bucket failed (vault_storage_error)"),
  "503": errorResponse("Vault storage is not configured (vault_not_configured)"),
};
const preconditionFailed = response(ref("PreconditionFailed"), "Precondition failed (precondition_failed)");

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
        "MCP (Streamable HTTP, stateless) is served at /mcp with the same API keys.",
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
          parameters: [ifMatchHeader("Etag from a previous read; 412 if the file no longer matches")],
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
      "/v1/openapi.json": {
        get: {
          operationId: "getOpenApi",
          summary: "This document",
          responses: { "200": response({ type: "object" }), "401": commonErrors["401"] },
        },
      },
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
      },
    },
  };
}
