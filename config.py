from pathlib import Path

import yaml

SENSORS_FILE = Path(__file__).parent / "sensors" / "sensors.yaml"
LOG_FILE = Path("sensors.log")
DEFAULT_DB = "data.db"


def load_sensor_config():
    """Load sensor configuration from sensors/sensors.yaml.

    Returns:
        dict: Sensor configuration, empty dict if file missing.
    """
    if SENSORS_FILE.exists():
        with open(SENSORS_FILE) as f:
            return yaml.safe_load(f) or {}
    return {}
