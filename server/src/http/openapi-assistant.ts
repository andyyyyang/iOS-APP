import { MAX_HISTORY_TEXT, MAX_HISTORY_TURNS, MAX_RUN_WAIT_SECONDS } from "../assistant/schemas.js";
import { MAX_RULES_CHARS, RULES_FILE_NAMES } from "../assistant/prompt.js";
import { MAX_TASKS, SNIPPET_MAX_CHARS } from "../vault/markdown.js";

// OpenAPI paths and schemas for GET /v1/vault/index and /v1/assistant (spread into buildOpenApi).

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const json = (schema: object) => ({ content: { "application/json": { schema } } });
const response = (schema: object, description = "OK") => ({ description, ...json(schema) });
const error = (description: string) => response(ref("Error"), description);
const unauthorized = error("Missing or invalid API key");
const runIdParam = { name: "id", in: "path", required: true, schema: { type: "string" } };
const stringArray = { type: "array", items: { type: "string" } };

export const assistantPaths = {
  "/v1/vault/index": {
    get: {
      operationId: "getVaultIndex",
      summary: "Parsed links, tags, tasks and snippets of every note, plus the other files",
      description:
        "Built from a recursive listing (paths with a segment starting with \".\" are skipped). A note is re-read only when its " +
        "etag changed; a build is reused for 5 s unless a change went through this server. ETag is the sha1 of the sorted " +
        "path+etag pairs and the parser version: send it back as If-None-Match to get 304. Gzipped when Accept-Encoding allows gzip.",
      parameters: [{ name: "If-None-Match", in: "header", schema: { type: "string" } }],
      responses: {
        "200": {
          description: "OK",
          headers: { ETag: { schema: { type: "string" } } },
          ...json(ref("VaultIndex")),
        },
        "304": { description: "Not modified (If-None-Match matched)" },
        "401": unauthorized,
        "502": error("The storage bucket failed (vault_storage_error)"),
        "503": error("Vault storage is not configured (vault_not_configured)"),
      },
    },
  },
  "/v1/assistant/route": {
    post: {
      operationId: "routeAssistantRequest",
      summary: "Decide whether a chat request runs on the device or as a cloud run, and on which model",
      description:
        "Jev (when JEV_API_KEY is set) classifies the request as question, edit or task; without Jev, or when it fails, a keyword " +
        "heuristic decides (confidence 0.6). Without budget: route is \"cloud\" only for a task when cloud runs are available and " +
        "the provider is the heuristic or Jev's confidence is at least 0.5. With budget (low/medium/high): Jev also judges " +
        "difficulty (simple/moderate/hard; an answer under 0.5 confidence is taken one step cheaper) and a fixed table picks the " +
        "device or a cloud tier — easy requests stay on the device at every budget, a higher budget reaches a better model " +
        "sooner for harder ones. Start the run with the returned tier and effort.",
      requestBody: {
        required: true,
        ...json({
          type: "object",
          required: ["text"],
          properties: {
            text: { type: "string", minLength: 1 },
            context: { type: "string" },
            budget: { type: "string", enum: ["low", "medium", "high"] },
            deviceAvailable: { type: "boolean", default: true, description: "Whether the phone can run Apple Intelligence" },
          },
        }),
      },
      responses: { "200": response(ref("AssistantRoute")), "400": error("Invalid body (invalid_request)"), "401": unauthorized },
    },
  },
  "/v1/assistant/runs": {
    post: {
      operationId: "startAssistantRun",
      summary: "Start a cloud AI run over the vault",
      description:
        "Claude works on the vault with file tools (list, read, search, links, write, edit, move with link updates, delete to " +
        ".trash/) and, when enabled, Anthropic's code-execution sandbox (save_output saves sandbox files into the vault) and web " +
        `search. Every write uses change-feed client "assistant". history keeps the newest ${MAX_HISTORY_TURNS} turns, ` +
        `${MAX_HISTORY_TEXT} characters each. rulesPath: null = no vault rules; absent = the first root file named ` +
        `${RULES_FILE_NAMES.join(", ")} (case-insensitive), else the first root .md whose name contains 規則 or "rule" ` +
        `(at most ${MAX_RULES_CHARS} characters). transcriptPath: the chat-history note this turn is appended to when the run ends.`,
      requestBody: { required: true, ...json(ref("AssistantRunRequest")) },
      responses: {
        "202": response(
          {
            type: "object",
            required: ["id", "status", "model"],
            properties: { id: { type: "string" }, status: { type: "string", const: "running" }, model: { type: "string" } },
          },
          "Started",
        ),
        "400": error("Invalid body (invalid_request) or path (invalid_path)"),
        "401": unauthorized,
        "503": error("ANTHROPIC_API_KEY is not set (assistant_not_configured) or the vault is not configured (vault_not_configured)"),
      },
    },
  },
  "/v1/assistant/runs/{id}": {
    get: {
      operationId: "getAssistantRun",
      summary: "A run with its events after `after` (long poll)",
      description:
        `When there are no events after \`after\` and the run is running, the request is held up to \`wait\` seconds (0–${MAX_RUN_WAIT_SECONDS}) ` +
        "for the next event or status change. Runs are kept in memory for 24 hours.",
      parameters: [
        runIdParam,
        { name: "after", in: "query", schema: { type: "integer", minimum: 0, default: 0 } },
        { name: "wait", in: "query", schema: { type: "number", minimum: 0, maximum: MAX_RUN_WAIT_SECONDS, default: 0 } },
      ],
      responses: { "200": response(ref("AssistantRun")), "400": error("Invalid after or wait"), "401": unauthorized, "404": error("Unknown run (not_found)") },
    },
  },
  "/v1/assistant/runs/{id}/cancel": {
    post: {
      operationId: "cancelAssistantRun",
      summary: "Cancel a run (aborts the in-flight model request)",
      parameters: [runIdParam],
      responses: {
        "200": response({ type: "object", required: ["status"], properties: { status: ref("AssistantRunStatus") } }),
        "401": unauthorized,
        "404": error("Unknown run (not_found)"),
      },
    },
  },
  "/v1/assistant/runs/{id}/undo": {
    post: {
      operationId: "undoAssistantRun",
      summary: "Undo a run's edits (all, or editIds), newest first",
      description:
        "Never overwrites later changes: a created file is deleted, an updated file restored and a moved file moved back only " +
        "while it still holds what the run wrote (and a move's source is free); a deleted file is restored from .trash/ (or the " +
        "saved content) only while its path is free. Link updates made by a move are separate update edits.",
      parameters: [runIdParam],
      requestBody: { required: false, ...json({ type: "object", properties: { editIds: stringArray } }) },
      responses: {
        "200": response({
          type: "object",
          required: ["undone", "failed"],
          properties: {
            undone: stringArray,
            failed: {
              type: "array",
              items: { type: "object", required: ["id", "reason"], properties: { id: { type: "string" }, reason: { type: "string" } } },
            },
          },
        }),
        "400": error("Invalid body (invalid_request)"),
        "401": unauthorized,
        "404": error("Unknown run (not_found)"),
      },
    },
  },
};

