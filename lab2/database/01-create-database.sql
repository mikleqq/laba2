-- ShopHub: ONE PostgreSQL database for all 6 microservices.
-- Run as a superuser (postgres) while connected to any database, e.g. "postgres".
-- Safe to run several times.
--
-- Isolation inside the single database:
--   every microservice has its own LOGIN ROLE and its own SCHEMA,
--   the role owns only its schema and cannot read the others.

DO $$
DECLARE
    svc text;
BEGIN
    FOREACH svc IN ARRAY ARRAY['auth', 'user', 'product', 'order', 'payment', 'notification'] LOOP
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = svc || '_svc') THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', svc || '_svc', svc || '_pass');
        END IF;
    END LOOP;
END $$;

SELECT 'CREATE DATABASE shophub'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'shophub')\gexec
