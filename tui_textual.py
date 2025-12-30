"""
Doddsville TUI - Python/Textual Prototype

A terminal user interface for managing stock transactions.
Run with: python tui_textual.py
Requires: pip install textual
"""

import sqlite3
from datetime import datetime
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    Static,
    Button,
    Select,
)
from textual.validation import Number


class TransactionModal(ModalScreen[dict | None]):
    """Modal dialog for adding a new transaction."""

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
    ]

    CSS = """
    TransactionModal {
        align: center middle;
    }

    #modal-container {
        width: 60;
        height: auto;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #modal-title {
        text-align: center;
        text-style: bold;
        margin-bottom: 1;
        color: $primary;
    }

    .form-row {
        height: 3;
        margin-bottom: 1;
    }

    .form-label {
        width: 12;
        padding-top: 1;
    }

    .form-input {
        width: 1fr;
    }

    #button-row {
        margin-top: 1;
        align: center middle;
    }

    Button {
        margin: 0 1;
    }
    """

    def __init__(self, transaction_type: str = "buy"):
        super().__init__()
        self.transaction_type = transaction_type

    def compose(self) -> ComposeResult:
        with Container(id="modal-container"):
            yield Label(f"Add {self.transaction_type.upper()} Transaction", id="modal-title")

            with Horizontal(classes="form-row"):
                yield Label("Stock:", classes="form-label")
                yield Input(placeholder="Search stock name...", id="stock-input", classes="form-input")

            with Horizontal(classes="form-row"):
                yield Label("Quantity:", classes="form-label")
                yield Input(placeholder="100", id="quantity-input", classes="form-input", validators=[Number()])

            with Horizontal(classes="form-row"):
                yield Label("Price:", classes="form-label")
                yield Input(placeholder="12.34", id="price-input", classes="form-input")

            with Horizontal(classes="form-row"):
                yield Label("Date:", classes="form-label")
                yield Input(placeholder="DD.MM.YYYY", value=datetime.now().strftime("%d.%m.%Y"), id="date-input", classes="form-input")

            with Horizontal(classes="form-row"):
                yield Label("Fees:", classes="form-label")
                yield Input(placeholder="0.00", value="0.00", id="cost-input", classes="form-input")

            with Horizontal(id="button-row"):
                yield Button("Cancel", variant="default", id="cancel-btn")
                yield Button("Add", variant="primary", id="add-btn")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel-btn":
            self.dismiss(None)
        elif event.button.id == "add-btn":
            self.dismiss({
                "type": self.transaction_type,
                "stock": self.query_one("#stock-input", Input).value,
                "quantity": self.query_one("#quantity-input", Input).value,
                "price": self.query_one("#price-input", Input).value,
                "date": self.query_one("#date-input", Input).value,
                "cost": self.query_one("#cost-input", Input).value,
            })

    def action_cancel(self) -> None:
        self.dismiss(None)


class StockSearchModal(ModalScreen[tuple | None]):
    """Modal for searching and selecting stocks."""

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
    ]

    CSS = """
    StockSearchModal {
        align: center middle;
    }

    #search-container {
        width: 80;
        height: 20;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }

    #search-title {
        text-align: center;
        text-style: bold;
        color: $primary;
    }

    #search-input {
        margin: 1 0;
    }

    #results-table {
        height: 1fr;
    }
    """

    def __init__(self, db_path: str = "data.db"):
        super().__init__()
        self.db_path = db_path

    def compose(self) -> ComposeResult:
        with Container(id="search-container"):
            yield Label("Search Stocks", id="search-title")
            yield Input(placeholder="Type to search...", id="search-input")
            yield DataTable(id="results-table", cursor_type="row")

    def on_mount(self) -> None:
        table = self.query_one("#results-table", DataTable)
        table.add_columns("ID", "ISIN", "Name")

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "search-input" and len(event.value) >= 2:
            self._search_stocks(event.value)

    def _search_stocks(self, query: str) -> None:
        table = self.query_one("#results-table", DataTable)
        table.clear()

        try:
            conn = sqlite3.connect(self.db_path)
            cur = conn.cursor()
            cur.execute(
                "SELECT id, isin, name FROM company WHERE name LIKE ? LIMIT 20",
                (f"%{query}%",)
            )
            results = cur.fetchall()
            conn.close()

            for row in results:
                table.add_row(*row, key=str(row[0]))
        except sqlite3.Error:
            pass

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        table = self.query_one("#results-table", DataTable)
        row_key = event.row_key
        if row_key:
            row_data = table.get_row(row_key)
            self.dismiss((row_data[0], row_data[1], row_data[2]))

    def action_cancel(self) -> None:
        self.dismiss(None)


