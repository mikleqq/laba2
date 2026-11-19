# Architecture

## 1. Domain decomposition

The online store is split by **business capability**. Each service owns its data and is the only writer of it.

| Bounded context | Owns | Does *not* know about |
|---|---|---|
| Auth | credentials, roles, tokens | profiles, orders |
| User | profile data | passwords, orders |
| Product | catalog, stock levels | who bought what |
| Order | orders and their items (price snapshot) | payment details, product descriptions |
| Payment | payments, transactions, refunds | items, stock |
| Notification | messages sent to users | how orders/payments work |

Data from other contexts is referenced only by **id** (for example `order_items.product_id`). It is never
joined across databases. When an order needs to keep the past state of another context, it copies it as a
snapshot: `product_name` and `unit_price` are stored in the order, so later price changes do not alter it.

## 2. Why these boundaries

* **Auth vs User**: security-critical data (password hashes) is kept apart from ordinary profile data, so it can
  have different access rules, its own scaling and its own audit.
* **Order vs Payment**: payments talk to an external provider, are slow and can fail. Doing them asynchronously
  keeps `POST /orders` fast and keeps order-service working even when the payment provider is down
  (orders wait in `pending_payment`).
* **Notification**: a pure consumer. New notification types need no change in the producers.

## 3. Communication patterns

### 3.1 Registration (synchronous + event)

```
Client        Gateway        Auth            User            RabbitMQ       Notification
  │ POST /api/auth/register  │               │                  │               │
  ├──────────►│──────────────►│ INSERT credential (flush)        │               │
  │           │               ├─POST /internal/users────────────►│ (REST)        │
  │           │               │◄──────────── 201 ────────────────┤               │
  │           │               │ COMMIT                           │               │
  │           │               ├── user.registered ──────────────►├──────────────►│ welcome
  │◄──────────┤◄── 201 ───────┤                                  │               │
```
If user-service fails or times out, the credential is rolled back and the client gets `502` / `504`.

### 3.2 Purchase (saga: REST step + event choreography)

```
Client   Gateway   Order            Product           RabbitMQ          Payment          Notification
  │ POST /api/orders │                 │                  │                 │                  │
  ├───────►├────────►│ POST /internal/stock/reserve ─────►│ (atomic, 409 if not enough)        │
  │        │         │◄──────── items + prices ───────────┤                 │                  │
  │        │         │ INSERT order (pending_payment)     │                 │                  │
  │        │         ├──── order.created ────────────────►├────────────────►│ charge           │
  │◄───────┤◄─ 201 ──┤                                    │                 │                  │
  │        │         │                                    │◄─ payment.completed / failed ──────┤
  │        │         │◄─── payment.* ─────────────────────┤──────────────────────────────────►│
  │        │         │ paid  |  payment_failed + POST /internal/stock/release                 │
```

### 3.3 Cancellation
`POST /orders/{id}/cancel` → status `cancelled`, stock released (REST), `order.cancelled` published →
payment-service refunds a completed payment (`payment.refunded`). If the payment was not made yet, it writes a
`cancelled` marker, so a late `order.created` is never charged.

## 4. Event catalog

Exchange `shop.events` (topic, durable). Envelope:
`{event_id, event_type, occurred_at, request_id, data}`.

| Routing key | Producer | Consumers | `data` |
|---|---|---|---|
| `user.registered` | auth | notification | `user_id, email, full_name, role` |
| `order.created` | order | payment, notification | `order_id, user_id, total_amount, items[]` |
| `order.cancelled` | order | payment, notification | `order_id, user_id, total_amount, previous_status` |
| `payment.completed` | payment | order, notification | `payment_id, order_id, user_id, amount, transaction_id` |
| `payment.failed` | payment | order, notification | `... , reason` |
| `payment.refunded` | payment | notification | `payment_id, order_id, user_id, amount` |
| `product.low_stock` | product | notification | `product_id, name, stock` |

Queues: `order-service.payments`, `payment-service.orders`, `notification-service.events`, and each has a
`*.dlq` dead-letter queue. Messages are persistent and acknowledged manually after the handler succeeds.
A failed handler rejects the message to the DLQ.

**Idempotency**: payment has `UNIQUE(order_id)`, notification has `UNIQUE(event_id)`, and order only moves
out of `pending_payment` once. Redelivered events therefore do no harm.

## 5. Data storage

```
postgres (one server for the lab)
├── auth_db          owner auth_svc          credentials
├── user_db          owner user_svc          profiles
├── product_db       owner product_svc       products (CHECK stock >= 0)
├── order_db         owner order_svc         orders, order_items
├── payment_db       owner payment_svc       payments (UNIQUE order_id)
└── notification_db  owner notification_svc  notifications (UNIQUE event_id)
```
`REVOKE CONNECT ... FROM PUBLIC`: each role can connect only to its own database, which is checked by the e2e
verification (`order_svc` → `product_db` is refused). Moving any database to its own server needs only a
change of `DATABASE_URL`.

Stock reservation uses `SELECT ... FOR UPDATE` in one transaction. Concurrent orders cannot oversell, and a
multi-item order is all-or-nothing.

## 6. API Gateway

Request pipeline: **request-id → access log → rate limit (per client IP) → JWT validation → role rules → proxy**.

* `/api/<service>/<path>` → `http://<service>:8000/<service>/<path>`, with method, query and body unchanged.
* Strips `X-Internal-Token`, `X-User-*` and hop-by-hop headers from client requests, and adds
  `X-Forwarded-For`, `X-User-Id`, `X-User-Role` and `X-Request-ID`.
* Aggregation: `GET /api/orders/{id}/summary` calls order-service and payment-service in parallel.
* `/ready` reports the health of every upstream.

## 7. Service internals

Every service has the same layered layout:

```
<pkg>/
├── main.py      create_app(): wiring (settings, DB, bus, clients, event subscriptions)
├── api.py       HTTP layer: routing, validation, auth dependencies, OpenAPI metadata
├── service.py   business logic (no FastAPI imports in the domain rules)
├── models.py    SQLAlchemy models (own DeclarativeBase -> own metadata)
├── schemas.py   pydantic request/response models
└── config.py    Settings (env vars)
```

`create_app()` accepts injected transports and event buses. Tests use this to run real services against each
other in one process.
