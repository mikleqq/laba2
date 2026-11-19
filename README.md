# ShopHub — Microservice Online Store (Lab 2)

A backend for an online store built as **6 independent business microservices** plus an
**API Gateway**. Python 3.12 + FastAPI, PostgreSQL (database per service), RabbitMQ
(asynchronous events), all of it run with Docker Compose.

```
                               Client
                                 │  HTTP :8080
                        ┌────────▼─────────┐
                        │   API Gateway    │  routing · JWT check · roles · rate limit
                        │                  │  aggregation · request-id · access logs
                        └──┬───┬───┬───┬───┬──┬──────────────┐
             REST          │   │   │   │   │  │              │
      ┌────────────────────┘   │   │   │   │  └───────┐      │
      ▼              ┌─────────┘   │   │   └────┐     ▼      ▼
┌───────────┐ REST ┌─▼─────────┐ ┌─▼───────┐ ┌──▼──────┐ ┌──────────┐ ┌──────────────┐
│   Auth    ├─────►│   User    │ │ Product │◄┤  Order  │ │ Payment  │ │ Notification │
│  Service  │      │  Service  │ │ Service │ │ Service │ │ Service  │ │   Service    │
└──┬────┬───┘      └─────┬─────┘ └──┬───┬──┘ └─┬────┬──┘ └─┬────┬───┘ └──────┬────┬──┘
   │    │                │          │   │      │    │      │    │            │    │
   ▼    │                ▼          ▼   │      ▼    │      ▼    │            ▼    │
auth_db │             user_db  product_db│  order_db │  payment_db│   notification_db│
        │                                │           │            │                 │
        └───────────────┬────────────────┴───────────┴────────────┴─────────────────┘
                        ▼
              ┌─────────────────────┐
              │ RabbitMQ (topic     │  user.registered, order.created, order.cancelled,
              │ exchange shop.events│  payment.completed, payment.failed, payment.refunded,
              │ + dead-letter queues│  product.low_stock
              └─────────────────────┘
```

More detail (sequence diagrams, event catalog, design decisions): [docs/architecture.md](docs/architecture.md).

## Services

| Service | Responsibility | DB | Sync API (REST) | Events |
|---|---|---|---|---|
| **auth-service** | Credentials, password hashing (PBKDF2), JWT issuing, bootstrap admin | `auth_db` | `/auth/*` | publishes `user.registered` |
| **user-service** | Customer profiles (name, phone, address) | `user_db` | `/users/*`, internal `/internal/users` | — |
| **product-service** | Catalog, stock, atomic stock reservation | `product_db` | `/products/*`, internal `/internal/stock/*` | publishes `product.low_stock` |
| **order-service** | Order lifecycle, saga coordination | `order_db` | `/orders/*` | publishes `order.created`, `order.cancelled`; consumes `payment.*` |
| **payment-service** | Charges / refunds through a (simulated) payment provider | `payment_db` | `/payments/*` | consumes `order.*`; publishes `payment.completed/failed/refunded` |
| **notification-service** | Turns domain events into user notifications (email-channel stub) | `notification_db` | `/notifications/*` | consumes `user.registered`, `order.*`, `payment.*`, `product.low_stock` |
| api-gateway *(infrastructure)* | Single entry point, see below | — | `/api/*` | — |

Each service has its own code package, `Dockerfile`, configuration (`Settings` class plus `.env.example`),
database and Swagger UI. It can be built, started and scaled on its own. `libs/common` is a small
shared **infrastructure** library (logging, error model, JWT helpers, DB/broker plumbing) and has **no
business logic**.

### Interaction between services

* **Synchronous (REST over HTTP)**, used when the caller needs the answer right away:
  * `auth → user`: create the profile while the user registers. If user-service fails, the
    registration is rolled back.
  * `order → product`: reserve stock (all-or-nothing) before an order is accepted, and release it on
    cancellation or failed payment.
  * `gateway → order + payment`: response aggregation (`GET /api/orders/{id}/summary`).
* **Asynchronous (RabbitMQ)**, used when the work can happen later and should not couple services:
  * `order.created → payment-service` charges the order → `payment.completed | payment.failed → order-service`
    (status `paid` / `payment_failed` + stock released) **and** `notification-service`.
  * `order.cancelled → payment-service` (refund) and `notification-service`.
  * `user.registered → notification-service` (welcome message).

Internal endpoints (`/internal/*`) need a shared service token (`X-Internal-Token`). The gateway strips that
header from client requests, so clients can never reach them.

## Technology choices