class PortfolioSummary(Static):
    """Widget showing portfolio summary."""

    def compose(self) -> ComposeResult:
        yield Static("Portfolio Summary", classes="summary-title")
        yield Static("Total Value: --", id="total-value")
        yield Static("Positions: --", id="positions")
        yield Static("Today: --", id="today-change")


class DoddsTUI(App):
    """Doddsville Terminal User Interface."""

    TITLE = "Doddsville"
    SUB_TITLE = "Stock Portfolio Manager"

    CSS = """
    Screen {
        background: $background;
    }

    #main-container {
        height: 1fr;
    }

    #sidebar {
        width: 30;
        border-right: solid $primary;
        padding: 1;
    }

    .summary-title {
        text-style: bold;
        color: $primary;
        margin-bottom: 1;
    }

    #content {
        width: 1fr;
        padding: 1;
    }

    #transactions-table {
        height: 1fr;
    }

    .status-bar {
        dock: bottom;
        height: 1;
        background: $primary;
        color: $background;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("b", "add_buy", "Buy"),
        Binding("s", "add_sell", "Sell"),
        Binding("d", "add_dividend", "Dividend"),
        Binding("r", "refresh", "Refresh"),
        Binding("/", "search", "Search"),
    ]

    def __init__(self, db_path: str = "data.db"):
        super().__init__()
        self.db_path = db_path

    def compose(self) -> ComposeResult:
        yield Header()

        with Horizontal(id="main-container"):
            with Vertical(id="sidebar"):
                yield PortfolioSummary()

            with Vertical(id="content"):
                yield DataTable(id="transactions-table", cursor_type="row")

        yield Footer()

    def on_mount(self) -> None:
        self._setup_table()
        self._load_transactions()

    def _setup_table(self) -> None:
        table = self.query_one("#transactions-table", DataTable)
        table.add_columns("ID", "Date", "Type", "Stock", "Qty", "Price", "Total", "Fees")

    def _load_transactions(self) -> None:
        table = self.query_one("#transactions-table", DataTable)
        table.clear()

        try:
            conn = sqlite3.connect(self.db_path)
            cur = conn.cursor()

            # Try the new schema first, fall back to old
            try:
                cur.execute("""
                    SELECT
                        t.id,
                        t.date,
                        t.type,
                        COALESCE(c.name, '-'),
                        COALESCE(t.quantity, 0),
                        COALESCE(t.unit_value, 0),
                        COALESCE(t.total_value, 0),
                        COALESCE(t.cost, 0)
                    FROM "transaction" t
                    LEFT JOIN company c ON t.company = c.id
                    ORDER BY t.date DESC
                    LIMIT 100
                """)
            except sqlite3.Error:
                # Fall back to trans table if exists
                cur.execute("""
                    SELECT
                        id,
                        date,
                        type,
                        com,
                        amount,
                        price,
                        (amount * price),
                        cost
                    FROM trans
                    ORDER BY date DESC
                    LIMIT 100
                """)

            rows = cur.fetchall()
            conn.close()

            for row in rows:
                # Format currency values from cents
                price = f"{row[5]/100:.2f}" if row[5] else "-"
                total = f"{row[6]/100:.2f}" if row[6] else "-"
                fees = f"{row[7]/100:.2f}" if row[7] else "-"

                type_display = self._format_type(row[2])

                table.add_row(
                    str(row[0]),
                    str(row[1]),
                    type_display,
                    str(row[3])[:20],
                    str(row[4]),
                    price,
                    total,
                    fees,
                    key=str(row[0])
                )

        except sqlite3.Error as e:
            self.notify(f"Database error: {e}", severity="error")

    def _format_type(self, tx_type: str) -> str:
        colors = {
            "buy": "[green]BUY[/]",
            "sell": "[red]SELL[/]",
            "dividend": "[cyan]DIV[/]",
            "interest": "[yellow]INT[/]",
            "deposit": "[blue]DEP[/]",
            "withdrawal": "[magenta]WDR[/]",
            "transfer": "[white]TRF[/]",
        }
        return colors.get(tx_type, tx_type)

    def action_add_buy(self) -> None:
        self.push_screen(TransactionModal("buy"), self._handle_transaction)

    def action_add_sell(self) -> None:
        self.push_screen(TransactionModal("sell"), self._handle_transaction)

    def action_add_dividend(self) -> None:
        self.push_screen(TransactionModal("dividend"), self._handle_transaction)

    def action_search(self) -> None:
        self.push_screen(StockSearchModal(self.db_path))

    def action_refresh(self) -> None:
        self._load_transactions()
        self.notify("Refreshed", severity="information")

    def _handle_transaction(self, result: dict | None) -> None:
        if result is None:
            return

        # Here you would insert into the database
        self.notify(
            f"Added {result['type']}: {result['quantity']} x {result['stock']} @ {result['price']}",
            severity="information"
        )
        self._load_transactions()


def main():
    app = DoddsTUI()
    app.run()


if __name__ == "__main__":
    main()
