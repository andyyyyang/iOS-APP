import { MAX_TEMPLATE_RULES, RULE_TARGET_PATTERN } from "../schemas.js";
import { CLASSIFICATION_PROVIDERS, SCAN_SOURCES } from "../types.js";
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

/** Hand-written OpenAPI 3.1 description of the REST API. */
export function buildOpenApi(serverUrl?: string) {
  return {
    openapi: "3.1.0",
    info: {
      title: "LocalOCR API",
      version: VERSION,
      description:
        "Scans from the LocalOCR iOS app, scenario templates, and server-side classification. " +
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
            'template ("{field}"), sum ([paths]), join (path + separator), divide ([num, den] + round), today: true, ' +
            'generate: "base36time", lookup (field + table {key: value}), onlyIfEmpty: true.',
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
