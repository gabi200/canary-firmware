"""Runtime configuration via environment variables (pydantic-settings)."""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CANARY_", env_file=".env", extra="ignore")

    # --- database ---
    # Postgres/Timescale in prod; SQLite for local/tests.
    database_url: str = "postgresql+asyncpg://canary:canary@localhost:5432/canary"

    # --- redis (cache + dedupe; optional in dev) ---
    redis_url: str = "redis://localhost:6379/0"
    use_redis: bool = False

    # --- MQTT broker (EMQX) ---
    mqtt_enabled: bool = True
    mqtt_host: str = "localhost"
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_topic_prefix: str = "canary/v1"

    # --- auth ---
    jwt_secret: str = "dev-only-change-me"
    jwt_algorithm: str = "HS256"
    jwt_ttl_seconds: int = 8 * 3600

    # --- detection tuning ---
    clear_hold_samples: int = 3  # consecutive below-clear samples before resolution/false_alarm
    escalation_persist_seconds: int = 120

    # --- bootstrap ---
    auto_create_schema: bool = True
    auto_seed: bool = True

    # --- misc ---
    cors_origins: list[str] = ["*"]

    @property
    def is_postgres(self) -> bool:
        return self.database_url.startswith("postgresql")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
