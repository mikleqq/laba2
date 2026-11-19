"""End-to-end business scenarios through the API Gateway (all services in-process)."""

from conftest import ADMIN


async def _register_and_login(gw, email="alice@example.com", password="Secret123!", name="Alice"):
    r = await gw.post("/api/auth/register", json={"email": email, "password": password, "full_name": name})
    assert r.status_code == 201, r.text
    r = await gw.post("/api/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}, r.json()["user"]["id"]


async def test_successful_purchase_flow(system):
    gw = system["gateway"]
    headers, user_id = await _register_and_login(gw)

    # profile was created synchronously by auth-service -> user-service
    r = await gw.get("/api/users/me", headers=headers)
    assert r.status_code == 200 and r.json()["full_name"] == "Alice"

    # admin fills the catalog
    r = await gw.post("/api/products", json={"name": "Keyboard", "price": 80, "stock": 3}, headers=ADMIN)
    assert r.status_code == 201, r.text
    product = r.json()

    # customer places an order: REST to product-service, then async payment
    r = await gw.post("/api/orders", json={"items": [{"product_id": product["id"], "quantity": 2}]}, headers=headers)
    assert r.status_code == 201, r.text
    order = r.json()
    assert order["status"] == "pending_payment" and order["total_amount"] == 160.0

    await system.bus.join()  # order.created -> payment -> payment.completed -> order + notifications

    r = await gw.get(f"/api/orders/{order['id']}", headers=headers)
    assert r.json()["status"] == "paid"

    r = await gw.get(f"/api/orders/{order['id']}/summary", headers=headers)
    summary = r.json()
    assert summary["order"]["status"] == "paid"
    assert summary["payment"]["status"] == "completed" and summary["payment"]["amount"] == 160.0

    assert (await gw.get(f"/api/products/{product['id']}")).json()["stock"] == 1

    r = await gw.get("/api/notifications", headers=headers)
    types = [n["event_type"] for n in r.json()["items"]]
    assert sorted(types) == ["order.created", "payment.completed", "user.registered"]

    # every event of the purchase carries the request id of the original HTTP call
    order_event = system.bus.events_of("order.created")[0]
    payment_event = system.bus.events_of("payment.completed")[0]
    assert order_event["request_id"] == payment_event["request_id"]


async def test_failed_payment_releases_stock(system):
    gw = system["gateway"]
    headers, _ = await _register_and_login(gw, "bob@example.com", name="Bob")
    product = (await gw.post("/api/products", json={"name": "TV", "price": 900, "stock": 5}, headers=ADMIN)).json()

    # 2 x 900 = 1800 > payment limit (1000 in the test config)
    r = await gw.post("/api/orders", json={"items": [{"product_id": product["id"], "quantity": 2}]}, headers=headers)
    order = r.json()
    await system.bus.join()

    summary = (await gw.get(f"/api/orders/{order['id']}/summary", headers=headers)).json()
    assert summary["order"]["status"] == "payment_failed"
    assert summary["payment"]["status"] == "failed"
    assert (await gw.get(f"/api/products/{product['id']}")).json()["stock"] == 5

    notes = (await gw.get("/api/notifications", headers=headers)).json()["items"]
    assert any(n["event_type"] == "payment.failed" for n in notes)


async def test_cancel_paid_order_refunds(system):
    gw = system["gateway"]
    headers, _ = await _register_and_login(gw, "carol@example.com", name="Carol")
    product = (await gw.post("/api/products", json={"name": "Mug", "price": 10, "stock": 10}, headers=ADMIN)).json()
    order = (
        await gw.post("/api/orders", json={"items": [{"product_id": product["id"], "quantity": 1}]}, headers=headers)
    ).json()
    await system.bus.join()

    r = await gw.post(f"/api/orders/{order['id']}/cancel", headers=headers)
    assert r.status_code == 200 and r.json()["status"] == "cancelled"
    await system.bus.join()

    summary = (await gw.get(f"/api/orders/{order['id']}/summary", headers=headers)).json()
    assert summary["payment"]["status"] == "refunded"
    assert (await gw.get(f"/api/products/{product['id']}")).json()["stock"] == 10


async def test_users_cannot_see_each_others_data(system):
    gw = system["gateway"]
    alice, _ = await _register_and_login(gw, "alice2@example.com", name="Alice")
    eve, eve_id = await _register_and_login(gw, "eve@example.com", name="Eve")
    product = (await gw.post("/api/products", json={"name": "Pen", "price": 1, "stock": 10}, headers=ADMIN)).json()
    order = (
        await gw.post("/api/orders", json={"items": [{"product_id": product["id"], "quantity": 1}]}, headers=alice)
    ).json()
    await system.bus.join()

    assert (await gw.get(f"/api/orders/{order['id']}", headers=eve)).status_code == 404
    assert (await gw.get(f"/api/orders/{order['id']}/summary", headers=eve)).status_code == 404
    assert (await gw.get(f"/api/payments/order/{order['id']}", headers=eve)).status_code == 404
    assert (await gw.get("/api/users", headers=eve)).status_code == 403
    assert (await gw.get(f"/api/users/{eve_id}", headers=eve)).status_code == 200
