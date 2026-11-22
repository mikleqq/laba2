# ShopHub — Microservice Online Store (Lab 2)

A consumer electronics store built from **6 independent microservices running in 6 Docker containers**,
sharing **one PostgreSQL database** (with a separate schema and login role per service), plus a web UI that
shows live what happens when a service fails.

```
                         Browser: frontend/index.html
          (shop + live "control room" with the state of every microservice)
                                     │ REST (each service directly)
   ┌──────────┬──────────┬──────────┼──────────┬──────────┬──────────────┐
   ▼          ▼          ▼          ▼          ▼          ▼              │
┌──────┐  ┌──────┐  ┌─────────┐  ┌───────┐  ┌─────────┐  ┌──────────────┐
│ auth │─►│ user │  │ product │◄─│ order │  │ payment │  │ notification │   6 containers
│:8001 │  │:8002 │  │  :8003  │  │ :8004 │  │  :8005  │  │    :8006     │
└──┬───┘  └──┬───┘  └────┬────┘  └───┬───┘  └────┬────┘  └──────┬───────┘
   │         │           │           │           │              │
   ▼         ▼           ▼           ▼           ▼              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ PostgreSQL — ONE database "shophub" (installed locally, outside Docker)    │
│  schemas: auth │ users │ products │ orders │ payments │ notifications      │
│  bus.events  ← asynchronous events between services (order.created, ...)   │
└──────────────────────────────────────────────────────────────────────────┘
```

Architecture details: [docs/architecture.md](docs/architecture.md). Step-by-step demo guide (Russian):
[docs/DEMO_RU.md](docs/DEMO_RU.md).

## Services

| # | Service | Container / port | Responsibility | Schema (tables) | Events |
|---|---|---|---|---|---|
| 1 | **auth-service** | `auth-service` :8001 | registration, login, password hashing (PBKDF2), JWT | `auth` (credentials) | publishes `user.registered` |
| 2 | **user-service** | `user-service` :8002 | customer profiles | `users` (profiles) | — |
| 3 | **product-service** | `product-service` :8003 | catalog, stock, atomic stock reservation | `products` (products) | publishes `product.low_stock` |
| 4 | **order-service** | `order-service` :8004 | order lifecycle (saga) | `orders` (orders, order_items) | publishes `order.*`; consumes `payment.*` |
| 5 | **payment-service** | `payment-service` :8005 | charges / refunds via a simulated provider | `payments` (payments) | consumes `order.*`; publishes `payment.*` |
| 6 | **notification-service** | `notification-service` :8006 | turns events into user notifications | `notifications` (notifications) | consumes `user.registered`, `order.*`, `payment.*` |

Every service has its own code package, `Dockerfile`, configuration (`Settings` class + `.env.example`), API
with Swagger UI, business logic, error handling and structured logging. `libs/common` is a small shared
**infrastructure** library (logging, errors, JWT, DB and event-bus plumbing) with no business logic.

### Why one database (and how the services stay separated)

The lab allows a shared database when the choice is justified. Here it is:

* **Simple to run.** One PostgreSQL server (already installed locally) instead of six, and only 6 containers in Docker.
* **Logical isolation is kept.** Every service has its own **schema** and **login role**, and a role can access only
  its own schema (`permission denied` otherwise; `scripts/show-db.ps1` shows this). No service reads another
  service's tables. Data from other services is obtained only through their API or events.
* **One less moving part.** The database also carries the event bus (`bus.events`), so no separate message broker is needed.
* **Can be split later.** Moving a schema to its own server only means changing that service's `DATABASE_URL`.

Trade-off: the database is a shared dependency. If PostgreSQL itself is down, all services lose their data
(each one stays alive and reports `503`). Failures of the **services** are fully isolated, and that is what the demo shows.

### Interaction between services

* **Synchronous (REST):**
  * `auth → user` creates the profile during registration; registration is rolled back if this fails;
  * `order → product` reserves stock (all-or-nothing) before an order is accepted and releases it on cancellation or failed payment.
* **Asynchronous (events through PostgreSQL):** a producer inserts a row into `bus.events`; each consumer reads
  new events in order and stores its position in `bus.consumer_offsets`. Events wait in the table while a
  consumer is down, and it catches up when it restarts.
  * `order.created → payment-service` charges the order → `payment.completed | payment.failed → order-service`
    (order becomes `paid` / `payment_failed` + stock released) **and** `notification-service`.
  * `order.cancelled → payment-service` (refund) and `notification-service`.
  * `user.registered → notification-service` (welcome message).

Internal endpoints (`/internal/*`) require the shared service token `X-Internal-Token`.

## Technology choices

