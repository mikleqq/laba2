"""Request context middleware: request id, access logging, last-resort error handler."""

from __future__ import annotations

import logging
import time
import uuid

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from .errors import error_body
from .logging import log_extra, request_id_var, service_var

logger = logging.getLogger("shopcommon.http")

REQUEST_ID_HEADER = "X-Request-ID"
_QUIET_PATHS = {"/health", "/ready"}


class RequestContextMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, service_name: str) -> None:
        super().__init__(app)
        self.service_name = service_name

    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get(REQUEST_ID_HEADER) or uuid.uuid4().hex
        rid_token = request_id_var.set(request_id)
        svc_token = service_var.set(self.service_name)
        started = time.perf_counter()
        try:
            try:
                response = await call_next(request)
            except Exception:  # noqa: BLE001 - last line of defence, never leak a stack trace
                logger.exception("unhandled error")
                response = JSONResponse(status_code=500, content=error_body("internal_error", "Internal server error"))
            duration_ms = round((time.perf_counter() - started) * 1000, 2)
            response.headers[REQUEST_ID_HEADER] = request_id
            if request.url.path not in _QUIET_PATHS:
                logger.info(
                    "request completed",
                    extra=log_extra(
                        method=request.method,
                        path=request.url.path,
                        status=response.status_code,
                        duration_ms=duration_ms,
                    ),
                )
            return response
        finally:
            request_id_var.reset(rid_token)
            service_var.reset(svc_token)
