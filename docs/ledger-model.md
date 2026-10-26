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

**Accounts** form a tree with one of five kinds:

| Kind      | Examples                                                        |
|-----------|-----------------------------------------------------------------|
| asset     | `Scalable:Cash`, `Scalable:Depot`, `Girokonto`, `Tax:Receivable` |
| liability | `Tax:Payable`                                                   |
| equity    | `Equity:Opening`, `Equity:Contributions`                        |
| income    | `Income:Dividends`, `Income:Interest`, `Income:Gains:Shares`, `Income:Gains:Other`, `Income:Vorabpauschale` |
| expense   | `Expense:Fees`, `Expense:Tax:KapESt`, `Expense:Tax:Soli`, `Expense:Tax:KiSt`, `Expense:Tax:Quellensteuer` |

**Transactions** have a date, description and linked documents. Each has two or
more **postings** `(account, amount in cents, commodity)` whose EUR value sums to
zero. A commodity is EUR, another currency (with the rate), or a security; a
security posting carries the quantity in millionths and its EUR value at cost.

**Lots** track what is held: `lot(account, security, opened, quantity, cost)`.
A sell closes the oldest lots first (FIFO) and books the difference between
proceeds and lot cost as gain or loss. Lot closings are stored, so a past year's
gains stay reproducible.

The broker's documents already state most of what a transaction needs; parsers
produce postings instead of typed rows.

## Examples

Buy 10 shares at €100 with €1 fee:

```
Scalable:Depot        +10 ACME @ 100.00   +1000.00
Expense:Fees                                  +1.00
Scalable:Cash                              -1001.00
```

Sell 4 of them at €130 (FIFO lot cost €400), €1 fee. The taxable gain is
€520 − €400 − €1 = €119, so 25 % KapESt (€29.75) plus 5.5 % Soli on it (€1.64):

```
Scalable:Cash                               +487.61
Expense:Fees                                  +1.00
Expense:Tax:KapESt                           +29.75
Expense:Tax:Soli                              +1.64
Scalable:Depot        -4 ACME (lot cost)    -400.00
Income:Gains:Shares                         -120.00
```

The gain is booked gross; the tax helper nets the sale's fees against it.

Dividend of €50 with 15% US withholding:

```
Scalable:Cash                                +42.50
Expense:Tax:Quellensteuer                     +7.50
Income:Dividends                             -50.00
```

Tax refund on a Kontoauszug (loss offset by the bank):

```
Scalable:Cash                                +20.00
Expense:Tax:KapESt                           -18.96
Expense:Tax:Soli                              -1.04
```

Vorabpauschale for an equity ETF (no cash, but taxable and it raises the cost of
the held units so the later sale is not taxed twice):

```
Scalable:Depot        cost adjustment        +80.00
Income:Vorabpauschale                        -80.00
```

Deferrals (Rechnungsabgrenzung) are just asset/liability accounts, e.g. an annual
fee paid in December for next year goes to `Prepaid:Fees` and is released in
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

Each current row becomes one transaction:

| Today      | Postings                                                       |
|------------|----------------------------------------------------------------|
| buy        | Depot + security at cost, Fees + cost, Cash − total            |
| sell       | Cash + proceeds, Fees + cost, Depot − lots (FIFO), Gains ±     |
| dividend   | Cash + net, Tax + cost, Income:Dividends − gross               |
| interest   | Cash +, Income:Interest −                                      |
| deposit    | Cash +, Equity:Contributions −                                 |
| withdrawal | Cash −, Equity:Contributions +                                 |
| transfer   | the two linked rows become one transaction with two postings  |

Existing broker accounts become `<name>:Cash` and `<name>:Depot`. Lots are rebuilt
by replaying buys and sells in date order. The paperless links move from
`transaction_document` to the new transactions unchanged.

The migration is a schema version bump like v5 and runs once; a dry run first
prints the old and new reports side by side.

## Open questions

- Balance sheet at cost only, or with market prices (which needs a price source)?
- One ledger for the whole family, or one per person with shared accounts?
- Taxes only for capital income, or other income too later?
- Cash accounts outside the broker (Girokonto) from bank statements, or only
  what flows through the broker?
- Keep `dv add buy ...` style shortcuts on top of postings (yes, I would), plus a
  generic `dv add txn` for the rest?
