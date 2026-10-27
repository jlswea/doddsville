# Ledger model: double-entry for a balance sheet and tax reporting

Status: proposal.

## Why

Today a transaction is one row with a fixed `type` (buy, sell, dividend, interest,
deposit, withdrawal, transfer). Everything else has nowhere to go: tax refunds,
withheld Kapitalertragsteuer/Soli/Kirchensteuer, creditable Quellensteuer, the
Vorabpauschale, fees on their own. `dv import` lists such bookings as "not
importable". The goal is a balance sheet and the figures for the tax return
(Anlage KAP), so the model has to represent every booking, not a fixed menu.

Two further gaps:

- Realized gains use the average cost per security. German tax law prescribes
  FIFO per securities account (§ 20 Abs. 4 Satz 7 EStG), so the numbers differ
  from what the broker reports and the Finanzamt expects.
- Money in the broker's clearing account and shares in the depot are one "account"
  today; a balance sheet needs them apart.

## Model

Classic double-entry, as in beancount/ledger, stored in SQLite.

**Accounts** form a tree. The top level is fixed and determines the account's
kind, which decides where it shows up in the reports:

| Top level     | Kind      | Report           | Examples                                               |
|---------------|-----------|------------------|--------------------------------------------------------|
| `Assets`      | asset     | balance sheet    | `Assets:Scalable:Cash`, `Assets:Scalable:Depot`, `Assets:Girokonto` |
| `Liabilities` | liability | balance sheet    | `Liabilities:Tax:Payable`                              |
| `Equity`      | equity    | balance sheet    | `Equity:Opening`, `Equity:Contributions`               |
| `Income`      | income    | income statement | `Income:Dividends`, `Income:Interest`, `Income:Gains:Shares`, `Income:Gains:Other`, `Income:Vorabpauschale` |
| `Expenses`    | expense   | income statement | `Expenses:Fees`, `Expenses:Tax:KapESt`, `Expenses:Tax:Soli`, `Expenses:Tax:KiSt`, `Expenses:Tax:Quellensteuer` |

Below the top level, accounts are created on first use, but only after
confirmation: the first posting to an unknown name asks "Create account
Expenses:Tax:Quelensteuer? (y/N)", so a typo does not silently start a new account.
A name outside the five top levels is rejected. The database stores each account's
full name and kind.

**Transactions** have a date, description and linked documents. Each has two or
more **postings** `(account, amount in cents, commodity)` whose EUR value sums to
zero; `dv` refuses to save one that does not. Accounts themselves just accumulate
their postings; because every transaction balances, all balances together always
sum to zero, which is why the balance sheet adds up. A commodity is EUR, another
currency (with the rate), or a security; a security posting carries the quantity
in millionths and its EUR value at cost.

**Lots** track what is held: `lot(account, security, opened, quantity, cost)`.
A sell closes the oldest lots first (FIFO) and books the difference between
proceeds and lot cost as gain or loss. Lot closings are stored, so a past year's
gains stay reproducible.

**Shortcuts and parsers.** The transaction types survive as shortcuts that create
the standard postings: `dv add buy ACME 10 100 -c 1` books depot, fees and cash.
Parsers produce postings instead of typed rows. Anything else, like a tax refund,
goes through a generic `dv add txn` with freely chosen postings.

## Configuration

`config.zon` names the top levels and the accounts that shortcuts and parsers post
to, so neither hard-codes names and a German chart of accounts is a config change:

```zig
.ledger = .{
    .roots = .{
        .assets = "Assets",
        .liabilities = "Liabilities",
        .equity = "Equity",
        .income = "Income",
        .expenses = "Expenses",
    },
    // Where shortcuts and parsers book; each must sit under the matching root.
    .accounts = .{
        .fees = "Expenses:Fees",
        .kapest = "Expenses:Tax:KapESt",
        .soli = "Expenses:Tax:Soli",
        .kist = "Expenses:Tax:KiSt",
        .quellensteuer = "Expenses:Tax:Quellensteuer",
        .dividends = "Income:Dividends",
        .interest = "Income:Interest",
        .gains_shares = "Income:Gains:Shares",
        .gains_other = "Income:Gains:Other",
        .vorabpauschale = "Income:Vorabpauschale",
        .contributions = "Equity:Contributions",
    },
    // Per broker account: where its cash and its securities live.
    .brokers = .{
        .{ .name = "Scalable", .cash = "Assets:Scalable:Cash", .depot = "Assets:Scalable:Depot" },
    },
},
```

