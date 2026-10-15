import { DEFAULT_WATCHLIST_PATH } from "../logistics/service.js";

// OpenAPI paths and schemas for /v1/logistics (spread into buildOpenApi).

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const json = (schema: object) => ({ content: { "application/json": { schema } } });
const response = (schema: object, description = "OK") => ({ description, ...json(schema) });
const error = (description: string) => response(ref("Error"), description);
const unauthorized = error("Missing or invalid API key");
const noVault = error("Vault storage is not configured (vault_not_configured)");
const numberParam = { name: "number", in: "path", required: true, schema: { type: "string" }, description: "Tracking number" };
const itemResponse = response({ type: "object", required: ["item"], properties: { item: ref("LogisticsItem") } });

export const logisticsPaths = {
  "/v1/logistics": {
    get: {
      operationId: "listLogistics",
      summary: "The logistics watch list with couriers, statuses and the background refresh state",
      description:
        `Items come from ${DEFAULT_WATCHLIST_PATH} in the vault (LOGISTICS_PATH), the file the desktop 物流追蹤中心 tool uses. ` +
        "The server reads T-Cat and SF itself, DHL with DHL_API_KEY, and other couriers with TRACK17_API_KEY; active items are " +
        "refreshed every LOGISTICS_REFRESH_MINUTES (default 120).",
      responses: { "200": response(ref("LogisticsList")), "401": unauthorized, "422": error("watchlist.json is not a JSON array (invalid_watchlist)"), "503": noVault },
    },
  },
  "/v1/logistics/items": {
    post: {
      operationId: "addLogisticsItem",
      summary: "Track a number: query the courier and add it first (or update the same number)",
      requestBody: {
        required: true,
        ...json({
          type: "object",
          required: ["courier", "number"],
          properties: {
            courier: { type: "string", description: "Courier code, e.g. t-cat, sf-express, dhl, fedex, ups" },
            number: { type: "string", description: "Spaces are removed; letters, digits and - only" },
            note: { type: "string", maxLength: 500, description: "Case / customer / remark (kept when re-adding without one)" },
          },
        }),
      },
      responses: { "201": itemResponse, "400": error("Invalid body (invalid_request)"), "401": unauthorized, "503": noVault },
    },
  },
  "/v1/logistics/items/{number}": {
    patch: {
      operationId: "updateLogisticsItem",
      summary: "Change the note or status, archive (結案, → delivered) or restore (恢復追蹤, → transit)",
      parameters: [numberParam],
      requestBody: {
        required: true,
        ...json({ type: "object", properties: { note: { type: "string" }, status: ref("LogisticsStatusId"), archived: { type: "boolean" } } }),
      },
      responses: { "200": itemResponse, "400": error("Nothing to change or invalid value"), "401": unauthorized, "404": error("Unknown number (not_found)") },
    },
    delete: {
      operationId: "deleteLogisticsItem",
      summary: "Remove a number from the watch list",
      parameters: [numberParam],
      responses: { "204": { description: "Deleted" }, "401": unauthorized, "404": error("Unknown number (not_found)") },
    },
  },
  "/v1/logistics/items/{number}/refresh": {
    post: {
      operationId: "refreshLogisticsItem",
      summary: "Query the courier again for one number (a failed lookup keeps the recorded progress)",
      parameters: [numberParam],
      responses: { "200": itemResponse, "401": unauthorized, "404": error("Unknown number (not_found)") },
    },
  },
  "/v1/logistics/refresh": {
    post: {
      operationId: "refreshLogistics",
      summary: "Query every active (not archived) number, one after another; joins a refresh already running",
      responses: {
        "200": response({ type: "object", required: ["refreshed", "items"], properties: { refreshed: { type: "integer" }, items: { type: "array", items: ref("LogisticsItem") } } }),
        "401": unauthorized,
      },
    },
  },
  "/v1/logistics/archive-delivered": {
    post: {
      operationId: "archiveDeliveredLogistics",
      summary: "Archive every active item whose status is delivered (結案已送達)",
      responses: { "200": response({ type: "object", required: ["archived"], properties: { archived: { type: "integer" } } }), "401": unauthorized },
    },
  },
  "/v1/logistics/archived": {
    delete: {
      operationId: "clearArchivedLogistics",
      summary: "Remove every archived item (清空結案清單)",
      responses: { "200": response({ type: "object", required: ["removed"], properties: { removed: { type: "integer" } } }), "401": unauthorized },
    },
  },
  "/v1/logistics/linked": {
    get: {
      operationId: "listLogisticsLinkedNotes",
      summary: "Notes whose frontmatter names a tracking number (tracking_no, tracking_number, waybill, tcat_no, sf_no, dhl_no, fedex_no)",
      responses: {
        "200": response({
          type: "object",
          required: ["notes"],
          properties: {
            notes: {
              type: "array",
              items: {
                type: "object",
                required: ["path", "name", "customer", "caseNo", "trackingNumber", "courier", "courierName", "tracked"],
                properties: {
                  path: { type: "string" },
                  name: { type: "string" },
                  customer: { type: "string" },
                  caseNo: { type: "string" },
                  trackingNumber: { type: "string" },
                  courier: { type: "string", description: "courier field, else from the key (tcat_no…), else guessed from the number" },
                  courierName: { type: "string" },
                  tracked: { type: "boolean", description: "Already on the watch list" },
                },
              },
            },
          },
        }),
        "401": unauthorized,
      },
    },
  },
};

