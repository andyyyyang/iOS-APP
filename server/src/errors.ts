import type { ZodError } from "zod";

/** A failure with a stable machine-readable code, rendered as `{"error":{"code","message"}}`. */
export class AppError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

export const notFound = (what: string, id: string) =>
  new AppError(404, "not_found", `${what} not found: ${id}`);

export const invalidRequest = (message: string) => new AppError(400, "invalid_request", message);

/** Converts zod issues into a single readable 400 error. */
export function fromZodError(error: ZodError, prefix = ""): AppError {
  const details = error.issues
    .map((issue) => {
      const path = issue.path.length ? issue.path.map(String).join(".") : "(body)";
      return `${prefix}${path}: ${issue.message}`;
    })
    .join("; ");
  return invalidRequest(details || "Invalid request");
}

export function toErrorBody(error: AppError) {
  return { error: { code: error.code, message: error.message } };
}
