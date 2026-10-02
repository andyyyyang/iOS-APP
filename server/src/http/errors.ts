import type { ErrorRequestHandler, RequestHandler } from "express";
import { AppError, toErrorBody } from "../errors.js";

export const notFoundHandler: RequestHandler = (req, res) => {
  res.status(404).json(toErrorBody(new AppError(404, "not_found", `Route not found: ${req.method} ${req.path}`)));
};

interface HttpLikeError {
  status?: number;
  statusCode?: number;
  type?: string;
  expose?: boolean;
  message?: string;
}

export const errorHandler: ErrorRequestHandler = (err: unknown, _req, res, next) => {
  if (res.headersSent) return next(err);
  if (err instanceof AppError) {
    res.status(err.status).json(toErrorBody(err));
    return;
  }

  // body-parser / http-errors style failures
  const httpError = err as HttpLikeError;
  const status = httpError.status ?? httpError.statusCode;
  if (httpError.type === "entity.parse.failed") {
    res.status(400).json(toErrorBody(new AppError(400, "invalid_json", "Request body is not valid JSON")));
    return;
  }
  if (httpError.type === "entity.too.large") {
    res.status(413).json(toErrorBody(new AppError(413, "payload_too_large", "Request body exceeds 5mb")));
    return;
  }
  if (typeof status === "number" && status >= 400 && status < 500) {
    const message = httpError.expose && httpError.message ? httpError.message : "Bad request";
    res.status(status).json(toErrorBody(new AppError(status, "bad_request", message)));
    return;
  }

  console.error("[http] unhandled error", err);
  res.status(500).json(toErrorBody(new AppError(500, "internal_error", "Internal server error")));
};
