import type { z } from "zod";
import { fromZodError } from "../errors.js";

/** Parses input with a shared schema, throwing a 400 AppError on failure. */
export function parse<T extends z.ZodType>(schema: T, input: unknown, prefix = ""): z.output<T> {
  const result = schema.safeParse(input);
  if (!result.success) throw fromZodError(result.error, prefix);
  return result.data;
}
