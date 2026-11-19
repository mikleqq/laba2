-- Database-per-service: one PostgreSQL server (to keep the lab lightweight),
-- but every service gets its own database AND its own login role.
-- A service cannot connect to another service's database.

CREATE ROLE auth_svc LOGIN PASSWORD 'auth_pass';
CREATE ROLE user_svc LOGIN PASSWORD 'user_pass';
CREATE ROLE product_svc LOGIN PASSWORD 'product_pass';
CREATE ROLE order_svc LOGIN PASSWORD 'order_pass';
CREATE ROLE payment_svc LOGIN PASSWORD 'payment_pass';
CREATE ROLE notification_svc LOGIN PASSWORD 'notification_pass';

CREATE DATABASE auth_db OWNER auth_svc;
CREATE DATABASE user_db OWNER user_svc;
CREATE DATABASE product_db OWNER product_svc;
CREATE DATABASE order_db OWNER order_svc;
CREATE DATABASE payment_db OWNER payment_svc;
CREATE DATABASE notification_db OWNER notification_svc;

REVOKE CONNECT ON DATABASE auth_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE user_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE product_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE order_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE payment_db FROM PUBLIC;
REVOKE CONNECT ON DATABASE notification_db FROM PUBLIC;
