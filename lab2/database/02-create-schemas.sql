-- Run as a superuser while connected to the "shophub" database. Safe to run several times.
--
--   schema          owner (login role)   tables (created by the service on startup)
--   auth            auth_svc             credentials
--   users           user_svc             profiles
--   products        product_svc          products
--   orders          order_svc            orders, order_items
--   payments        payment_svc          payments
--   notifications   notification_svc     notifications
--   bus             postgres             events, consumer_offsets, dead_letters  (event bus, shared)

REVOKE ALL ON DATABASE shophub FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $$
DECLARE
    pair text[];
BEGIN
    FOREACH pair SLICE 1 IN ARRAY ARRAY[
        ['auth', 'auth_svc'],
        ['users', 'user_svc'],
        ['products', 'product_svc'],
        ['orders', 'order_svc'],
        ['payments', 'payment_svc'],
        ['notifications', 'notification_svc']
    ] LOOP
        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I AUTHORIZATION %I', pair[1], pair[2]);
        EXECUTE format('GRANT CONNECT ON DATABASE shophub TO %I', pair[2]);
        -- tables created by the service land in its own schema
        EXECUTE format('ALTER ROLE %I IN DATABASE shophub SET search_path = %I', pair[2], pair[1]);
    END LOOP;
END $$;

-- ---------------------------------------------------------------- event bus
-- Asynchronous communication between services goes through these tables:
-- a producer INSERTs an event, every consumer reads new events in order and
-- remembers how far it got (consumer_offsets). Events stay in the table while
-- a consumer is down and are processed when it comes back.
CREATE SCHEMA IF NOT EXISTS bus;

CREATE TABLE IF NOT EXISTS bus.events (
    id          bigserial PRIMARY KEY,
    event_id    text        NOT NULL UNIQUE,
    event_type  text        NOT NULL,
    producer    text        NOT NULL,
    payload     jsonb       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS events_type_idx ON bus.events (event_type);

CREATE TABLE IF NOT EXISTS bus.consumer_offsets (
    consumer       text PRIMARY KEY,
    last_event_id  bigint      NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS bus.dead_letters (
    id          bigserial PRIMARY KEY,
    consumer    text        NOT NULL,
    event_id    bigint      NOT NULL,
    error       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['auth_svc', 'user_svc', 'product_svc', 'order_svc', 'payment_svc', 'notification_svc'] LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA bus TO %I', r);
        EXECUTE format('GRANT SELECT, INSERT ON bus.events TO %I', r);
        EXECUTE format('GRANT USAGE ON SEQUENCE bus.events_id_seq TO %I', r);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON bus.consumer_offsets TO %I', r);
        EXECUTE format('GRANT INSERT ON bus.dead_letters TO %I', r);
        EXECUTE format('GRANT USAGE ON SEQUENCE bus.dead_letters_id_seq TO %I', r);
    END LOOP;
END $$;
