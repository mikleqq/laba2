"""Configuration management.

Every service has its own ``Settings`` class derived from
:class:`BaseServiceSettings`. Values are read from environment variables
(and an optional ``.env`` file), so the same image can be configured
differently per environment without code changes.
"""

from __future__ import annotations

from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class BaseServiceSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    service_name: str = "service"
    log_level: str = "INFO"

    # Persistence: each service points to its own database.
    database_url: str = "sqlite+aiosqlite:///:memory:"

    # Messaging: when empty an in-process event bus is used (tests/local runs).
    rabbitmq_url: Optional[str] = None
    event_exchange: str = "shop.events"

    # Security
    jwt_secret: str = "dev-secret-change-me"
    jwt_algorithm: str = "HS256"
    internal_token: str = "dev-internal-token-change-me"

    # Outgoing HTTP calls to other services
    http_timeout_seconds: float = 5.0

    # Startup: how long to wait for DB / broker to become available
    startup_retries: int = 30
    startup_retry_delay_seconds: float = 2.0
