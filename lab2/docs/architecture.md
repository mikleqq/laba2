# Architecture

## 1. Deployment

```
Docker (6 containers)                                   Host machine
┌───────────────────────────────────────────┐          ┌──────────────────────────────┐
│ auth-service          :8001 ──┐            │          │ PostgreSQL :5432             │
│ user-service          :8002 ──┤            │          │  database shophub            │
│ product-service       :8003 ──┤ host.docker│ ───────► │   schema auth          (auth_svc)
│ order-service         :8004 ──┤ .internal  │          │   schema users         (user_svc)
│ payment-service       :8005 ──┤            │          │   schema products      (product_svc)
│ notification-service  :8006 ──┘            │          │   schema orders        (order_svc)
└───────────────────────────────────────────┘          │   schema payments      (payment_svc)
            ▲ REST (ports 8001–8006)                    │   schema notifications (notification_svc)
            │                                           │   schema bus           (event bus)
   Browser: frontend/index.html                         └──────────────────────────────┘
```

* Each container runs one microservice and nothing else. `restart: unless-stopped` brings a crashed process back.
* Containers do not depend on each other at startup. Each one waits only for the database, retrying the connection.
* The UI calls every service directly, so there is no component in front of the services whose failure would stop everything.

## 2. Domain decomposition

| Context | Owns | Does *not* know about |
|---|---|---|
| Auth | credentials, roles, tokens | profiles, orders |
| User | profile data | passwords, orders |
| Product | catalog, stock levels | who bought what |
| Order | orders and their items (price snapshot) | payment details, product descriptions |
| Payment | payments, transactions, refunds | items, stock |
| Notification | messages sent to users | how orders/payments work |

Data from other contexts is referenced only by id (`order_items.product_id`) and never joined across schemas.
When an order needs to keep the past state of another context, it stores a snapshot (`product_name`, `unit_price`).

## 3. One database, isolated schemas

```sql
CREATE SCHEMA orders AUTHORIZATION order_svc;
ALTER ROLE order_svc IN DATABASE shophub SET search_path = orders;
```

* Every service connects with its own role. Tables it creates land in its own schema (`search_path`).
* A role has no privileges on other schemas: `order_svc` → `SELECT FROM payments.payments` → `permission denied`.
* All roles can only `INSERT`/`SELECT` events in `bus.events` and update their own position in `bus.consumer_offsets`.

Setup scripts: `database/01-create-database.sql` (roles + database) and `database/02-create-schemas.sql`
(schemas + bus tables). Both are idempotent and are run by `scripts/setup-database.ps1`.

## 4. Communication

### 4.1 Registration (synchronous + event)

```
Client ──POST /auth/register──► auth: INSERT credential (flush)
                                  ├─POST /internal/users──► user (REST, must succeed)
                                  ├─ COMMIT  (rolled back if user-service failed)
                                  └─ INSERT bus.events: user.registered ──► notification (welcome)
```

### 4.2 Purchase (saga: REST step + events)

```
Client ──POST /orders──► order ──POST /internal/stock/reserve──► product   (all-or-nothing, 409 if not enough)
                           │ INSERT order (pending_payment)
                           └─ event order.created ─────────────────► payment: charge
                                                                       └─ event payment.completed / payment.failed
                           order ◄─────────────────────────────────────────┤
                             paid | payment_failed + POST /internal/stock/release
                           notification ◄───────────────────────────────────┘
```

### 4.3 Cancellation
`POST /orders/{id}/cancel` → `cancelled`, stock released (REST), `order.cancelled` → payment-service refunds
(`payment.refunded`). If the payment has not happened yet, a `cancelled` marker prevents a late charge.

## 5. Event bus on PostgreSQL

```
bus.events(id bigserial, event_id, event_type, producer, payload jsonb, created_at)
bus.consumer_offsets(consumer, last_event_id)
bus.dead_letters(consumer, event_id, error)
```

* **Publish:** `INSERT INTO bus.events`. Inserts are serialized with an advisory lock, so ids become visible in
  order and a consumer never skips an event.
* **Consume:** every 0.5 s a consumer reads `WHERE id > last_event_id ORDER BY id`, runs its handler for the
  event types it subscribed to (`order.*`, `payment.completed`, …) and advances its offset.
* **Failures:** if a handler fails, the same event is retried every 3 s. After 40 attempts it is written to
  `bus.dead_letters` and skipped. If the consumer's container is down, its offset does not move, and it continues
  from the same place after the restart. **No event is lost while a service is down.**
* **Idempotency:** payment has `UNIQUE(order_id)`, notification has `UNIQUE(event_id)`, and an order leaves
  `pending_payment` only once.

| Event | Producer | Consumers |
|---|---|---|
| `user.registered` | auth | notification |
| `order.created` | order | payment, notification |
| `order.cancelled` | order | payment, notification |
| `payment.completed` / `payment.failed` | payment | order, notification |
| `payment.refunded` | payment | notification |
| `product.low_stock` | product | notification |

## 6. Fault isolation

| Mechanism | Effect |
|---|---|
| 1 service = 1 container, no startup dependencies | a service can be stopped, restarted or redeployed alone |
| `restart: unless-stopped` + `/health` health check | a crashed process is restarted by Docker automatically |
| timeouts + retries on REST calls, clean 502/503/504 | a dead dependency fails fast, nothing hangs or cascades |
| events stored in the database | asynchronous work waits for a stopped service and is not lost |
| JWT verified by every service | logged-in users keep working when auth-service is down |
| UI calls each service directly | the UI only greys out the part that belongs to the failed service |
| `POST /chaos/crash` (demo flag) | lets you show a real crash (exit code 1) on demand |

## 7. Service internals

```
<pkg>/
├── main.py      create_app(): wiring (settings, DB, event bus, HTTP clients, subscriptions)
├── api.py       HTTP layer: routes, validation, auth dependencies, OpenAPI metadata
├── service.py   business logic
├── models.py    SQLAlchemy models (own metadata -> own tables)
├── schemas.py   pydantic request/response models
└── config.py    Settings (environment variables)
```

`create_app()` accepts an injected event bus and HTTP transports. The tests use this to run the real services
against each other in one process.
