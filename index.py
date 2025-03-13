import sys
import sqlite3
import logging
import urllib.request
from urllib.error import URLError
from contextlib import closing

from bs4 import BeautifulSoup as bs

def main(argv):
    logging.basicConfig(filename="index.log", level=logging.DEBUG)

    con = sqlite3.connect("data.db")
    cur = con.cursor()

    for idx in cur.execute("SELECT id, name, url FROM idx").fetchall():
        logging.info(f"Scanning {idx[1]} ...")
        page: BeautifulSoup = request(idx[2])
        table_parts: [str] = get_multipart_table(page)
        
        # Inserting the data
        for isin, value in get_elements(table_parts).items():
            with closing(con.cursor()) as c:
                count = c.execute(f"SELECT COUNT(*) FROM com WHERE isin='{isin}'").fetchone()[0]
                # Isin already exists in database
                if count == 1:
                    dup = c.execute(f"SELECT * FROM com WHERE isin='{isin}'").fetchone()
                    # Check for companies that are included in multiple indeces
                    if idx[0] not in dup[4]:
                        index_list = dup[4] + ", " + idx[0]
                        cur.execute(f"UPDATE com SET idx='{index_list}' WHERE isin='{isin}'")
                        con.commit()
                        logging.info(f"Add index {idx[1]} to {dup[2]}")
                    # Check for updated name
                    if value[0] != dup[2]:
                        update = f"UPDATE com SET name='{value[0]}' WHERE isin='{isin}'"
                        cur.execute(update)
                        con.commit()
                        logging.info(
                            f"Name updated for isin {isin}: "
                            f"{dup[2]} --> {value[0]}"
                        )
                    # Check for updated url
                    if value[1] != dup[3]:
                        update = f"UPDATE com SET url='{value[1]}' WHERE isin='{isin}'"
                        cur.execute(update)
                        con.commit()
                        logging.info(
                            f"URL updated for isin {isin}: "
                            f"{dup[3]} --> {value[1]}"
                        )
                elif count == 0:
                    insert = f"INSERT INTO com(isin, name, url, idx) VALUES ('{isin}', '{value[0]}', '{value[1]}', '{idx[0]}')"
                    cur.execute(insert)
                    con.commit()
                    logging.info(f"Add '{value[0]}'")
    
    cur.close()
    con.close()


def get_multipart_table(soup):
    """
    Checks for multipage content in soup. Returns a list of all 
    associated URL's as a BS soup object
    """ 
    content_list = [soup.find("div", id="USFzusammensetzung")]
    pagination = content_list[0].find("div", class_="pagination")

    if pagination:
        offset = 0

        # Get ajax parameters
        onclick = pagination.find("li", class_="next").get("onclick")
        json_req = onclick.split("{")[1].split("}")[0]
        req = json_req.split(",")
        par = req[0].split(":")[1].split("'")[1].split("'")[0]
        filename = req[1].split(":")[1].split("'")[1].split("'")[0]
        rootDir = req[2].split("':'")[1].split("'")[0]

        # Split off offset parameter
        last_equal = par.rfind("=")
        no_offset_par = par[:last_equal+1]

        while True:
            # Compute offset
            offset += 1
            par = no_offset_par + str(offset * 50)
            
            # Make the request
            url = rootDir + filename
            data = par
            extra_soup = request(url, data)
            content_list.append(extra_soup)
            
            # Cancellation condition
            if extra_soup.find("li", class_="next disabled"):
                break

    return [c.find("table") for c in content_list]


def request(url, data=None):
    """
    Sends HTTP request
    """

    user_agent = """Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_3) 
    AppleWebKit/537.75.14 (KHTML, like Gecko) Version/7.0.3 Safari/7046A194A"""
    header = {"User-Agent": user_agent}

    if data:
        header["X-Requested-With"] = "XMLHttpRequest"
        url = url + "?" + data
        
    req = urllib.request.Request(url = url, headers = header)
    
    try:
        response = urllib.request.urlopen(req)
    except URLError as e:
        if hasattr(e, "reason"):
            print("unable to serve request: ", e.reason)
        if hasattr(e, "code"):
            print("error code: ", e.code)
            
    # server responded as expected; save and close response
    else:
        page = response.read()
        response.close()
        
    soup = bs(page, "lxml")
    return soup
    

def parse(table):
    """
    Reads com entity from given html table
    """

    trs = table.find_all("tr")[1:] # Exclude table header
    
    res = dict()
    for tr in trs:
        tds = tr.findAll("td")
        isin = tds[7].string
        name = str(tds[0].string)
        url = str(tr.get("onclick")).split("'")[1].split("'")[0]
        res[isin] = [name, url]
        
    return res


def get_elements(parts):
    """
    Parses all elements from a list of html tables
    """

    res = dict()
    for p in parts:
        res.update(parse(p))
        
    return res

    
if __name__ == "__main__":
    main(sys.argv[1:])






