"""Unified error model and FastAPI exception handlers.

All errors are returned as::

    {"error": {"code": "not_found", "message": "...", "request_id": "...", "details": ...}}

Stack traces are never sent to the client; unexpected errors are logged and
returned as a generic ``internal_error``.
"""

from __future__ import annotations

import logging
from typing import Any, Optional

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError
from starlette.exceptions import HTTPException as StarletteHTTPException

from .logging import log_extra, request_id_var

logger = logging.getLogger("shopcommon.errors")


class AppError(Exception):
    status_code: int = 500
    code: str = "internal_error"
    message: str = "Internal server error"

    def __init__(
        self,
        message: Optional[str] = None,
        *,
        code: Optional[str] = None,
        status_code: Optional[int] = None,
        details: Any = None,
        headers: Optional[dict[str, str]] = None,
    ) -> None:
        self.message = message or self.message
        self.code = code or self.code
        self.status_code = status_code or self.status_code
        self.details = details
        self.headers = headers
        super().__init__(self.message)


class BadRequestError(AppError):
    status_code = 400
    code = "bad_request"
    message = "Bad request"


class UnauthorizedError(AppError):
    status_code = 401
    code = "unauthorized"
    message = "Authentication required"


class ForbiddenError(AppError):
    status_code = 403
    code = "forbidden"
    message = "You do not have permission to perform this action"


class NotFoundError(AppError):
    status_code = 404
    code = "not_found"
    message = "Resource not found"


class ConflictError(AppError):
    status_code = 409
    code = "conflict"
    message = "Resource state conflict"


class RateLimitError(AppError):
    status_code = 429
    code = "rate_limited"
    message = "Too many requests"


class UpstreamError(AppError):
    status_code = 502
    code = "upstream_error"
    message = "A dependent service failed"


class ServiceUnavailableError(AppError):
    status_code = 503
    code = "service_unavailable"
    message = "Service temporarily unavailable"


class UpstreamTimeoutError(AppError):
    status_code = 504
    code = "upstream_timeout"
    message = "A dependent service did not respond in time"


def error_body(code: str, message: str, details: Any = None) -> dict[str, Any]:
    body: dict[str, Any] = {"code": code, "message": message, "request_id": request_id_var.get()}
    if details is not None:
        body["details"] = details
    return {"error": body}


_HTTP_CODES = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    405: "method_not_allowed",
}


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
        level = logging.WARNING if exc.status_code < 500 else logging.ERROR
        logger.log(level, exc.message, extra=log_extra(error_code=exc.code, status=exc.status_code))
        return JSONResponse(
            status_code=exc.status_code,
            content=error_body(exc.code, exc.message, exc.details),
            headers=exc.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        details = [
            {"field": ".".join(str(p) for p in err.get("loc", ()) if p != "body"), "message": err.get("msg", "")}
            for err in exc.errors()
        ]
        logger.warning("validation failed", extra=log_extra(details=details))
        return JSONResponse(status_code=422, content=error_body("validation_error", "Invalid input data", details))

    @app.exception_handler(StarletteHTTPException)
    async def handle_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = _HTTP_CODES.get(exc.status_code, "http_error")
        message = exc.detail if isinstance(exc.detail, str) else "HTTP error"
        return JSONResponse(status_code=exc.status_code, content=error_body(code, message), headers=exc.headers)

    @app.exception_handler(SQLAlchemyError)
    async def handle_db_error(request: Request, exc: SQLAlchemyError) -> JSONResponse:
        logger.exception("database error")
        return JSONResponse(status_code=503, content=error_body("database_error", "Database is temporarily unavailable"))
