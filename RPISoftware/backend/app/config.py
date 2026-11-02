"""Runtime configuration via environment variables (pydantic-settings)."""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CANARY_", env_file=".env", extra="ignore")

    # --- database ---
    # Postgres/Timescale in prod; SQLite for local/tests.
    database_url: str = "postgresql+asyncpg://canary:canary@localhost:5432/canary"

    # --- MQTT broker (Mosquitto) ---
    mqtt_enabled: bool = True
    mqtt_host: str = "localhost"
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_topic_prefix: str = "canary/v1"  # legacy canary.telemetry.v1 topics
    # One filter covers the hardware `<base>/status|availability` topics and the legacy ones.
    mqtt_subscribe: str = "#"

    # --- hardware nodes (docs/HARDWARE.md) ---
    default_building_id: str = "bld_007"  # where auto-registered nodes land
    default_zone_id: str = "zone_hallway"

    # --- retention: prune raw snapshots, readings, occupancy older than this (<= 0 disables) ---
    retention_days: int = 14

    # --- auth ---
    jwt_secret: str = "dev-only-change-me"
    jwt_algorithm: str = "HS256"
    jwt_ttl_seconds: int = 8 * 3600
    # Fernet key for care profiles (health data, encrypted at rest); written to .env by
    # scripts/pi_setup.sh. Empty -> the care-profile endpoints answer 503, the rest works.
    care_key: str = ""

    # --- external escalation webhook (ARC / 112 partner, docs/HARDWARE.md section 4) ---
    escalation_url: str = ""  # empty: no webhook (notification rows only, as before)
    escalation_secret: str = ""  # HMAC-SHA256 key; written to .env by scripts/pi_setup.sh

    # --- detection tuning ---
    clear_hold_samples: int = 3  # consecutive below-clear samples before resolution/false_alarm
    escalation_persist_seconds: int = 120

    # --- cluster: one Pi ("single") or three redundant Pis ("triple"), RUNME.md section 3 ---
    cluster_mode: Literal["single", "triple"] = "single"
    node_name: str = "hub"  # triple: this Pi's home role, processing | web | ai
    processing_ip: str = ""  # triple: the three Pis' LAN addresses (the same on every Pi)
    web_ip: str = ""
    ai_ip: str = ""
    vip: str = ""  # triple: the floating address of the hub (sensors, dashboard, app)
    cluster_secret: str = ""  # triple: node-to-node API key, written by scripts/pi_setup.sh --cluster
    vrrp_state_file: str = "/run/canary/vrrp_state"  # keepalived writes MASTER / BACKUP / FAULT here
    # --- software updates: canary-updater on every Pi's host (cluster/updater, RUNME.md) ---
    updater_key: str = ""  # CANARY_UPDATER_KEY, written by scripts/pi_setup.sh; empty: updates unavailable
    updater_port: int = 8010

    # --- AI accelerator: Raspberry Pi AI HAT+ 2 serving an LLM through hailo-ollama ---
    llm_url: str = ""  # e.g. http://host.docker.internal:11434; empty: incident briefs use a template
    llm_model: str = "qwen2.5-instruct:1.5b"

    # --- ESPectre Wi-Fi motion boards (stock firmware, deployed separately; docs/ESPECTRE.md) ---
    espectre_topic_prefix: str = "espectre/v1/devices"  # ESPectre's default MQTT base
    # device_id (16 hex chars) -> Zone id, e.g. {"3cf79180d3a0aca4": "zone_kitchen"}; unmapped
    # boards are listed as such and their motion is not stored
    espectre_zones: dict[str, str] = {}
    espectre_store_interval_s: float = 5.0  # an unchanged motion state is stored at most this often

    # --- water-leak impact map: which units sit below / share a riser (docs/WATER_TOPOLOGY.md) ---
    water_topology_file: str = ""  # JSON file; empty: the impact map says "topology not configured"

    # --- bootstrap ---
    auto_create_schema: bool = True
    auto_seed: bool = True

    # --- misc ---
    cors_origins: list[str] = ["*"]
    public_url: str = "http://localhost"  # base of shareable links, e.g. household invites (/join/<code>)

    @property
    def is_postgres(self) -> bool:
        return self.database_url.startswith("postgresql")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
