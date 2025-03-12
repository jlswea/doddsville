import sys
import sqlite3
from contextlib import closing

import pandas as pd


def scrape_all(argv):
    #logging.basicConfig(filename="log_parse_ard.txt", level=logging.DEBUG)

    '''
    Reading all companies urls from database.
    Call the scrape_one() on each url.
    '''
    con = sqlite3.connect("data.db")
    with closing(con.cursor()) as c:
        # No DISTINCT needed since isin is checked for duplicates
        # while scanning in index_ard.py
        c.execute("SELECT isin, link FROM companies")
        for row in c:
            # TODO: Time this function and wait for some time to not DoS accidentally 
            scrape_one(row[0], row[1])


def scrape_one(isin, link):
    """
    Scrape fundamental data for the provided isin, link pair.
    Store this data in the fundamentals table in data.db.
    """
    nan = ["-"]
    dfs = pd.read_html(link, match = "Gewinn und Verlustrechnung", header=0, thousands=".", decimal=",", na_values=nan)

    print(dfs[0])
    return

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
    #scrape_all(sys.argv[1:])
    scrape_one("US98980G1022", r"https://www.tagesschau.de/wirtschaft/boersenkurse/us98980g1022-65162748/")

