import httpx
import pytest

from api_gateway.config import Settings
from api_gateway.main import create_app
from api_gateway.policies import SlidingWindowRateLimiter, is_public
from conftest import JWT_SECRET, auth, client, running
from shopcommon.errors import RateLimitError


def _echo_transport(seen: list):
    def handler(request: httpx.Request):
        seen.append(request)
        return httpx.Response(200, json={"path": request.url.path, "query": str(request.url.query, "ascii")})

    return httpx.MockTransport(handler)


def _gateway(seen, **overrides):
    names = ["auth", "users", "products", "orders", "payments", "notifications"]
    return create_app(
        Settings(jwt_secret=JWT_SECRET, **overrides), transports={n: _echo_transport(seen) for n in names}
    )


def test_public_routes():
    assert is_public("POST", "/api/auth/login")
    assert is_public("GET", "/api/products")
    assert is_public("GET", "/api/products/5")
    assert not is_public("POST", "/api/products")
    assert not is_public("GET", "/api/orders")


def test_rate_limiter_window():
    limiter = SlidingWindowRateLimiter(limit=2, window_seconds=10)
    limiter.check("ip", now=0)
    limiter.check("ip", now=1)
    with pytest.raises(RateLimitError) as exc:
        limiter.check("ip", now=2)
    assert exc.value.headers["Retry-After"] == "8"
    limiter.check("ip", now=10.5)  # first hit expired
    limiter.check("other-ip", now=2)


async def test_routing_and_header_handling():
    seen = []
    app = _gateway(seen)
    async with running(app), client(app) as c:
        r = await c.get("/api/products", params={"search": "pen"})
        assert r.status_code == 200
        assert r.json() == {"path": "/products", "query": "search=pen"}

        r = await c.get("/api/orders/5", headers={**auth(3), "X-Internal-Token": "spoofed", "X-User-Id": "1"})
        assert r.json()["path"] == "/orders/5"
        forwarded = seen[-1].headers
        assert "x-internal-token" not in forwarded  # clients can never reach /internal endpoints
        assert forwarded["x-user-id"] == "3"
        assert forwarded["x-request-id"] == r.headers["x-request-id"]


async def test_authentication_and_authorization_at_the_edge():
    seen = []
    app = _gateway(seen)
    async with running(app), client(app) as c:
        assert (await c.get("/api/orders")).status_code == 401
        assert (await c.get("/api/orders", headers={"Authorization": "Bearer bad"})).status_code == 401
        assert (await c.post("/api/products", json={}, headers=auth())).status_code == 403
        assert (await c.post("/api/products", json={}, headers=auth(role="admin"))).status_code == 200
        assert (await c.get("/api/unknown/x", headers=auth())).status_code == 404
        assert (await c.get("/api/users/..%2F..%2Finternal", headers=auth())).status_code in (400, 404)
        assert len(seen) == 1  # only the admin request reached a service


async def test_rate_limit_returns_429():
    seen = []
    app = _gateway(seen, rate_limit_requests=3)
    async with running(app), client(app) as c:
        codes = [(await c.get("/api/products")).status_code for _ in range(4)]
        assert codes == [200, 200, 200, 429]
        r = await c.get("/api/products")
        assert r.json()["error"]["code"] == "rate_limited" and "retry-after" in r.headers


async def test_unreachable_service_gives_502_and_not_ready():
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)

    names = ["auth", "users", "products", "orders", "payments", "notifications"]
    app = create_app(Settings(jwt_secret=JWT_SECRET), transports={n: httpx.MockTransport(refuse) for n in names})
    async with running(app), client(app) as c:
        r = await c.get("/api/products")
        assert r.status_code == 502
        assert "Traceback" not in r.text
        r = await c.get("/ready")
        assert r.status_code == 503
        assert r.json()["checks"]["products"] is False
