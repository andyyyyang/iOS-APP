import { z } from "zod";
import { CLASSIFICATION_PROVIDERS, SCAN_SOURCES, type JsonObject, type JsonValue, type TemplateRule } from "./types.js";

// Shared input schemas: REST handlers and MCP tools both funnel through these (via services).

export const TEMPLATE_ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const templateIdSchema = z
  .string()
  .regex(TEMPLATE_ID_PATTERN, "must match ^[a-z0-9][a-z0-9_-]{0,63}$");

export const scanIdSchema = z
  .string()
  .regex(UUID_PATTERN, "must be a UUID")
  .transform((id) => id.toUpperCase());

export const isoDateTimeSchema = z.iso
  .datetime({ offset: true, message: "must be an ISO 8601 date-time" })
  .transform((value) => new Date(value).toISOString());

export const jsonValueSchema = z.json() as unknown as z.ZodType<JsonValue>;
export const jsonObjectSchema = z.record(z.string(), jsonValueSchema) as unknown as z.ZodType<JsonObject>;

export const classificationSchema = z.object({
  templateId: templateIdSchema,
  confidence: z.number().min(0).max(1).nullable().optional(),
  provider: z.enum(CLASSIFICATION_PROVIDERS),
  probabilities: z.record(z.string(), z.number()).optional(),
});

const optionalNullable = <T extends z.ZodType>(schema: T) => schema.nullable().optional();

export const scanInputSchema = z.object({
  id: z.string().optional(),
  createdAt: isoDateTimeSchema.optional(),
  source: z.enum(SCAN_SOURCES),
  text: z.string(),
  templateId: optionalNullable(templateIdSchema),
  classification: optionalNullable(classificationSchema),
  data: optionalNullable(jsonValueSchema),
  lineCount: optionalNullable(z.number().int().min(0)),
  averageConfidence: optionalNullable(z.number().min(0).max(1)),
  pageCount: optionalNullable(z.number().int().min(0)),
  device: optionalNullable(z.string().max(200)),
});
export type ScanInput = z.infer<typeof scanInputSchema>;

export const scanPatchSchema = z
  .object({
    templateId: optionalNullable(templateIdSchema),
    data: optionalNullable(jsonValueSchema),
    classification: optionalNullable(classificationSchema),
  })
  .refine(
    (patch) =>
      patch.templateId !== undefined || patch.data !== undefined || patch.classification !== undefined,
    { message: "Provide at least one of templateId, data, classification" },
  );
export type ScanPatch = z.infer<typeof scanPatchSchema>;

/** Query strings: treat empty values as absent. */
const queryParam = <T extends z.ZodType>(schema: T) =>
  z.preprocess((value) => (value === "" ? undefined : value), schema.optional());

export const scanListQuerySchema = z.object({
  limit: z.preprocess(
    (value) => (value === "" || value === undefined ? undefined : value),
    z.coerce
      .number()
      .int()
      .min(1)
      .optional()
      .transform((value) => Math.min(value ?? 50, 200)),
  ),
  templateId: queryParam(templateIdSchema),
  q: queryParam(z.string().max(500)),
  updatedAfter: queryParam(isoDateTimeSchema),
  cursor: queryParam(z.string().max(1000)),
});
export type ScanListQuery = z.infer<typeof scanListQuerySchema>;

export const MAX_TEMPLATE_RULES = 100;
/** `field` or `array[].field`; segments may be any key without `.`, `[` or `]`. */
export const RULE_TARGET_PATTERN = /^[^.[\]]+(?:\[\]\.[^.[\]]+)?$/;

/**
 * A rule is any JSON object with a string `set` target. A record (not z.object) is used so the
 * parsed output keeps the client's key order.
 */
export const templateRuleSchema = z.record(z.string(), jsonValueSchema).superRefine((rule, ctx) => {
  const target = rule.set;
  if (typeof target !== "string") {
    ctx.addIssue({ code: "custom", path: ["set"], message: 'Rule must have a string "set" target path' });
  } else if (!RULE_TARGET_PATTERN.test(target)) {
    ctx.addIssue({ code: "custom", path: ["set"], message: 'Target path must be "field" or "array[].field"' });
  }
}) as unknown as z.ZodType<TemplateRule>;

export const templateRulesSchema = z
  .array(templateRuleSchema)
  .max(MAX_TEMPLATE_RULES, `At most ${MAX_TEMPLATE_RULES} rules`);

export const templateInputSchema = z.object({
  id: z.string().optional(),
  name: z.string().trim().min(1).max(200),
  description: z.string().trim().min(1).max(4000),
  keywords: z.array(z.string().trim().min(1).max(200)).max(500).nullable().optional(),
  sample: jsonObjectSchema,
  instructions: z.string().max(20000).nullable().optional(),
  rules: templateRulesSchema.nullable().optional(),
});
export type TemplateInput = z.infer<typeof templateInputSchema>;

export const classifyRequestSchema = z.object({
  text: z.string().refine((text) => text.trim().length > 0, "must not be empty"),
  templateIds: z.array(templateIdSchema).min(1).optional(),
});
export type ClassifyRequest = z.infer<typeof classifyRequestSchema>;

export const validateRequestSchema = z.object({
  templateId: templateIdSchema,
  data: jsonValueSchema,
});
