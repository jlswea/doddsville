"""Sensor for scraping stock index compositions from tagesschau.de."""

import logging

import requests
from bs4 import BeautifulSoup

from .base import BaseSensor, Security, SecurityType, register_sensor

logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def _request(url: str, data: str | None = None) -> BeautifulSoup:
    """Send HTTP request and return parsed HTML."""
    headers = {"User-Agent": USER_AGENT}
    if data:
        headers["X-Requested-With"] = "XMLHttpRequest"
        url = url + "?" + data

    response = requests.get(url, headers=headers, timeout=30)
    response.raise_for_status()
    return BeautifulSoup(response.content, "lxml")


def _get_multipart_table(soup: BeautifulSoup) -> list:
    """Handle paginated tables on tagesschau.de."""
    composition = soup.find("div", id="USFzusammensetzung")
    if not composition:
        return []

    content_list = [composition]
    pagination = composition.find("div", class_="pagination")

    if pagination:
        offset = 0
        next_li = pagination.find("li", class_="next")
        if not next_li:
            return [c.find("table") for c in content_list if c.find("table")]

        onclick = next_li.get("onclick", "")
        if not onclick or "{" not in onclick:
            return [c.find("table") for c in content_list if c.find("table")]

        json_req = onclick.split("{")[1].split("}")[0]
        req = json_req.split(",")
        par = req[0].split(":")[1].split("'")[1].split("'")[0]
        filename = req[1].split(":")[1].split("'")[1].split("'")[0]
        root_dir = req[2].split("':'")[1].split("'")[0]

        last_equal = par.rfind("=")
        no_offset_par = par[: last_equal + 1]

        while True:
            offset += 1
            par = no_offset_par + str(offset * 50)
            url = root_dir + filename
            extra_soup = _request(url, par)
            content_list.append(extra_soup)

            if extra_soup.find("li", class_="next disabled"):
                break

    return [c.find("table") for c in content_list if c.find("table")]


def _parse_table(table) -> dict[str, tuple[str, str]]:
    """Parse securities from an HTML table."""
    trs = table.find_all("tr")[1:]  # Skip header
    result = {}

    for tr in trs:
        tds = tr.find_all("td")
        if len(tds) < 8:
            continue
        isin = tds[7].string
        if not isin:
            continue
        name = str(tds[0].string or "")
        onclick = str(tr.get("onclick", ""))
        url = onclick.split("'")[1].split("'")[0] if "'" in onclick else ""
        result[isin] = (name, url)

    return result


@register_sensor
class TagesschauSensor(BaseSensor):
    """Scrapes stock index compositions from tagesschau.de.

    Reads index URLs from sensors.yaml configuration.
    """

    name = "tagesschau"
    description = "Scrape stock index compositions (DAX, MDAX, etc.) from tagesschau.de"

    def scrape(self, config: dict) -> list[Security]:
        """Scrape all configured indices.

        Config format in sensors.yaml:
            tagesschau:
              enabled: true
              indices:
                - name: DAX
                  url: https://www.tagesschau.de/wirtschaft/boersenkurse/dax-index-846900/
        """
        indices = config.get("indices", [])
        if not indices:
            logger.warning("No indices configured for tagesschau sensor")
            return []

        all_securities: dict[str, Security] = {}

        for index_info in indices:
            index_name = index_info.get("name", "Unknown")
            index_url = index_info.get("url", "")
            if not index_url:
                continue

            logger.info(f"Scanning {index_name}...")

            try:
                page = _request(index_url)
                tables = _get_multipart_table(page)

                for table in tables:
                    if not table:
                        continue
                    for isin, (name, url) in _parse_table(table).items():
                        if isin not in all_securities:
                            all_securities[isin] = Security(
                                isin=isin,
                                name=name,
                                type=SecurityType.STOCK,
                                url=url,
                            )
                        elif name and not all_securities[isin].name:
                            all_securities[isin].name = name

            except Exception as e:
                logger.error(f"Error scanning {index_name}: {e}")

        return list(all_securities.values())
