"""Smoke test against the real stack (PostgreSQL + RabbitMQ + 7 containers).

    docker compose up -d --build
    pytest -m e2e

Skipped automatically when the gateway is not reachable.
"""

import os
import time
import uuid

import httpx
import pytest

GATEWAY = os.getenv("GATEWAY_URL", "http://localhost:8080")
ADMIN_EMAIL = os.getenv("ADMIN_EMAIL", "admin@example.com")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "Admin12345!")

pytestmark = pytest.mark.e2e


def _reachable() -> bool:
    try:
        return httpx.get(f"{GATEWAY}/ready", timeout=2).status_code == 200
    except httpx.HTTPError:
        return False


@pytest.fixture(scope="module")
def gw():
    if not _reachable():
        pytest.skip(f"stack is not running at {GATEWAY}")
    with httpx.Client(base_url=GATEWAY, timeout=10) as c:
        yield c


def _login(gw, email, password):
    r = gw.post("/api/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _wait_for(predicate, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    raise AssertionError("condition not met in time")


def test_purchase_through_real_broker(gw):
    email = f"e2e-{uuid.uuid4().hex[:8]}@example.com"
    assert gw.post("/api/auth/register", json={"email": email, "password": "Secret123!", "full_name": "E2E"}).status_code == 201
    user = _login(gw, email, "Secret123!")
    admin = _login(gw, ADMIN_EMAIL, ADMIN_PASSWORD)

    product = gw.post("/api/products", json={"name": "E2E item", "price": 12.5, "stock": 5}, headers=admin).json()
    order = gw.post("/api/orders", json={"items": [{"product_id": product["id"], "quantity": 2}]}, headers=user).json()
    assert order["status"] == "pending_payment"

    summary = _wait_for(
        lambda: (s := gw.get(f"/api/orders/{order['id']}/summary", headers=user).json())["order"]["status"] == "paid" and s
    )
    assert summary["payment"]["status"] == "completed"
    assert gw.get(f"/api/products/{product['id']}").json()["stock"] == 3

    notes = _wait_for(lambda: (n := gw.get("/api/notifications", headers=user).json())["total"] >= 3 and n)
    assert {"user.registered", "order.created", "payment.completed"} <= {i["event_type"] for i in notes["items"]}
