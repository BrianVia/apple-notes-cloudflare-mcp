import type { Context } from "hono";
import type { HonoBindings } from "./env";

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
  }
}

export const BadRequest = (code: string, message: string, details?: unknown) =>
  new ApiError(400, code, message, details);
export const Unauthorized = (message = "unauthorized") =>
  new ApiError(401, "unauthorized", message);
export const Forbidden = (message = "forbidden") =>
  new ApiError(403, "forbidden", message);
export const NotFound = (message = "not found") =>
  new ApiError(404, "not_found", message);
export const Conflict = (code: string, message: string) =>
  new ApiError(409, code, message);
export const TooLarge = (message = "payload too large") =>
  new ApiError(413, "payload_too_large", message);
export const RateLimited = (message = "rate limited") =>
  new ApiError(429, "rate_limited", message);
export const Internal = (message = "internal error") =>
  new ApiError(500, "internal", message);

export function errorHandler(err: Error, c: Context<HonoBindings>) {
  if (err instanceof ApiError) {
    return c.json(
      { error: { code: err.code, message: err.message, details: err.details } },
      err.status as 400 | 401 | 403 | 404 | 409 | 413 | 429 | 500,
    );
  }
  console.error("Unhandled error:", err);
  return c.json(
    { error: { code: "internal", message: "internal server error" } },
    500,
  );
}
