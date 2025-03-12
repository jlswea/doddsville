import sys
import sqlite3
import logging
import urllib.request
from urllib.error import URLError
from contextlib import closing

from bs4 import BeautifulSoup as bs

def main(argv):
    logging.basicConfig(filename="log_index_ard.txt", level=logging.DEBUG)

    # Reading indeces urls from database
    con = sqlite3.connect("data.db")
    cur = con.cursor()
    indeces = cur.execute("SELECT name, link FROM indeces").fetchall()

    for index in indeces:
        logging.info(f"Scanning {index[0]} ...")
        page = request(index[1])
        table = get_tables(page)
        companies = get_companies(table)
        
        # Inserting the data
        for isin, value in companies.items():
            with closing(con.cursor()) as c:
                count = c.execute(f"SELECT COUNT(*) FROM companies WHERE isin='{isin}'").fetchone()[0]
                # Isin already exists in database
                if count == 1:
                    duplicate = c.execute(f"SELECT * FROM companies WHERE isin='{isin}'").fetchone()
                    # Check for companies that are included in multiple indeces
                    if index[0] not in duplicate[3]:
                        indeces = duplicate[3] + ", " + index[0]
                        update = f"UPDATE companies SET index_id='{indeces}' WHERE isin='{isin}'"
                        cur.execute(update)
                        con.commit()
                        logging.info(f"Add index {index[0]} to {duplicate[1]}")
                    # Check for updated name
                    if value[0] != duplicate[1]:
                        update = f"UPDATE companies SET name='{value[0]}' WHERE isin='{isin}'"
                        cur.execute(update)
                        con.commit()
                        logging.info(
                            f"Name updated for isin {isin}: "
                            f"{duplicate[1]} --> {value[0]}"
                        )
                    # Check for updated link
                    if value[1] != duplicate[2]:
                        update = f"UPDATE companies SET link='{value[0]}' WHERE isin='{isin}'"
                        cur.execute(update)
                        con.commit()
                        logging.info(
                            f"URL updated for isin {isin}: "
                            f"{duplicate[2]} --> {value[1]}"
                        )
                elif count == 0:
                    insert = f"INSERT INTO companies VALUES ('{isin}', '{value[0]}', '{value[1]}', '{index[0]}')"
                    cur.execute(insert)
                    con.commit()
                else:
                    logging.warning(f"Isin {isin} has a count of {count} in table companies")
    
    cur.close()
    con.close()


def get_tables(soup):
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
    Requests a url of domain kurse.boerse.ard.de and returns its
    relevant content
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
            print("Error code: ", e.code)
            
    # server responded as expected; save and close response
    else:
        page = response.read()
        response.close()
        
    soup = bs(page, "lxml")
    return soup
    

def parse_table(table):
    """
    Gets all companies from an html table and returns their name
    and link to their financial information on boerse.ard.de
    """
    # Exclude table header
    trs = table.find_all("tr")[1:]
    
    company_dict = dict()
    for tr in trs:
        tds = tr.findAll("td")
        name = str(tds[0].string)
        isin = tds[7].string
        link = str(tr.get("onclick"))
        link_clean = link.split("'")[1].split("'")[0]
        company_dict[isin] = [name, link_clean]
        
    return(company_dict)


def get_companies(tables):
    """
    Gets all companies from a list of html tables and returns their name
    and link to their financial information on boerse.ard.de
    """

    company_dict = dict()
    for t in tables:
        next_dict = parse_table(t)
        company_dict.update(next_dict)
        
    return(company_dict)

    
if __name__ == "__main__":
    main(sys.argv[1:])