| Area | Choice | Why |
|---|---|---|
| Language / framework | **Python 3.12 + FastAPI** | async I/O (many service-to-service calls), pydantic validation, OpenAPI/Swagger generated automatically |
| Database | **PostgreSQL 16**, one database + one login role per service | ACID transactions for stock and payments; `REVOKE CONNECT` keeps services from reading each other's data |
| ORM | **SQLAlchemy 2 (async) + asyncpg** | mature, async, the same models run on SQLite in tests |
| Messaging | **RabbitMQ** (topic exchange) via aio-pika | routing by event type (`order.*`), durable queues, ack/reject, dead-letter queues; simpler to run than Kafka for this scale |
| Sync communication | **REST + httpx** | simple, debuggable, documented with OpenAPI |
| Auth | **JWT (HS256, PyJWT)** | stateless: the gateway and every service verify the token locally with no extra call to auth-service |
| Deployment | **Docker Compose** | one command starts 9 containers with health checks and startup order |
| Tests | **pytest + pytest-asyncio + httpx ASGITransport** | the whole system runs in-process, with no Docker needed |

## Quick start

```bash
cp .env.example .env            # optional: change secrets
docker compose up -d --build    # postgres, rabbitmq, 6 services, gateway
curl http://localhost:8080/ready
```

| URL | What |
|---|---|
| http://localhost:8080 | API Gateway (entry point for clients) |
| http://localhost:8080/docs | Gateway Swagger UI (aggregation endpoint) |
| http://localhost:8001/docs … :8006/docs | Swagger UI of auth, user, product, order, payment, notification |
| http://localhost:15672 | RabbitMQ management UI (`shop` / `shop`) |

The direct service ports (8001–8006) are published only for documentation and debugging. In production only
the gateway would be exposed.

A default administrator is created at startup: `admin@example.com` / `Admin12345!`
(set `ADMIN_EMAIL` / `ADMIN_PASSWORD`). The catalog is seeded with 5 demo products.

### Example session (through the gateway)

```bash
# register + login
curl -X POST localhost:8080/api/auth/register -H "Content-Type: application/json" \
     -d '{"email":"alice@example.com","password":"Secret123!","full_name":"Alice"}'
TOKEN=$(curl -s -X POST localhost:8080/api/auth/login -H "Content-Type: application/json" \
     -d '{"email":"alice@example.com","password":"Secret123!"}' | python -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# browse catalog (public) and order
curl localhost:8080/api/products
curl -X POST localhost:8080/api/orders -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"items":[{"product_id":1,"quantity":2}]}'

# a moment later: order is "paid", payment "completed", notifications created
curl localhost:8080/api/orders/1/summary -H "Authorization: Bearer $TOKEN"
curl localhost:8080/api/notifications   -H "Authorization: Bearer $TOKEN"
```

## Main API endpoints (via gateway `/api/...`)

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/api/auth/register` | public | Register a customer (creates the profile in user-service) |
| POST | `/api/auth/login` | public | Get a JWT access token |
| GET | `/api/auth/me` | user | Identity from the token |
| GET | `/api/users/me` | user | Own profile |
| PATCH | `/api/users/me` | user | Update name / phone / address |
| GET | `/api/users/{id}` | self or admin | Profile by id |
| GET | `/api/users` | admin | List profiles |
| GET | `/api/products?search=&category=&limit=&offset=` | public | Browse the catalog |
| GET | `/api/products/{id}` | public | Product details |
| POST | `/api/products` | admin | Create product |
| PATCH / DELETE | `/api/products/{id}` | admin | Update / delete product |
| POST | `/api/orders` | user | Place an order (stock reserved, payment async) |
| GET | `/api/orders?status=` | user | Own orders (admin: all) |
| GET | `/api/orders/{id}` | owner or admin | Order details |
| POST | `/api/orders/{id}/cancel` | owner or admin | Cancel (stock released, payment refunded) |
| GET | `/api/orders/{id}/summary` | owner or admin | **Gateway aggregation**: order + payment |
| GET | `/api/payments` | user | Own payments (admin: all) |
| GET | `/api/payments/order/{order_id}` | owner or admin | Payment of an order |
| GET | `/api/notifications?unread_only=` | user | Own notifications |
| POST | `/api/notifications/{id}/read` | owner | Mark as read |
| GET | `/health`, `/ready` | public | Liveness / readiness on **every** service and the gateway |

The full OpenAPI specs are exported to [docs/openapi/](docs/openapi/). The live Swagger UI is at `/docs` of each service.

### Order statuses

```
pending_payment ──payment.completed──► paid ──cancel──► cancelled (refund)
       │
       ├──payment.failed──► payment_failed (stock released) ──cancel──► cancelled
       └──cancel──► cancelled (stock released, never charged)
