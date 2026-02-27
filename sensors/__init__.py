"""Sensor registry and orchestrator for security data scraping."""

import importlib
import pkgutil
from pathlib import Path

from .base import (
    BaseSensor,
    Security,
    SecurityType,
    SensorResult,
    get_sensor_registry,
    register_sensor,
)


def discover_sensors() -> None:
    """Auto-discover and import all sensor modules in the sensors package."""
    package_dir = Path(__file__).parent

    for module_info in pkgutil.iter_modules([str(package_dir)]):
        if module_info.name not in ("base", "__init__"):
            importlib.import_module(f".{module_info.name}", package=__name__)


def list_sensors() -> list[dict]:
    """List all available sensors with their metadata.

    Returns:
        List of dicts with sensor info: name, description
    """
    registry = get_sensor_registry()
    return [
        {"name": name, "description": cls.description}
        for name, cls in registry.items()
    ]


def run_sensor(name: str, config: dict, cur) -> SensorResult:
    """Run a specific sensor by name.

    Args:
        name: Sensor name
        config: Sensor-specific configuration from sensors.yaml
        cur: Database cursor

    Returns:
        SensorResult

    Raises:
        ValueError: If sensor not found
    """
    registry = get_sensor_registry()
    if name not in registry:
        available = ", ".join(registry.keys())
        raise ValueError(f"Unknown sensor '{name}'. Available: {available}")

    sensor = registry[name]()
    return sensor.run(config, cur)


def run_all_sensors(config: dict, cur) -> list[SensorResult]:
    """Run all enabled sensors.

    Args:
        config: Full sensor configuration from sensors.yaml
        cur: Database cursor

    Returns:
        List of SensorResult objects
    """
    registry = get_sensor_registry()
    results = []

    for name, sensor_cls in registry.items():
        sensor_config = config.get(name, {})
        if not sensor_config.get("enabled", True):
            continue
        sensor = sensor_cls()
        results.append(sensor.run(sensor_config, cur))

    return results


# Auto-discover sensors on import
discover_sensors()


__all__ = [
    "BaseSensor",
    "Security",
    "SecurityType",
    "SensorResult",
    "register_sensor",
    "list_sensors",
    "run_sensor",
    "run_all_sensors",
]