| Area | Choice | Why |
|---|---|---|
| Language / framework | **Python 3.12 + FastAPI** | async I/O, pydantic validation, OpenAPI/Swagger generated automatically |
| Database | **PostgreSQL** (one database, schema + role per service) | ACID transactions for stock and payments; schemas and roles keep the services isolated |
| ORM / driver | **SQLAlchemy 2 (async) + asyncpg** | mature and async; the same models run on SQLite in tests |
| Messaging | **event table in PostgreSQL** (`bus.events` + consumer offsets) | durable, ordered, at-least-once delivery with no extra broker container; events survive restarts of any service |
| Sync communication | **REST + httpx** | simple, debuggable, documented with OpenAPI |
| Auth | **JWT (HS256)** | stateless: every service verifies the token itself, so logged-in users keep working even when auth-service is down |
| Deployment | **Docker Compose** | one command starts the 6 containers with health checks and automatic restart |
| UI | **one static HTML file** (vanilla JS) | no build step; talks to each service directly, so there is no single point of failure in front of them |
| Tests | **pytest + httpx ASGITransport** | the whole system runs in-process without Docker |

## Quick start

Requirements: Docker Desktop, a local PostgreSQL (tested with 16 and 18), Windows PowerShell.

```powershell
cd lab2
# 1. once: create the database "shophub" in the local PostgreSQL (asks for the postgres password)
powershell -ExecutionPolicy Bypass -File scripts\setup-database.ps1
# 2. start the 6 microservices
docker compose up -d --build
docker compose ps            # 6 containers, all "healthy"
# 3. open the UI
start frontend\index.html
```

If the UI cannot reach the services when opened as a file, serve it over HTTP instead:
`python -m http.server 5500 --directory frontend`, then open http://localhost:5500.

| URL | What |
|---|---|
| `frontend/index.html` | the shop + control room (main demo) |
| http://localhost:8001/docs … http://localhost:8006/docs | Swagger UI of each microservice |

Default administrator: `admin@example.com` / `Admin12345!`. The catalog is seeded with 16 demo products (fictional brands).
A PostgreSQL that is not on `localhost:5432` can be selected with `DB_HOST` / `DB_PORT`, for example
`$env:DB_PORT=5433; docker compose up -d`.

## Fault isolation demo (manual)

The shop page shows a short notice only in the part that depends on the missing service
("Каталог временно не обновляется", "Статус оплаты временно не обновляется", …) and keeps everything else working.
The footer shows the live state of the 6 services.

```powershell
# 1. switch one service off / on
docker compose stop payment-service
docker compose start payment-service

# 2. hard kill (no graceful shutdown); Docker does not restart it because it was a manual command
docker kill notification-service
docker start notification-service

# 3. crash inside the container (main process ends); Docker restarts it automatically (restart: unless-stopped)
docker exec order-service python -c "import os, signal; os.kill(1, signal.SIGTERM)"
docker inspect -f "{{.RestartCount}}" order-service

# 4. redeploy only one service; the other containers are not touched
docker compose up -d --build --no-deps payment-service
```

| Down | Unavailable on the site | Still works |
|---|---|---|
| auth-service | login, registration | everything else; existing sessions stay valid |
| user-service | profile, registration | login, catalog, cart, orders, payments, notifications |
| product-service | catalog refresh, placing new orders | cart, existing orders, payments, notifications, profile |
| order-service | placing / viewing orders | catalog, search, cart (kept in the browser), notifications, profile |
| payment-service | payment status | everything else; new orders wait as `pending_payment` and get paid after restart |
| notification-service | notifications | everything else; missed events are processed after restart |

The step-by-step guide for the demo (Russian) is in [docs/DEMO_RU.md](docs/DEMO_RU.md).

## Validation

Input is checked twice: in the browser (field-level hints while typing) and on the server (so a direct API call
cannot bypass it). The server answers `422` with a Russian message per field:

```json
{"error": {"code": "validation_error", "message": "Проверьте введённые данные",
  "details": [{"field": "delivery.phone", "message": "Телефон должен содержать от 10 до 15 цифр, например +373 69 123 456"}]}}
```

| Field | Rule |
|---|---|
| email | valid address, max 255 |
| password | 8–128 characters, at least one letter and one digit, no leading/trailing spaces |
| name / recipient | 2–100 characters: letters, spaces, hyphen, apostrophe |
| phone | digits, spaces, `+ ( ) -`; 10–15 digits |
| address | 5–255 characters, must contain letters |
| comment | up to 500 characters |
| order items | 1–50 lines, quantity 1–100 and not more than in stock (409 otherwise) |
| product (admin) | name 2–120, price > 0 with max 2 decimals, stock ≥ 0, category `^[a-z_]+$` |

Rules: `libs/common/shopcommon/validation.py` (server) and the `RULES` object in `frontend/index.html` (browser).
Tests: `tests/unit/test_validation.py`.

## Main API endpoints