export const assistantSchemas = {
  VaultIndex: {
    type: "object",
    required: ["version", "notes", "files"],
    properties: {
      version: { type: "integer", const: 1 },
      notes: {
        type: "array",
        items: {
          type: "object",
          required: ["path", "mtime", "size", "etag", "title", "aliases", "tags", "links", "firstEmbed", "tasks", "snippet", "notebook"],
          properties: {
            path: { type: "string" },
            mtime: { type: "integer", description: "Milliseconds since the epoch" },
            size: { type: "integer" },
            etag: { type: "string" },
            title: { type: "string", description: "File name without .md" },
            aliases: { ...stringArray, description: "Frontmatter aliases/alias" },
            tags: { ...stringArray, description: "Frontmatter tags without a leading #" },
            links: {
              ...stringArray,
              description: "Wikilink targets (before |, # or ^), deduplicated case-insensitively; attachments left out",
            },
            firstEmbed: { type: ["string", "null"], description: "First ![[x]] target (without |size) or local ![](x) target" },
            tasks: {
              type: "array",
              maxItems: MAX_TASKS,
              items: { type: "object", required: ["text", "done"], properties: { text: { type: "string" }, done: { type: "boolean" } } },
            },
            snippet: { type: "string", maxLength: SNIPPET_MAX_CHARS },
            notebook: { type: ["string", "null"], description: "Frontmatter localocr-notebook" },
            properties: {
              type: "object",
              description: "The frontmatter as simple YAML: each value a string, a list of strings, or null (empty or nested)",
              additionalProperties: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }, { type: "null" }] },
            },
          },
        },
      },
      files: {
        type: "array",
        items: {
          type: "object",
          required: ["path", "mtime", "size"],
          properties: { path: { type: "string" }, mtime: { type: "integer" }, size: { type: "integer" } },
        },
      },
    },
  },
  AssistantRoute: {
    type: "object",
    required: ["kind", "route", "confidence", "provider", "cloudAvailable"],
    properties: {
      kind: { type: "string", enum: ["question", "edit", "task"] },
      route: { type: "string", enum: ["device", "cloud"] },
      confidence: { type: "number", minimum: 0, maximum: 1 },
      provider: { type: "string", enum: ["jev", "heuristic"] },
      cloudAvailable: { type: "boolean" },
      difficulty: { type: "string", enum: ["simple", "moderate", "hard"], description: "Only with budget" },
      budget: { type: "string", enum: ["low", "medium", "high"], description: "Only with budget" },
      tier: { type: "string", enum: ["device", "small", "medium", "large"], description: "Only with budget" },
      model: { type: ["string", "null"], description: "The tier's model right now (null on the device); only with budget" },
      effort: { type: ["string", "null"], enum: ["low", "medium", "high", null], description: "Only with budget" },
    },
  },
  AssistantRunRequest: {
    type: "object",
    required: ["prompt"],
    properties: {
      prompt: { type: "string", minLength: 1 },
      history: {
        type: "array",
        items: {
          type: "object",
          required: ["role", "text"],
          properties: { role: { type: "string", enum: ["user", "assistant"] }, text: { type: "string" } },
        },
      },
      rulesPath: { type: ["string", "null"], description: "null = no vault rules; absent = auto-detect" },
      openNote: { type: "string" },
      transcriptPath: { type: "string", description: "Vault path of the chat-history note to append this turn to" },
      timeZone: { type: "string", default: "Asia/Taipei", description: "IANA time zone for the transcript and today's date" },
      tier: { type: "string", enum: ["small", "medium", "large"], default: "large", description: "Cloud tier from the route" },
      effort: { type: "string", enum: ["low", "medium", "high"], default: "high", description: "Thinking effort from the route" },
    },
  },
  AssistantRunStatus: { type: "string", enum: ["running", "completed", "failed", "cancelled"] },
  AssistantEdit: {
    type: "object",
    required: ["id", "op", "path", "summary", "undone"],
    properties: {
      id: { type: "string" },
      op: { type: "string", enum: ["create", "update", "move", "delete"] },
      path: { type: "string", description: "For a move the destination; for a delete the original path" },
      from: { type: "string", description: "Source of a move" },
      summary: { type: "string" },
      undone: { type: "boolean" },
    },
  },
  AssistantEvent: {
    type: "object",
    required: ["seq", "at", "type"],
    description:
      'message {text}: an assistant text block or progress note (the last one is also the answer); tool {name, summary}: a tool ' +
      "call started (summary in Traditional Chinese); edit {edit}; file {path}: a sandbox output saved into the vault; error {message}.",
    properties: {
      seq: { type: "integer", minimum: 1 },
      at: { type: "string", format: "date-time" },
      type: { type: "string", enum: ["message", "tool", "edit", "file", "error"] },
      text: { type: "string" },
      name: { type: "string" },
      summary: { type: "string" },
      edit: ref("AssistantEdit"),
      path: { type: "string" },
      message: { type: "string" },
    },
  },
  AssistantRun: {
    type: "object",
    required: ["id", "status", "model", "events", "answer", "error", "sources", "edits", "usage"],
    properties: {
      id: { type: "string" },
      status: ref("AssistantRunStatus"),
      model: { type: "string" },
      events: { type: "array", items: ref("AssistantEvent") },
      answer: { type: ["string", "null"] },
      error: {
        oneOf: [
          { type: "null" },
          { type: "object", required: ["code", "message"], properties: { code: { type: "string" }, message: { type: "string" } } },
        ],
      },
      sources: { ...stringArray, description: "Vault paths read or cited" },
      edits: { type: "array", items: ref("AssistantEdit") },
      usage: {
        type: "object",
        required: ["inputTokens", "outputTokens"],
        properties: { inputTokens: { type: "integer" }, outputTokens: { type: "integer" } },
      },
    },
  },
};
