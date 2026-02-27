"""Sensor for scraping ETF data from justetf.com."""

import json
import logging
import re

import requests

from .base import BaseSensor, Security, SecurityType, register_sensor

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


@register_sensor
class JustETFSensor(BaseSensor):
    """Scrapes ETF data from justetf.com overview pages.

    Extracts embedded JS variables containing ETF listings.
    """

    name = "justetf"
    description = "Scrape ETF listings from justetf.com"

    def scrape(self, config: dict) -> list[Security]:
        """Scrape ETF data from configured URLs.

        Config format in sensors.yaml:
            justetf:
              enabled: true
              urls:
                - https://www.justetf.com/de/etf-list-overview.html
        """
        urls = config.get("urls", [])
        if not urls:
            logger.warning("No URLs configured for justetf sensor")
            return []

        all_securities: dict[str, Security] = {}

        for url in urls:
            try:
                response = requests.get(
                    url,
                    headers={"User-Agent": USER_AGENT},
                    timeout=30,
                )
                response.raise_for_status()
                html = response.text

                # Extract embedded JSON arrays from JS variables
                # Pattern: var id10Etfs = [{...}, ...];
                pattern = r"var\s+\w+Etfs\s*=\s*(\[.*?\]);"
                matches = re.findall(pattern, html, re.DOTALL)

                for match in matches:
                    try:
                        etfs = json.loads(match)
                        for etf in etfs:
                            isin = etf.get("isin", "")
                            if not isin:
                                continue
                            name = etf.get("name", "")
                            profile_url = etf.get("url", "")
                            if profile_url and not profile_url.startswith("http"):
                                profile_url = f"https://www.justetf.com{profile_url}"

                            if isin not in all_securities:
                                all_securities[isin] = Security(
                                    isin=isin,
                                    name=name,
                                    type=SecurityType.ETF,
                                    url=profile_url,
                                    ter=etf.get("ter", ""),
                                    replication=etf.get("replication", ""),
                                    distribution=etf.get("distribution", ""),
                                )
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse JSON from {url}")

            except Exception as e:
                logger.error(f"Error fetching {url}: {e}")

        return list(all_securities.values())