| Method | Service | Path | Auth | Description |
|---|---|---|---|---|
| POST | auth :8001 | `/auth/register` | public | register a customer (creates the profile in user-service) |
| POST | auth :8001 | `/auth/login` | public | get a JWT |
| GET | auth :8001 | `/auth/me` | user | identity from the token |
| GET / PATCH | user :8002 | `/users/me` | user | own profile |
| GET | user :8002 | `/users/{id}`, `/users` | self or admin / admin | profiles |
| GET | product :8003 | `/products?search=&category=` | public | catalog |
| GET | product :8003 | `/products/{id}` | public | product details |
| POST / PATCH / DELETE | product :8003 | `/products`, `/products/{id}` | admin | manage catalog |
| POST | order :8004 | `/orders` | user | place an order |
| GET | order :8004 | `/orders`, `/orders/{id}` | owner or admin | orders |
| POST | order :8004 | `/orders/{id}/cancel` | owner or admin | cancel (stock released, payment refunded) |
| GET | payment :8005 | `/payments`, `/payments/order/{order_id}` | owner or admin | payments |
| GET | notification :8006 | `/notifications` | user | own notifications |
| POST | notification :8006 | `/notifications/{id}/read` | owner | mark as read |
| GET | every service | `/health`, `/ready` | public | liveness / readiness (database, event bus) |

OpenAPI specs are exported to [docs/openapi/](docs/openapi/).

## Cross-cutting concerns

**Authentication / authorization.** auth-service issues JWTs (`sub`, `email`, `role`, `exp`, `iss`). Each service
verifies the token and applies its own rules: admins manage the catalog, and users see only their own orders,
payments and notifications (another user's order returns `404`). Internal endpoints need `X-Internal-Token`.

**Error handling.** One error format everywhere, never a stack trace:

```json
{"error": {"code": "insufficient_stock", "message": "Insufficient stock for ...", "request_id": "7c3e..."}}
```

`422 validation_error`, `404 not_found`, `401 unauthorized / invalid_token / token_expired`, `403 forbidden`,
`409 conflict / insufficient_stock`, `502 upstream_unavailable`, `504 upstream_timeout`, `503 database_error`,
`500 internal_error`. Outgoing calls have timeouts; connection errors are retried; failed steps are compensated
(stock is released, a registration is rolled back); event consumers are idempotent and retry failed events.

**Logging.** Structured JSON on stdout (`docker compose logs -f order-service`) with `timestamp`, `service`,
`level`, `request_id`, `message` and extra fields. The request id is passed on in HTTP headers **and inside
events**, so one purchase can be traced across order → payment → notification.

**Configuration.** Each service has a pydantic `Settings` class that reads environment variables (see
`services/<name>/.env.example`). Docker Compose sets them per container. Secrets come from the root `.env`.

**Health checks.** `GET /health` (process alive) and `GET /ready` (database and event bus reachable). Docker uses
`/health` for container health and restarts crashed containers.

## Tests

```powershell
pip install -r requirements-dev.txt
pytest                   # 72 unit + integration tests, no Docker or PostgreSQL needed
pytest -m e2e            # purchase flow against the running containers + PostgreSQL
```

* `tests/unit/` covers each service: business rules, validation, authorization, idempotency, timeouts,
  upstream failures, input validation and the mapping of DB connection errors to 503.
* `tests/integration/` runs all 6 services in-process. They call each other through `httpx.ASGITransport`
  and share an in-memory event bus. The tests cover purchase, failed payment, cancellation with refund,
  data isolation and CORS.
* `tests/e2e/` runs the purchase flow against the real containers and the PostgreSQL event bus.

## Project structure

```
lab2/
├── README.md
├── docker-compose.yml           # exactly 6 containers
├── .env.example
├── database/                    # SQL: database "shophub", 6 roles, 6 schemas, event bus tables
├── frontend/index.html          # shop + control room UI
├── libs/common/shopcommon/      # shared infrastructure: logging, errors, security, db, event bus, http client
├── services/
│   ├── auth-service/            # each: <pkg>/{main,api,service,models,schemas,config}.py, Dockerfile, .env.example
│   ├── user-service/
│   ├── product-service/
│   ├── order-service/
│   ├── payment-service/
│   └── notification-service/
├── scripts/
│   ├── setup-database.ps1       # create the database in the local PostgreSQL (once)
│   └── show-db.ps1              # print what is stored in every schema
├── tests/{unit,integration,e2e}/
└── docs/                        # architecture.md, DEMO_RU.md, openapi/*.json
```

## Known limitations

* The database is shared infrastructure. If PostgreSQL is down, every service answers `503` until it is back.
* Events are written right after the business transaction commits, not inside it. A full transactional outbox
  would close the small gap if the process crashes between the two steps.
* Schemas are created with `create_all`. A production system would use migrations (Alembic).
* The event bus polls every 0.5 s; `LISTEN/NOTIFY` could make delivery instant.
