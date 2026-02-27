import os
from pathlib import Path

import yaml

CONFIG_FILE = Path("dv.conf")
SENSORS_FILE = Path(__file__).parent / "sensors" / "sensors.yaml"
LOG_FILE = Path("sensors.log")
DEFAULT_DB = "data.db"


def load_config():
    """Load configuration from dv.conf + environment variables.

    File-based config (dv.conf) stores non-secret settings like db path.
    Secrets (paperless_url, paperless_token) come from environment variables
    DV_PAPERLESS_URL and DV_PAPERLESS_TOKEN.
    """
    config = {"db": DEFAULT_DB}

    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    config[key.strip()] = value.strip()

    # Environment variables override file config
    if url := os.environ.get("DV_PAPERLESS_URL"):
        config["paperless_url"] = url
    if token := os.environ.get("DV_PAPERLESS_TOKEN"):
        config["paperless_token"] = token

    return config


def save_config(config):
    """Save non-secret configuration to dv.conf.

    Secrets (paperless_url, paperless_token) are skipped — those belong
    in environment variables (e.g. via direnv).
    """
    secret_keys = {"paperless_url", "paperless_token"}
    with open(CONFIG_FILE, "w") as f:
        for key, value in config.items():
            if key not in secret_keys:
                f.write(f"{key}={value}\n")


def load_sensor_config():
    """Load sensor configuration from sensors/sensors.yaml.

    Returns:
        dict: Sensor configuration, empty dict if file missing.
    """
    if SENSORS_FILE.exists():
        with open(SENSORS_FILE) as f:
            return yaml.safe_load(f) or {}
    return {}