Everything has defaults, so the block is optional. Config accounts count as
confirmed: shortcuts and parsers create them without asking. `dv config check`
verifies that each configured account sits under the right root. Renaming a root
later means renaming the stored accounts too; a `dv account rename` would do both.

## Examples

Buy 10 shares at €100 with €1 fee. Trade fees are part of the purchase cost
(Anschaffungsnebenkosten), so they go into the depot and the lot's cost, not into
`Expenses:Fees`; otherwise they would count twice when the shares are sold. Only
fees not tied to a trade, e.g. custody fees, are expenses.

```
Assets:Scalable:Depot     +10 ACME (cost)     +1001.00
Assets:Scalable:Cash                           -1001.00
```

Sell 4 of them at €130 with €1 fee. The FIFO lot cost is 4/10 of €1,001 = €400.40,
so the gain is €520 − €1 − €400.40 = €118.60; 25 % KapESt (€29.65) plus 5.5 % Soli
on it (€1.63):

```
Assets:Scalable:Cash                            +487.72
Expenses:Tax:KapESt                              +29.65
Expenses:Tax:Soli                                 +1.63
Assets:Scalable:Depot     -4 ACME (lot cost)    -400.40
Income:Gains:Shares                             -118.60
```

Sale fees reduce the gain directly, so the gain account holds what is taxable.

Dividend of €50 with 15% US withholding:

```
Assets:Scalable:Cash                             +42.50
Expenses:Tax:Quellensteuer                        +7.50
Income:Dividends                                 -50.00
```

Tax refund on a Kontoauszug (loss offset by the bank):

```
Assets:Scalable:Cash                             +20.00
Expenses:Tax:KapESt                              -18.96
Expenses:Tax:Soli                                 -1.04
```

Vorabpauschale for an equity ETF (no cash, but taxable and it raises the cost of
the held units so the later sale is not taxed twice):

```
Assets:Scalable:Depot     cost adjustment        +80.00
Income:Vorabpauschale                            -80.00
```

Deferrals (Rechnungsabgrenzung) are just asset/liability accounts, e.g. an annual
fee paid in December for next year goes to `Assets:Prepaid:Fees` and is released in
January. Private capital income is mostly taxed on receipt (Zuflussprinzip), so
this is the exception, not the rule.

## Reports

- **Balance sheet** at a date: asset, liability and equity balances; holdings at
  cost, at market value once prices exist.
- **Income statement** per year or month: income and expense accounts.
- **Cash flow**: postings on cash accounts, by counterpart account.
- **Tax helper per year** (Anlage KAP), from the postings:
  - gains and losses from shares vs. everything else (separate loss pots),
  - dividends, interest, Vorabpauschale,
  - Teilfreistellung for funds (equity funds 30 %, mixed 15 %, real estate
    60/80 %), which needs a fund type per security,
  - withheld KapESt/Soli/KiSt and creditable Quellensteuer,
  - use of the Sparer-Pauschbetrag (€1,000 single, €2,000 joint).
  To be checked against the broker's yearly Steuerbescheinigung, not to replace it.

## Migration

Each current row becomes one transaction (account names as configured, defaults
shown):

| Today      | Postings                                                                     |
|------------|------------------------------------------------------------------------------|
| buy        | Depot + security at cost, Expenses:Fees + cost, Cash − total                 |
| sell       | Cash + proceeds, Expenses:Fees + cost, Depot − lots (FIFO), Income:Gains:* ± |
| dividend   | Cash + net, Expenses:Tax:* + withheld, Income:Dividends − gross              |
| interest   | Cash +, Income:Interest −                                                    |
| deposit    | Cash +, Equity:Contributions −                                               |
| withdrawal | Cash −, Equity:Contributions +                                               |
| transfer   | the two linked rows become one transaction with two postings                 |

Cash and Depot are the broker's accounts from `.ledger.brokers`; a broker without
an entry gets `Assets:<name>:Cash` and `Assets:<name>:Depot`, so the migration
needs no config. Lots are rebuilt by replaying buys and sells in date order. The
paperless links move from `transaction_document` to the new transactions unchanged.

The migration is a schema version bump like v5 and runs once; a dry run first
prints the old and new reports side by side.

## Decisions

- **Market values on the balance sheet.** Holdings are shown at cost and at market
  value. That needs a `price(security, date, price, currency, source)` table and a
  price source; the balance sheet uses the latest price on or before its date and
  marks positions without one. Unrealized gains follow from cost vs. market value.
