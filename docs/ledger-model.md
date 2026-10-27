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

Buy 10 shares at €100 with €1 fee:

```
Assets:Scalable:Depot     +10 ACME @ 100.00   +1000.00
Expenses:Fees                                     +1.00
Assets:Scalable:Cash                           -1001.00
```

Sell 4 of them at €130 (FIFO lot cost €400), €1 fee. The taxable gain is
€520 − €400 − €1 = €119, so 25 % KapESt (€29.75) plus 5.5 % Soli on it (€1.64):

```
Assets:Scalable:Cash                            +487.61
Expenses:Fees                                     +1.00
Expenses:Tax:KapESt                              +29.75
Expenses:Tax:Soli                                 +1.64
Assets:Scalable:Depot     -4 ACME (lot cost)    -400.00
Income:Gains:Shares                             -120.00
```

The gain is booked gross; the tax helper nets the sale's fees against it.

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
an entry gets `Assets:<name>:Cash` and `Assets:<name>:Depot`. `dv` never writes
`config.zon`. Lots are rebuilt by replaying buys and sells in date order. The
paperless links move from `transaction_document` to the new transactions unchanged.

The migration is a schema version bump like v5 and runs once; a dry run first
prints the old and new reports side by side.

## Open questions

- Balance sheet at cost only, or with market prices (which needs a price source)?
- One ledger for the whole family, or one per person with shared accounts?
- Taxes only for capital income, or other income too later?
- Cash accounts outside the broker (Girokonto) from bank statements, or only
  what flows through the broker?