export const logisticsSchemas = {
  LogisticsStatusId: { type: "string", enum: ["transit", "delivered", "pickup", "exception", "pending", "notfound"] },
  LogisticsItem: {
    type: "object",
    description: "One watchlist.json entry (fields as the desktop tool writes them; unknown fields are kept)",
    required: ["tracking_number", "courier_code", "courier_name", "note", "status", "is_archived", "latest_event", "latest_time", "trackinfo", "updated_at"],
    properties: {
      tracking_number: { type: "string" },
      courier_code: { type: "string" },
      courier_name: { type: "string" },
      note: { type: "string" },
      status: ref("LogisticsStatusId"),
      is_archived: { type: "boolean" },
      latest_event: { type: "string" },
      latest_time: { type: "string", description: "As the courier writes it, e.g. 2026/10/05 15:40" },
      trackinfo: {
        type: "array",
        description: "Newest first",
        items: {
          type: "object",
          required: ["checkpoint_date", "location", "tracking_detail"],
          properties: { checkpoint_date: { type: "string" }, location: { type: "string" }, tracking_detail: { type: "string" } },
        },
      },
      updated_at: { type: "string" },
    },
  },
  LogisticsList: {
    type: "object",
    required: ["items", "path", "couriers", "statuses", "dhl", "track17", "refresh"],
    properties: {
      items: { type: "array", items: ref("LogisticsItem") },
      path: { type: "string" },
      couriers: {
        type: "array",
        items: {
          type: "object",
          required: ["code", "name", "url", "live"],
          properties: {
            code: { type: "string" },
            name: { type: "string" },
            url: { type: "string", description: "The courier's tracking page; {number} is the URL-encoded number" },
            live: { type: "boolean", description: "The server can read this courier's progress with the current keys" },
          },
        },
      },
      statuses: {
        type: "array",
        items: { type: "object", required: ["id", "label", "color"], properties: { id: { type: "string" }, label: { type: "string" }, color: { type: "string" } } },
      },
      dhl: { type: "boolean", description: "DHL_API_KEY is set" },
      track17: { type: "boolean", description: "TRACK17_API_KEY is set" },
      refresh: {
        type: "object",
        required: ["intervalMinutes", "running", "lastRunAt", "lastRefreshed", "lastError"],
        properties: {
          intervalMinutes: { type: "integer", description: "0 = background refresh off" },
          running: { type: "boolean" },
          lastRunAt: { type: ["string", "null"] },
          lastRefreshed: { type: "integer" },
          lastError: { type: ["string", "null"] },
        },
      },
    },
  },
};
