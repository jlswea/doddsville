import sqlite3

from formatting import BOLD, GREEN, RED, RESET


def handle_account(args, conn, cur):
    """Handle the 'account' command."""
    if args.account_action == "add":
        try:
            cur.execute("INSERT INTO account (name) VALUES (?)", (args.name,))
            conn.commit()
            print(f"{GREEN}Account '{args.name}' created.{RESET}")
        except sqlite3.IntegrityError:
            print(f"{RED}Account '{args.name}' already exists.{RESET}")

    elif args.account_action == "list":
        cur.execute("SELECT id, name FROM account ORDER BY name")
        accounts = cur.fetchall()
        if not accounts:
            print("No accounts found.")
        else:
            print(f"{BOLD}Accounts:{RESET}")
            for acc in accounts:
                print(f"  {acc[0]}: {acc[1]}")
