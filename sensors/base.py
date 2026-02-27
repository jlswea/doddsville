"""Base types and abstract sensor class for security data scraping."""

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger(__name__)


class SecurityType(Enum):
    """Type of financial security."""

    STOCK = "stock"
    ETF = "etf"
    FUND = "fund"


@dataclass
class Security:
    """A financial security scraped by a sensor."""

    isin: str
    name: str
    type: SecurityType
    url: str = ""
    wkn: str = ""
    ter: str = ""
    replication: str = ""
    distribution: str = ""


@dataclass
class SensorResult:
    """Result of running a sensor."""

    sensor_name: str
    securities: list[Security] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    stats: dict = field(default_factory=dict)


# Sensor registry
_sensor_registry: dict[str, type["BaseSensor"]] = {}


def register_sensor(cls: type["BaseSensor"]) -> type["BaseSensor"]:
    """Decorator to register a sensor class."""
    _sensor_registry[cls.name] = cls
    return cls


def get_sensor_registry() -> dict[str, type["BaseSensor"]]:
    """Get the sensor registry."""
    return _sensor_registry


class BaseSensor(ABC):
    """Base class for all sensors.

    Sensors implement scrape() to fetch security data from external sources.
    The base class provides upsert_securities() for DB persistence and
    run() as an orchestrator.
    """

    name: str = "base"
    description: str = ""

    @abstractmethod
    def scrape(self, config: dict) -> list[Security]:
        """Scrape securities from external source.

        This is the only method sensors must implement.

        Args:
            config: Sensor-specific configuration from sensors.yaml

        Returns:
            List of Security objects found
        """
        pass

    def upsert_securities(self, cur, securities: list[Security]) -> dict:
        """Upsert securities into the database using ISIN as unique key.

        Args:
            cur: Database cursor
            securities: List of Security objects to upsert

        Returns:
            Stats dict with counts and details of inserted, updated, unchanged
        """
        stats = {
            "inserted": 0,
            "updated": 0,
            "unchanged": 0,
            "inserted_items": [],
            "updated_items": [],
        }

        for sec in securities:
            cur.execute(
                "SELECT id, name, url, type FROM security WHERE isin = ?",
                (sec.isin,),
            )
            existing = cur.fetchone()

            if existing is None:
                cur.execute(
                    "INSERT INTO security (isin, name, url, type) VALUES (?, ?, ?, ?)",
                    (sec.isin, sec.name, sec.url, sec.type.value),
                )
                stats["inserted"] += 1
                stats["inserted_items"].append(
                    {"isin": sec.isin, "name": sec.name, "type": sec.type.value}
                )
            else:
                existing_id, existing_name, existing_url, existing_type = existing
                if (
                    existing_name != sec.name
                    or existing_url != sec.url
                    or existing_type != sec.type.value
                ):
                    changes = {}
                    if existing_name != sec.name:
                        changes["name"] = (existing_name, sec.name)
                    if existing_url != sec.url:
                        changes["url"] = (existing_url, sec.url)
                    if existing_type != sec.type.value:
                        changes["type"] = (existing_type, sec.type.value)

                    cur.execute(
                        "UPDATE security SET name = ?, url = ?, type = ? WHERE id = ?",
                        (sec.name, sec.url, sec.type.value, existing_id),
                    )
                    stats["updated"] += 1
                    stats["updated_items"].append(
                        {"isin": sec.isin, "name": sec.name, "changes": changes}
                    )
                else:
                    stats["unchanged"] += 1

        return stats

    def run(self, config: dict, cur) -> SensorResult:
        """Run the sensor: scrape + upsert.

        Args:
            config: Sensor-specific configuration from sensors.yaml
            cur: Database cursor

        Returns:
            SensorResult with securities, errors, and stats
        """
        result = SensorResult(sensor_name=self.name)

        try:
            securities = self.scrape(config)
            result.securities = securities
            result.stats = self.upsert_securities(cur, securities)
        except Exception as e:
            logger.exception(f"[{self.name}] Sensor failed")
            result.errors.append(str(e))

        return result