- **Several people in one ledger.** Asset and liability accounts have an
  **owner**, a person; there are no joint accounts for now. Income and expense
  postings belong to the owner of the asset or liability accounts in the same
  transaction, so a transaction may only touch one owner's accounts. Names may
  carry the owner as a convention (`Assets:Name:Scalable:Cash`), but the owner
  is stored on the account, not parsed from the name.
- **Allowances across persons.** The tax helper reports per person; whether
  allowances are combined across persons is a setting.
- **Taxes: capital income first, more later.** The tax helper covers Anlage KAP. The
  account tree stays general, so salary, rent or other income can be added as
  `Income:*` accounts with their own reports later.
- **Bank accounts too.** A Girokonto is just another `Assets:*` account.
  Parsers for bank statements are a later step, like the broker parsers. Transfers
  between Girokonto and broker become one transaction with two cash postings.

## Open questions

- Price source for market values (daily close per ISIN), and how often to fetch.

## Implementation plan

New tables next to the old ones; the old `account`/`transaction` tables are
dropped only once every command uses the new ones.

```sql
CREATE TABLE person (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE ledger_account (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,      -- full name, e.g. Assets:Name:Scalable:Cash
    kind TEXT NOT NULL CHECK (kind IN ('asset', 'liability', 'equity', 'income', 'expense')),
    owner INTEGER REFERENCES person (id),  -- required for asset and liability
    CHECK (owner IS NOT NULL OR kind NOT IN ('asset', 'liability'))
);
CREATE TABLE txn (
    id INTEGER PRIMARY KEY,
    date DATE NOT NULL,
    description TEXT NOT NULL DEFAULT ''
);
CREATE TABLE posting (
    id INTEGER PRIMARY KEY,
    txn INTEGER NOT NULL REFERENCES txn (id) ON DELETE CASCADE,
    account INTEGER NOT NULL REFERENCES ledger_account (id),
    amount INTEGER NOT NULL,        -- EUR cents; these sum to zero per txn
    currency TEXT NOT NULL DEFAULT 'EUR',
    original INTEGER,               -- cents in `currency` when it is not EUR
    security INTEGER REFERENCES security (id),
    quantity INTEGER,               -- millionths of a share, with `security`
    CHECK ((security IS NULL) = (quantity IS NULL))
);
CREATE TABLE lot (
    id INTEGER PRIMARY KEY,
    account INTEGER NOT NULL REFERENCES ledger_account (id),
    security INTEGER NOT NULL REFERENCES security (id),
    txn INTEGER NOT NULL REFERENCES txn (id),   -- the buy that opened it
    opened DATE NOT NULL,
    quantity INTEGER NOT NULL,      -- millionths
    cost INTEGER NOT NULL           -- EUR cents, raised by Vorabpauschalen
);
CREATE TABLE lot_close (
    id INTEGER PRIMARY KEY,
    lot INTEGER NOT NULL REFERENCES lot (id),
    txn INTEGER NOT NULL REFERENCES txn (id),   -- the sell
    quantity INTEGER NOT NULL,
    cost INTEGER NOT NULL,          -- share of the lot's cost
    proceeds INTEGER NOT NULL
);
CREATE TABLE price (
    security INTEGER NOT NULL REFERENCES security (id),
    date DATE NOT NULL,
    price INTEGER NOT NULL,         -- cents per share
    currency TEXT NOT NULL DEFAULT 'EUR',
    source TEXT NOT NULL,
    PRIMARY KEY (security, date, source)
);
CREATE TABLE txn_document (
    txn INTEGER NOT NULL REFERENCES txn (id) ON DELETE CASCADE,
    paperless_id INTEGER NOT NULL,
    PRIMARY KEY (txn, paperless_id)
);
```

`dv` checks before every commit that a transaction's postings sum to zero and
touch only one owner's asset and liability accounts, like the transfer check today.

Steps, each one commit or a few:

1. v6: create the tables above (empty), Zig types for transactions and postings,
   the balance and owner checks.
2. Posting builders for the shortcuts (buy, sell with FIFO lots, dividend, interest,
   deposit, withdrawal, transfer), tested on an in-memory database.
3. Migration of the existing rows into the new tables, with a dry run comparing old
   and new reports. Needs the owner of the existing broker accounts.
4. Commands one by one on the new tables: `add`, `list`, `edit`, `doc`, `import`
   (parsers produce postings), then `report`.
5. New reports: balance sheet, income statement, tax helper.
6. Drop the old tables.
7. Later: prices, bank statement parsers, `dv add txn` for free-form postings.

Until step 6 the branch's `dv` should not be used on the real database.
