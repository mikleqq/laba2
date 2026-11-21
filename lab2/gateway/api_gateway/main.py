"""API Gateway.

Responsibilities:
* routing        ``/api/<service>/...`` -> ``http://<service>:8000/<service>/...``
* authentication JWT is verified at the edge (invalid tokens never reach services)
* authorization  coarse role checks (e.g. only admins modify the catalog)
* rate limiting  sliding window per client
* aggregation    ``GET /api/orders/{id}/summary`` = order + payment in one call
* logging        structured access logs with request id propagation
"""

import asyncio
from typing import Optional

import httpx
from fastapi import APIRouter, Depends, FastAPI, Request, Response

from shopcommon.app import create_service_app
from shopcommon.errors import BadRequestError, NotFoundError, UnauthorizedError
from shopcommon.http import ServiceClient
from shopcommon.schemas import error_responses
from shopcommon.security import CurrentUser, decode_access_token

from .config import Settings
from .policies import SlidingWindowRateLimiter, authorize, is_public

_HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
    "transfer-encoding", "upgrade", "host", "content-length", "content-encoding",
}
_STRIPPED_REQUEST_HEADERS = _HOP_BY_HOP | {"x-internal-token", "x-user-id", "x-user-role"}


def _client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _authenticate(request: Request) -> Optional[CurrentUser]:
    header = request.headers.get("authorization", "")
    settings: Settings = request.app.state.settings
    if header.lower().startswith("bearer "):
        return decode_access_token(header[7:].strip(), settings.jwt_secret, settings.jwt_algorithm)
    if is_public(request.method, request.url.path):
        return None
    raise UnauthorizedError("Missing bearer token")


async def gateway_guard(request: Request) -> Optional[CurrentUser]:
    """Rate limit -> authenticate -> authorize. Used by every proxied route."""
    request.app.state.rate_limiter.check(_client_ip(request))
    user = _authenticate(request)
    if user is not None:
        authorize(request.method, request.url.path, user)
    return user


def _forward_headers(request: Request, user: Optional[CurrentUser]) -> dict[str, str]:
    headers = {k: v for k, v in request.headers.items() if k.lower() not in _STRIPPED_REQUEST_HEADERS}
    headers["X-Forwarded-For"] = _client_ip(request)
    if user is not None:
        headers["X-User-Id"] = str(user.id)
        headers["X-User-Role"] = user.role
    return headers


def _to_response(upstream: httpx.Response) -> Response:
    headers = {k: v for k, v in upstream.headers.items() if k.lower() not in _HOP_BY_HOP and k.lower() != "x-request-id"}
    return Response(content=upstream.content, status_code=upstream.status_code, headers=headers)


aggregation_router = APIRouter(prefix="/api", tags=["aggregation"])
proxy_router = APIRouter(prefix="/api", tags=["proxy"])


@aggregation_router.get(
    "/orders/{order_id}/summary",
    summary="Order with its payment (aggregated from order-service and payment-service)",
    responses=error_responses(401, 404, 429, 502, 504),
)
async def order_summary(order_id: int, request: Request, user: Optional[CurrentUser] = Depends(gateway_guard)):
    clients: dict[str, ServiceClient] = request.app.state.clients
    headers = {"Authorization": request.headers["authorization"]}
    order_resp, payment_resp = await asyncio.gather(
        clients["orders"].request("GET", f"/orders/{order_id}", headers=headers),
        clients["payments"].request("GET", f"/payments/order/{order_id}", headers=headers),
    )
    if order_resp.status_code != 200:
        return _to_response(order_resp)
    payment = payment_resp.json() if payment_resp.status_code == 200 else None
    return {"order": order_resp.json(), "payment": payment}


_METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"]

# public path segment -> service name used in logs and error messages
SERVICE_NAMES = {
    "auth": "auth-service",
    "users": "user-service",
    "products": "product-service",
    "orders": "order-service",
    "payments": "payment-service",
    "notifications": "notification-service",
}


@proxy_router.api_route("/{service}", methods=_METHODS, include_in_schema=False)
@proxy_router.api_route("/{service}/{path:path}", methods=_METHODS, include_in_schema=False)
async def proxy(
    service: str, request: Request, path: str = "", user: Optional[CurrentUser] = Depends(gateway_guard)
) -> Response:
    clients: dict[str, ServiceClient] = request.app.state.clients
    client = clients.get(service)
    if client is None:
        raise NotFoundError(f"Unknown API route /api/{service}")
    if ".." in path or path.startswith("/"):
        raise BadRequestError("Invalid path")
    upstream_path = f"/{service}/{path}" if path else f"/{service}"
    upstream = await client.request(
        request.method,
        upstream_path,
        content=await request.body(),
        params=list(request.query_params.multi_items()),
        headers=_forward_headers(request, user),
        raise_on_server_error=False,
    )
    return _to_response(upstream)


def create_app(
    settings: Optional[Settings] = None, *, transports: Optional[dict[str, httpx.AsyncBaseTransport]] = None
) -> FastAPI:
    settings = settings or Settings()
    transports = transports or {}
    clients = {
        name: ServiceClient(
            SERVICE_NAMES[name], url, timeout=settings.http_timeout_seconds, transport=transports.get(name), connect_retries=1
        )
        for name, url in settings.upstreams().items()
    }

    async def upstream_check(client: ServiceClient) -> bool:
        response = await client.request("GET", "/health")
        return response.status_code == 200

    async def on_shutdown(app: FastAPI) -> None:
        for client in clients.values():
            await client.close()

    app = create_service_app(
        settings=settings,
        title="ShopHub API Gateway",
        description=(
            "Single entry point for clients. All business endpoints are available under `/api/<service>/...` "
            "and are proxied to the services (see each service's own Swagger UI for the full contract)."
        ),
        use_messaging=False,
        routers=[aggregation_router, proxy_router],
        on_shutdown=on_shutdown,
        ready_checks={name: (lambda c=client: upstream_check(c)) for name, client in clients.items()},
    )
    app.state.clients = clients
    app.state.rate_limiter = SlidingWindowRateLimiter(settings.rate_limit_requests, settings.rate_limit_window_seconds)
    return app


app = create_app()
