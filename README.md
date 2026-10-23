# omarchy-transactions

Omarchy bar widget (Quickshell/QML plugin) showing your real HDFC bank
transactions and credit-card billing status, and reminding you which
transactions you haven't logged into your budget tracker yet and which
bills aren't paid.

Bar icon, top-right corner → click opens a popup with: a compact
month-spend/top-spenders line, a BILLS section (one row per credit card,
click, or focus + Enter/Space, to see full details; click the status
avatar specifically to mark it paid), a Filter popover (account
selection, see below), a RECENT
transactions list (each row toggles "already recorded elsewhere", and
expands in place for more detail), and a search box hidden by default.
Fully keyboard-operable — Tab between every control, arrow keys move
within a section (Up/Down between rows; Left/Right expand/collapse a
BILLS or RECENT row's detail panel), Enter/Space to activate, "/" toggles
search, Escape to close.

## Data source

Everything the widget shows or remembers lives in one SQLite file,
`data/transactions.db` (git-ignored, mode 600), managed by the stdlib-only
`txdb/` package:

- **Fetchers write it.** `hdfc-`, `axis-`, `sbi-` and `icici-statement-fetcher` import
  `txdb.ingest` through their `src/store.py` (`TXDB_HOME` points at this
  repo) and save transactions, balances and HDFC card billing cycles.
  Each run is recorded in `fetch_runs`, and a successful run makes a backup
  in `data/backups/` (14 kept).
- **The widget reads a snapshot.** `python3 bin/txdb snapshot` prints one
  JSON object (transactions newest first, balances, card overviews, bills,
  account names, renames). Every write rewrites `data/.changed`; the widget
  watches that file and reloads the snapshot, and also on popup open.
- **The widget writes small changes.** `bin/txdb set-tracked`,
  `set-tracked-many`, `rename`, `account-name`, `bill-paid`, `bill-notified`
  run as argv commands, one at a time; the UI updates at once and the next
  snapshot confirms.
- **Live fetch signals stay files.** `output/*fetch-status.json`, the login
  QR (`output/qr.png`, HDFC and ICICI) and the OTP (sent on the fetcher's
  stdin). The QR popup follows whichever bank is fetching: the fetcher
  writes the stage `qr-ready` with the code's path, republishes the path
  with a new `updated` stamp each time the bank redraws the code, and the
  popup reloads the image off that stamp.

The credit-card picture comes from two blocks on HDFC's Overview tab,
both scraped into `card_cycles` / `hdfc_card_cycles_raw`: the Billing
Summary ("Unbilled Amount", "Total Outstanding", "Upcoming Payment" and
its status badge) and the Outstanding Summary, which splits the total
into `last_statement_amount` (this month's bill), `unbilled_credits`
(money already paid into the card, negative as the page prints it),
`unbilled_purchases` (next month's bill so far) and `unsettled_amount`.
The card tables are `card_cycles` and `card_cycles_raw` — not HDFC's
alone since the ICICI card arrived; `hdfc_card_cycles_raw` survives as a
view over the HDFC rows, because that name is in a few fingers' muscle
memory.
They add up: `last statement - credits + purchases + unsettled = total
outstanding`. The same scrape stores `credit_limit_total` and
`available_limit`; both cards report the same pair, because the limit is
one pool shared across the account.

Tables: `accounts` (id `BANK|type|last4`, optional display name),
`transactions` (shared row for every bank, with `group_key` /
`counterparty` / `note` computed by `txdb/keys.py`), `tracked`,
`merchant_names`, `balances` + `balance_history`, `card_cycles`, `bills`,
`fetch_runs`, and per-bank raw tables with every scraped field
(`sbi_transactions`, `axis_transactions`, `hdfc_savings_transactions`,
`hdfc_card_transactions`, `hdfc_card_cycles_raw`) plus `sbi_view`,
`axis_view`, `hdfc_view` for ad-hoc `sqlite3` queries.

Rows scraped before the statement's balance was kept carry one **worked
back** from the account's current balance instead (`txdb derive-balances`,
`ingest.derive_balances`): the newest row ends at the account's balance, and
each earlier row at the next row's balance less the next row's amount. It is
arithmetic, not a reading — one missing transaction would shift every
balance before it — so those rows are flagged (`balance_derived`), the
expanded card says "worked out, not read from the statement", `txdb check`
counts them, and the next fetch overwrites them with the statement's own
figures, which the reconciliation below then checks.

**Balances are checked, not trusted.** `txdb reconcile [BANK]` walks each
checking/savings account in statement order and asserts two things: every
running balance equals the one before it plus that row's amount, and the
newest equals the account's saved current balance. `txdb check` prints the
same verdict, and every fetch runs it on the way out (`guard.run_main`),
appending any mismatch to its own "done" message rather than letting a
misread amount quietly become a wrong balance in the widget.

Other commands: `txdb check`, `txdb reconcile`, `txdb backup`, `txdb export-json <dir>`, and
`txdb migrate-json` (one-off import of the old JSON files; safe to repeat).
Tests: `python3 -m unittest discover -s tests`.

## Features

- **Month summary + account balances** — merged into one compact block at
  the top (no separate header or separator — the old layout spent a full
  section's worth of margin+header+separator overhead just to show a
  couple of lines of text): "October: -₹5,632.10 spent" / "+₹0.00 in"
  computed over the full unfiltered transaction list (stable regardless
  of the account filter or search; `Model.monthSummary()`), then one line
  per checking/savings account's current balance — "Savings ••7367:
  ₹21,524.34" — read from `output/hdfc_account_balances.json` (see "Data
  source" above; `Model.formatAccountBalance()`). A `Flow`, not a single
  line: only one account exists today, but it's built to wrap to further
  lines once more accounts/banks are added to the fetcher.
- **Search** — hidden by default; "/" (from anywhere in the popup) or the
  search button next to the Filter button reveals a text box above RECENT
  that filters by merchant/display name (case-insensitive substring),
  combined with the account filter. Escape (while it's focused), or "/"
  again, hides it. Ephemeral — not persisted, resets on every close
  (explicit or on popup reopen).
- **Keyboard navigation** — every interactive element (`BillRow`,
  `FilterMenuButton`, `TransactionCard`, and everything inside the Filter
  popover) is reachable via Tab, shows a focus ring
  (`Border.controlSpec("focus", ...)`, matching the rest of the shell),
  and activates on Enter/Space. Arrow keys move within whatever section
  is focused without leaving Tab order: Up/Down steps between rows in
  BILLS and RECENT; Left/Right expand/collapse a focused
  BILLS or RECENT row's detail panel. "/" toggles the search box from
  anywhere. On a focused `TransactionCard`, F2 opens the rename field
  (Enter/Space are already claimed by "toggle
  tracked"). Escape closes the popup from anywhere inside it (or just the
  Filter popover/search box, if one of those is open).
- **RECENT transactions** — grouped into one date header per calendar day
  ("Today, October 5" / "Yesterday, October 4" / "Saturday, October 3",
  dropping the weekday name once a group is over a week old), each with
  that day's net total, and a card per transaction below it: a circular
  ↓/↑ icon (debit/credit — HDFC doesn't give us spend categories, so this
  isn't a "category" icon like a shopping-themed app's), the merchant
  name, a pill showing the account, and the amount in red (debit) or
  green (credit) — no raw remark beside the account pill any more, it
  moved into the expanded card — with the balance the statement showed after that
  transaction under it ("bal ₹6,016.89", dim). A credit card has no
  running balance, and rows saved before it was scraped have none, so
  that line simply disappears where there is nothing to show; the full
  figure also appears in the expanded card. Click a card (or Enter/Space while it's focused) to
  mark it tracked (already recorded elsewhere) — tracked cards get a
  tinted background instead of a switch. Persists to the
  `tracked` table. Clicking the
  circle on the left (or Left/Right while focused) expands the card in place to show the raw
  (pre-rename) merchant text, the full date + full account name, and an
  explicit tracked checkbox — separate from the row-click/Enter/Space
  toggle, so expanding a card never changes its tracked state by itself.
- **Rename a UPI counterparty** — hover a RECENT card to reveal an edit
  pencil (✎); click it to swap the row for an inline text field, so you
  can replace the raw scraped merchant text (often an ugly UPI string, e.g.
  `"UPI-TIMBER FUELS-PAYTMQR5D4E1X@PTYS-YESB0PTMUPI-221805950920-NO REMARK"`)
  with something readable (e.g. `"Timber Fuels"`). Keyed by
  `Model.transactionGroupKey()`, not the transaction's own id — HDFC's UPI
  text embeds a per-payment reference number (and sometimes a varying
  remark) that would otherwise make every payment to the same person look
  like a different vendor, so the key truncates at that reference number.
  The rename applies to every past *and future* transaction from that same
  counterparty. Doesn't change the
  underlying data — purely a display override. Persists to the
  `merchant_names` table, keyed by `group_key`.

  **One counterparty, one name.** The key is the person, not the string:
  every UPI row of every bank resolves to `UPI|<NAME>`, so renaming
  "LAKSHMI MOHAN" once covers the HDFC rows (masked VPA and unmasked),
  the Axis row and the SBI row alike. It used to carry the bank and the
  counterparty's bank code, which split one person into four groups that
  each needed renaming. HDFC's own UPI format
  (`UPI-<name>-<vpa>-<ifsc>-<ref>-<remark>`) was not parsed at all, so
  those rows showed the whole raw string; it is parsed now. Rows nothing
  can parse — bank charges, interest, card vendor names — keep a
  bank-prefixed key, since their text is the only identity they have.
- **Filter** — a single compact popover (`FilterMenuButton`) replacing the
  old always-expanded account-chip row and the standalone "Show archived"
  row: an account list ("All accounts" + one per distinct account, from
  `Model.accountOptions`, not hardcoded — click/Enter closes the popover),
  and below a separator a tracking view: "All transactions", "Tracked
  only" or "Not tracked only" (the chosen one is highlighted and narrows
  RECENT).
  An accent dot on the trigger
  shows at a glance whether any non-default filter is active, without
  opening it. Costs one small row whether open or closed — it's a popover,
  not an inline disclosure, so opening it doesn't push RECENT down.
  Account display names: the card's real scraped name for credit
  accounts, "Savings" for the checking account — overridable with
  `bin/txdb account-name <last4|BANK|type|last4> <name>` (no in-UI editor
  for this one, unlike per-transaction renames).
- **Select and track in bulk** — the ☑ button beside search turns on
  selection mode: each RECENT card gets a checkbox, the header shows
  "Select all" / "Clear" (for the rows currently shown), and "Track (N)" /
  "Untrack (N)" set the tracked state of every selected row. The **X** key
  toggles the focused row. Leaving selection mode clears the selection.
- **BILLS + full details** — one compact row per credit card from the
  overview file: a status-colored avatar, a brand mark next to the card
  name (Mastercard's twin circles / RuPay's own fast-forward double-
  triangle mark in its real brand orange/green, drawn with
  `QtQuick.Shapes`, when that network is detected in the scraped card
  name) and the card name; under the status disc, a pill saying where
  the bill stands — "NOT PAID" in red, "OVERDUE" once the due date has
  passed, "IN CREDIT" in green, "PAID" when you flipped it by hand —
  and beside the name the last day to pay, "Due 1 Nov · 12 days left",
  in red at three days or less. At the right edge, two figures stacked
  so they are never mistaken for one: the amount still owed on the bill
  already generated, and under it this cycle's spend — next month's
  bill — or "no spend yet" when the card has not been used this cycle.
  Three fixed columns (status, name, figures) give every row the same
  name budget, so the figures and the state can never be squeezed out
  by a long card name; the name itself is the only thing that elides.
  The numbers come from `Model.billParts` (see "Data source"). Next
  month's bill counts both settled unbilled spend *and* HDFC's "loans
  and unsettled transactions" figure: a purchase the merchant has not
  settled yet is this cycle's spend, not money the statement already
  asked for. That split makes pay-now agree with the bank to the rupee
  — outstanding ₹1,241.38 − ₹646.38 unsettled is the ₹595.00 HDFC
  asks for.
- **Section header and the shared limit** — the BILLS header carries the
  totals on its right: "to pay ₹16,600.77" across every card that is not
  marked paid (red; "all paid" in green at zero) and "next ₹3,127" for
  what this cycle has spent into next month's bills
  (`Model.billsDueTotal` / `Model.billsNextTotal`). Under it, the credit
  limit as one line and a slim meter: "limit ₹19,728 of ₹1,38,000 used"
  with the percentage green under 30% utilisation, amber past it and
  red past 50%. The section leads with **one bar for every card** —
  "limit ₹20,374 of ₹2,68,000 used · 8%", a segment per pool — and
  clicking it (or Tab + Enter) opens the per-pool strips underneath,
  each with its own figures and card key. One strip per **pool**: HDFC
  prints the same limit on both its cards and total-minus-available
  equals their combined outstanding, so those two share a pool, while
  the ICICI card carries its own — and a bank whose cards disagree about
  the total is split one pool per card rather than averaged into fiction
  (`Model.creditLimitPools`). A pool with more available than its limit
  is in credit, not negatively used: ICICI's reads "₹40 in credit of
  ₹1,30,000 limit". The bar carries one segment per card — accent, then the
  same accent at 55% — with a key under it ("••0220 ₹19,132   ••7462
  ₹1,241"), since at low utilisation a small card's segment is only a
  pixel or two wide. Before a fetch has read the limit the strip keeps
  its height and reads "limit not read yet", so the block never jumps.
  The limit is one **shared pool, not a limit per card** — both
  cards print the same total and the same available figure, and total
  minus available is the two cards' outstanding added together — so it
  belongs to the section, and each card's detail panel says "shared with
  1 other card" rather than implying the card has ₹1,38,000 of its own
  (`Model.creditLimitSummary`). The line is hidden until a fetch has
  scraped the limit. Three states, purely numeric (not tied
  to the scrape's own "FULLY PAID"/"PARTIALLY PAID" text, which says
  paid while ₹595 is still owed and partly paid while nothing is):
  green ✓ when there is nothing to pay and no unbilled spend (or the
  bank owes you); amber ● when nothing is due yet and only this cycle's
  spend is building up; red ! while a bill is unpaid. Click anywhere on
  a row, or focus it and press Enter/Space, to expand full details
  below it (the bank's own mark, bill this month, paid into the card,
  left to pay, the cycle dates, next bill so far, total outstanding,
  unsettled / loans, the shared limit with available and used, last
  payment, raw status) — or Left/Right while focused. Click (mouse only)
  the status avatar specifically to flip the manual "mark as paid"
  override, independent of the row's own color/glyph — it still drives
  the bill-due reminder/badge below, for the "I paid through another
  channel and the scrape hasn't caught up yet" case. Persists to the
  `bills` table.
- **A reload button per bank** — one line, one chip per bank: its logo
  is the button (click it, or Tab to it and press Enter, to fetch that
  bank), and beside it the balance to the rupee — the exact paise are in
  the account list above, and four chips carrying decimals needed about
  100px more than the popup has. The balance elides before the row
  wraps: the logos are the buttons, so they are the last thing to give
  way. ICICI is a credit card
  only on this profile, so its chip reads what the card wants instead —
  "₹X due", "₹40 in credit" or "nothing to pay". Only one fetch runs at a
  time; the others grey out while one is going.
- **Bill-due reminder** — while any card isn't paid, the bar icon shows a
  second "!" badge (top-right, alongside the existing untracked-count
  badge at bottom-right), and a desktop notification fires via
  `omarchy-notification-send` — at most once per card per calendar day,
  not on every popup open.

## Files

- `manifest.json` — plugin manifest (id `home.transactions`, kind `bar-widget`)
- `Panel.qml` — bar icon + popup panel, entry point
- `Icon.qml` — bar icon glyph + untracked-count badge + bill-due badge
- `Model.js` — real-data formatting/filtering/bill-status helpers
- `txdb/`, `bin/txdb` — the transactions database and its command line
- `tests/test_txdb.py` — database tests (stdlib `unittest`)
- `tests/test_model_js.py` — the bill maths in `Model.js`, run through
  `node` (skipped when node isn't installed)

## Install (local dev)

```bash
ln -s "$(pwd)" ~/.config/omarchy/plugins/home.transactions
omarchy-shell shell rescanPlugins   # if hot-reload doesn't pick it up
omarchy plugin enable home.transactions
omarchy plugin validate
```

Confirm `{"id": "home.transactions"}` is in `bar.layout.right` in
`~/.config/omarchy/shell.json` (append manually if `defaultSection` didn't
place it automatically).
