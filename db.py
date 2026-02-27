from formatting import BOLD, GREEN, RED, RESET


def get_or_prompt_account(cur, account_name=None):
    """Get account by name or prompt user to select one."""
    if account_name:
        cur.execute("SELECT id, name FROM account WHERE name = ?", (account_name,))
        result = cur.fetchone()
        if result:
            return result
        cur.execute(
            "SELECT id, name FROM account WHERE name LIKE ?", (f"%{account_name}%",)
        )
        results = cur.fetchall()
    else:
        cur.execute("SELECT id, name FROM account")
        results = cur.fetchall()

    if not results:
        print(f"{RED}No accounts found. Create one with: dv account add <name>{RESET}")
        return None

    if len(results) == 1:
        return results[0]

    print("Select an account:")
    for i, acc in enumerate(results):
        print(f"  {BOLD}{GREEN}{i + 1}{RESET}: {acc[1]} (ID: {acc[0]})")

    try:
        option = int(input("Account number: "))
        return results[option - 1]
    except (ValueError, IndexError):
        print(f"{RED}Invalid selection.{RESET}")
        return None


def get_or_prompt_security(cur, security_identifier):
    """Get security by name or prompt user to select one if multiple matches."""
    cur.execute(
        "SELECT id, isin, name FROM security WHERE name LIKE ? OR isin LIKE ?",
        (
            f"%{security_identifier}%",
            f"%{security_identifier}%",
        ),
    )
    results = cur.fetchall()

    if not results:
        print(f"{RED}No security found matching '{security_identifier}'.{RESET}")
        return None

    if len(results) == 1:
        return results[0]

    print(f"Multiple securities match '{security_identifier}':")
    for i, sec in enumerate(results):
        print(f"  {BOLD}{GREEN}{i + 1}{RESET}: {sec[2]} (ISIN: {sec[1]}, ID: {sec[0]})")

    try:
        option = int(input("Which one? "))
        return results[option - 1]
    except (ValueError, IndexError):
        print(f"{RED}Invalid selection.{RESET}")
        return None


def get_current_holdings(cur, security_id: int, account_id: int | None = None) -> int:
    """Get current holdings (shares owned) for a security.

    Args:
        cur: Database cursor
        security_id: Security ID to check holdings for
        account_id: Optional account ID to filter by (None = all accounts)

    Returns:
        Net shares owned (buys - sells)
    """
    if account_id:
        cur.execute(
            """
            SELECT COALESCE(
                SUM(CASE WHEN type = 'buy' THEN quantity ELSE -quantity END),
                0
            )
            FROM "transaction"
            WHERE security = ? AND account = ? AND type IN ('buy', 'sell')
            """,
            (security_id, account_id),
        )
    else:
        cur.execute(
            """
            SELECT COALESCE(
                SUM(CASE WHEN type = 'buy' THEN quantity ELSE -quantity END),
                0
            )
            FROM "transaction"
            WHERE security = ? AND type IN ('buy', 'sell')
            """,
            (security_id,),
        )
    return cur.fetchone()[0]
