# The double-entry ledger

How `dv` records money. The approach is the same as in beancount or
ledger-cli. This note explains how the model works and why the reports add up,
using one small worked example.

## Accounts are running totals

An account is a list of dated amounts with a running balance, like a bank
statement. A broker's clearing account is an account, and so is its depot. So
are less tangible things: "dividends received", "KapESt withheld", "money I put
in". Nothing is ever posted to only one of them.

A **transaction** is a set of two or more **postings**. Each posting is an amount
on one account, and the postings of a transaction sum to zero:

```
2026-01-05  Deposit
  Assets:Scalable:Cash            +2000.00
  Equity:Contributions            -2000.00
```

Money does not appear or disappear; it moves from one account to another. If you
draw accounts as nodes and transactions as edges, every euro leaving one node
arrives at another, and because each transaction sums to zero, so do the
balances of all accounts together. That one invariant is what makes the balance
sheet balance. `dv` refuses to save a transaction that does not sum to zero.

A transaction may touch more than two accounts. A sale with fees and taxes has
five postings and still sums to zero.

## Five kinds of account

The top-level name of an account fixes its kind. The kind decides which report it
appears on and which sign is normal for it:

| Top level     | Holds                          | Normal sign | Report           |
|---------------|--------------------------------|-------------|------------------|
| `Assets`      | what you have                  | +           | balance sheet    |
| `Liabilities` | what you owe                   | −           | balance sheet    |
| `Equity`      | what you put in, and earnings  | −           | balance sheet    |
| `Income`      | where money came from          | −           | income statement |
| `Expenses`    | where money went               | +           | income statement |

The signs follow from the zero sum. A dividend adds to cash (+) so the matching
posting on `Income:Dividends` is negative. Income is negative internally;
reports flip the sign for display. Debit and credit are just names for the two
signs.

Asset, liability and equity accounts describe a **point in time**: what is there
now. Income and expense accounts describe a **period**: what happened this year.

Below the top level the tree is free: `Assets:Scalable:Depot`,
`Expenses:Tax:Soli`. A new account name is only created after confirmation, so
a typo does not quietly open a new account. Names outside the five top levels
are rejected. The names that shortcuts and parsers post to are set in the
`.ledger` block of `config.zon`; `dv config check` shows names under the wrong
top level.

## Securities and lots

A posting on a depot account carries a security and a quantity next to its EUR
amount. The EUR amount is the cost, not the market value.

Each buy opens a **lot**: so many shares, bought on this date, for this cost. Trade
fees are part of the cost (Anschaffungsnebenkosten), so they go into the lot,
not to `Expenses:Fees`.

```
2026-02-02  Buy 10 ACME at 100.00, fee 1.00
  Assets:Scalable:Depot     +10 ACME      +1001.00
  Assets:Scalable:Cash                    -1001.00
```

A sale closes the oldest lots first (FIFO, as § 20 Abs. 4 Satz 7 EStG requires
per securities account). The depot loses the closed lots' cost, cash gets the
proceeds, and the difference is the gain. Sale fees reduce the gain, so the gain
account holds what is taxable:

```
2026-06-10  Sell 4 ACME at 130.00, fee 1.00
  Assets:Scalable:Cash                     +487.72
  Expenses:Tax:KapESt                       +29.65
  Expenses:Tax:Soli                          +1.63
  Assets:Scalable:Depot     -4 ACME        -400.40
  Income:Gains:Shares                      -118.60
```

The four shares cost 4/10 × 1001.00 = 400.40. The gain is 520.00 − 1.00 −
400.40 = 118.60, taxed at 25 % KapESt (29.65) plus 5.5 % Soli on that (1.63).
Which lots were closed, and for how much, is stored, so a past year's gains are
reproducible.

Gains from shares and from everything else go to separate accounts, because the
tax law keeps their losses in separate pots.

## Income with withheld tax

```
2026-07-15  Dividend ACME, 15 % US withholding
  Assets:Scalable:Cash                      +42.50
  Expenses:Tax:Quellensteuer                 +7.50
  Income:Dividends                          -50.00
```

The income account gets the gross amount; the tax is an expense, whether or not
the money ever reached the cash account.

## Reports are sums

After these four transactions the balances are:

| Account                      |   Balance |
|------------------------------|----------:|
| `Assets:Scalable:Cash`       |  +1529.22 |
| `Assets:Scalable:Depot`      |   +600.60 |
| `Equity:Contributions`       |  −2000.00 |
| `Income:Gains:Shares`        |   −118.60 |
| `Income:Dividends`           |    −50.00 |
| `Expenses:Tax:KapESt`        |    +29.65 |
| `Expenses:Tax:Soli`          |     +1.63 |
| `Expenses:Tax:Quellensteuer` |     +7.50 |
| **Sum**                      |  **0.00** |

This list is the **trial balance**. It always sums to zero, which proves nothing
about correctness but catches every one-sided mistake.

The **income statement** for 2026 takes the income and expense accounts, with
signs flipped: income 168.60, expenses 38.78, net income 129.82.

The **balance sheet** takes the rest. At the end of a period the income and
expense balances are moved ("closed") into an equity account for earnings, so
the period starts from zero and the balance sheet only needs three kinds:

| Assets                 |         | Equity                 |         |
|------------------------|--------:|------------------------|--------:|
| Cash                   | 1529.22 | Contributions          | 2000.00 |
| Depot (6 ACME at cost) |  600.60 | Earnings               |  129.82 |
| **Total**              | 2129.82 | **Total**              | 2129.82 |

Both sides match because all balances sum to zero:
Assets + Liabilities + Equity + Income + Expenses = 0, which after closing is
the familiar Assets = Liabilities + Equity. The two reports are views on the same
postings: the income statement explains how equity changed between two balance
sheets.

In the database every report is a grouped sum over the posting table:

```sql
SELECT a.name, sum(p.amount)
FROM posting p
JOIN txn t ON t.id = p.txn
JOIN ledger_account a ON a.id = p.account
WHERE a.kind IN ('income', 'expense') AND t.date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY a.name;
```

## More shapes

A tax refund reverses expenses, so their postings are negative:

```
  Assets:Scalable:Cash                      +20.00
  Expenses:Tax:KapESt                       -18.96
  Expenses:Tax:Soli                          -1.04
```

The Vorabpauschale is taxable income without cash. It raises the cost of the
held units, so the later sale is not taxed on it again:

```
  Assets:Scalable:Depot     cost +80.00     +80.00
  Income:Vorabpauschale                     -80.00
```

A prepaid fee for next year (Rechnungsabgrenzung) goes to an asset such as
`Assets:Prepaid:Fees` and moves to `Expenses:Fees` in the year it belongs to.

## Several people

Asset and liability accounts have an owner. Income and expenses belong to
whoever owns the asset or liability accounts in the same transaction, so one
transaction may only touch one owner's accounts. Reports can then be made per
person. The owner is stored on the account, not read from its name.

## Further reading

- Martin Kleppmann, [Accounting for Computer Scientists](https://martin.kleppmann.com/2011/03/07/accounting-for-computer-scientists.html):
  accounts as a graph.
- Martin Blais, [The Double-Entry Counting Method](https://beancount.github.io/docs/the_double_entry_counting_method.html):
  timelines, signs, closing and the table view.
