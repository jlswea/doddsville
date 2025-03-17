import sys
import sqlite3
import time
import logging
from contextlib import closing
from datetime import datetime, timezone

from index import request

logger = logging.getLogger(__name__)
logger.addHandler(logging.StreamHandler()) 


def sense_all(argv):
    logging.basicConfig(filename="parse.log", level=logging.DEBUG)

    '''
    Reading all companies urls from database.
    '''
    con = sqlite3.connect("data.db")
    with closing(con.cursor()) as c:
        coms = c.execute("SELECT id, name, url FROM com").fetchall()
        for com in coms:
            now = datetime.now(timezone.utc)
            logger.info(f"Scanning {com[1]} at {now}")

            html = request(com[2]).find("div", class_="VWDcomp WE032")
            
            if html is None:
                logger.info("No data found")
            else:
                logger.info("Save data")
                c.execute(f"insert into raw ( com, html, timestamp ) values ('{com[0]}', '{str(html)}', '{now}')")
                con.commit()

            time.sleep(1)


def sense(id, name, url, cursor):
    """
    Store raw html in the database.
    """

    
    # for df in dfs:
    #     name = df.columns[0]
    #     df.set_index(name, inplace=True)
    #     if name == "Bilanz":
    #         bilanz = df
    #     if name == "Gewinn- und Verlustrechnung":
    #         guv = df

    # dates = bilanz.columns
    # bilanz.astype("float64")
    # guv.astype("float64")

    # roce_data = dict()
    # for d in dates:
    #     ebit = guv.loc["Operatives Ergebnis", d]
    #     cap_emp = bilanz.loc["Summe Aktiva", d] \
    #             - bilanz.loc["Summe kurzfristiges Fremdkapital", d]
    #     roce = ebit / cap_emp
    #     roce_data[d] = roce

    # if __name__ == "__main__":
    #     print_calc(roce_data)
    # else:
    #     return roce_data
        

def print_calc(data):
    """
    print calculated output to terminal.
    """
    for d in data:
        print(d, ":", "%.3f" %data[d])


if __name__ == "__main__":
    sense_all(sys.argv[1:])