```

## Cross-cutting concerns

### Authentication & authorization
* auth-service issues JWTs (`sub`, `email`, `role`, `exp`, `iss`). Passwords are hashed with PBKDF2-HMAC-SHA256 and a per-user salt.
* **Gateway**: rejects missing, invalid or expired tokens (except on public routes) and enforces coarse role rules
  (only `admin` may modify the catalog or list users).
* **Services** check the token again (zero trust inside the network) and apply fine-grained rules, such as
  ownership of orders, payments and notifications. Another user's order returns `404`, so its existence is not revealed.
* Service-to-service endpoints need `X-Internal-Token`.

### Error handling
Every error has the same shape and never contains a stack trace:

```json
{"error": {"code": "insufficient_stock", "message": "Insufficient stock for 'Pen': requested 5, available 1",
           "request_id": "7c3e...", "details": null}}
```

| Situation | HTTP | code |
|---|---|---|
| Invalid input (pydantic) | 422 | `validation_error` (+ `details` per field) |
| Resource missing | 404 | `not_found` |
| Missing / invalid / expired token | 401 | `unauthorized`, `invalid_token`, `token_expired` |
| Not enough rights | 403 | `forbidden` |
| Business conflict | 409 | `email_taken`, `insufficient_stock`, `already_cancelled` |
| Rate limit | 429 | `rate_limited` (+ `Retry-After`) |
| Dependent service down / 5xx | 502 | `upstream_unavailable`, `upstream_error` |
| Dependent service timeout | 504 | `upstream_timeout` |
| Database error | 503 | `database_error` |
| Anything unexpected | 500 | `internal_error` (details only in logs) |

Resilience: timeouts on every outgoing call, retries for connection errors (when the request was never sent),
compensation actions (a failed order rolls back its stock reservation, a failed profile creation rolls back
the registration), idempotent consumers (unique `order_id` / `event_id`), dead-letter queues for poison
messages, and retries on startup while Postgres or RabbitMQ are not ready yet.

### Logging
Structured JSON logs on stdout (`docker compose logs -f order-service`):

```json
{"timestamp": "2026-11-19T21:04:06.895+00:00", "service": "order-service", "level": "INFO",
 "request_id": "814620ae28514f97817173fac34ee924", "logger": "order_service",
 "message": "order created", "order_id": 1, "user_id": 2, "total": "25.00"}
```

The `X-Request-ID` comes from the client or is generated by the gateway. It is passed on with every HTTP call
**and inside every event**, so one purchase can be traced across gateway → order → payment → notification
with a single id. It is also returned to the client in the `X-Request-ID` response header.

### Configuration management
Each service has a `Settings` class (pydantic-settings) that reads environment variables or `.env`.
See `services/<name>/.env.example` for every option. `docker-compose.yml` sets the values for the
containers. Secrets (`JWT_SECRET`, `INTERNAL_TOKEN`, passwords) come from the root `.env`.

### Health checks
* `GET /health`: liveness, the process is up.
* `GET /ready`: readiness, with the dependencies checked: `{"checks": {"database": true, "message_broker": true}}`.
  The gateway's `/ready` checks every upstream service. It returns `503` when a dependency is down.
* Docker health checks use `/health`, and `depends_on: service_healthy` sets the startup order.

## Tests

```bash
pip install -r requirements-dev.txt
pytest                       # 50 unit + integration tests, no Docker needed (~5 s)
docker compose up -d --build
pytest -m e2e                # smoke test against the real stack (PostgreSQL + RabbitMQ)
```

* `tests/unit/` has the tests for each service: business rules, validation, authorization, idempotency,
  timeouts and upstream failures, and the gateway policies (routing, auth, rate limiting, header stripping).
* `tests/integration/` runs **all 6 services and the gateway in-process**. Services call each other through
  `httpx.ASGITransport` and share an in-memory event bus that follows RabbitMQ's topic rules. The tests cover
  the full purchase, a failed payment, a cancellation with refund, and data isolation between users.
* `tests/e2e/` runs the same purchase flow against the real Docker stack. It is skipped if the stack is not running.

## Project structure

```
laba2/
├── README.md
├── docker-compose.yml
├── .env.example
├── libs/common/shopcommon/      # shared infrastructure: logging, errors, security, db, messaging, http client
├── services/
│   ├── auth-service/            # each: <pkg>/{main,api,service,models,schemas,config}.py, Dockerfile, .env.example
│   ├── user-service/
│   ├── product-service/
│   ├── order-service/
│   ├── payment-service/
│   └── notification-service/
├── gateway/                     # API Gateway
├── infrastructure/postgres/     # database-per-service init script
├── tests/{unit,integration,e2e}/
└── docs/                        # architecture.md, openapi/*.json
```

## Known limitations / possible improvements
* Events are published right after the DB commit. A transactional **outbox** would guarantee delivery if the
  broker is down at that moment. For now a failed publish is logged as an error.
* Schemas are created with `create_all`. A real project would use Alembic migrations.
* The rate limiter keeps its state in memory (per gateway instance). With several replicas it would use Redis.
* One PostgreSQL *server* hosts six isolated databases to keep the lab light. Every service can be pointed to
  its own server just by changing `DATABASE_URL`.
