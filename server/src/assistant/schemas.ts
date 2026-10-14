import { z } from "zod";
import { isValidTimeZone } from "./time.js";

/** Previous chat turns kept for a run (the newest), and the characters kept of each. */
export const MAX_HISTORY_TURNS = 12;
export const MAX_HISTORY_TEXT = 4000;
export const MAX_RUN_WAIT_SECONDS = 25;

const nonEmpty = (text: string) => text.trim().length > 0;

export const routeRequestSchema = z.object({
  text: z.string().max(100_000).refine(nonEmpty, "must not be empty"),
  context: z.string().max(100_000).optional(),
  budget: z.enum(["low", "medium", "high"]).optional(),
  deviceAvailable: z.boolean().optional(),
});

export const runRequestSchema = z.object({
  prompt: z.string().max(100_000).refine(nonEmpty, "must not be empty"),
  history: z
    .array(z.object({ role: z.enum(["user", "assistant"]), text: z.string().max(1_000_000) }))
    .max(1000)
    .optional(),
  rulesPath: z.string().nullable().optional(),
  openNote: z.string().optional(),
  transcriptPath: z.string().optional(),
  timeZone: z.string().refine(isValidTimeZone, "must be an IANA time zone such as Asia/Taipei").optional(),
  /** Cloud tier from POST /v1/assistant/route (default large). */
  tier: z.enum(["small", "medium", "large"]).optional(),
  effort: z.enum(["low", "medium", "high"]).optional(),
  /** A model picked in the app's settings for this tier (one GET /v1/assistant/models lists); default the tier's. */
  model: z
    .string()
    .max(100)
    .regex(/^claude-[a-z0-9][a-z0-9.\-]*$/, "must be a Claude model id such as claude-sonnet-5-5")
    .optional(),
  /** Switch the server tools for this run (default: the server's ASSISTANT_CODE_EXECUTION / ASSISTANT_WEB_SEARCH). */
  codeExecution: z.boolean().optional(),
  webSearch: z.boolean().optional(),
  /** Fewer model calls than the server's ASSISTANT_MAX_TURNS (never more). */
  maxTurns: z.number().int().min(1).optional(),
});
export type RunRequest = z.infer<typeof runRequestSchema>;

const queryNumber = z.preprocess((value) => (value === "" ? undefined : value), z.coerce.number().optional());

export const runQuerySchema = z.object({
  after: queryNumber.pipe(z.number().int().min(0).optional()).transform((value) => value ?? 0),
  wait: queryNumber.transform((value) => Math.min(Math.max(value ?? 0, 0), MAX_RUN_WAIT_SECONDS)),
});

export const undoRequestSchema = z.object({
  editIds: z.array(z.string()).max(10_000).optional(),
});
