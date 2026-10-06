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

Real data is read directly from the sibling
[`hdfc-statement-fetcher`](../hdfc-statement-fetcher) project's output
files — a hardcoded path in `Panel.qml`'s `fetcherOutputDir` property,
since this is a single-machine personal setup, not something that needs a
settings UI:

- `output/hdfc_transactions.json` — all transactions, in exactly the row
  shape `Model.js` expects (`id`, `date`, `merchant`, `amount`, `currency`,
  `bank`, `accountType`, `last4`, `source`, `rawStatementRowId`, `tracked`).
  Rewritten wholesale on every fetcher run — the widget just re-reads it,
  no merge logic needed here.
- `output/hdfc_creditcard_overview.json` — one entry per credit card
  (`name`, `last4`, `payment_status`, `upcoming_payment_due`,
  `total_outstanding`, `last_payment_amount`, `last_payment_date`, ...).
  Also rewritten wholesale each run.
- `output/hdfc_account_balances.json` — one entry per checking/savings
  account (`bank`, `accountType`, `last4`, `balance`, `currency`), read
  off the current balance HDFC already shows next to each transaction
  (`fetch_savings.fetch_savings_balance()` in the fetcher — previously
  scraped only to split it out of the transaction amount, never
  persisted). Also rewritten wholesale each run. A list, not one object,
  so more accounts (this bank or another) can be appended later without
  a schema change here.

All three files are watched (`FileView` + `onFileChanged: reload()`), so
the widget picks up a fresh fetcher run automatically without reopening
the popup, and are also explicitly reloaded whenever the popup opens.

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
  green (credit). Click a card (or Enter/Space while it's focused) to
  mark it tracked (already recorded elsewhere) — tracked cards get a
  tinted background instead of a switch. Persists to
  `~/.local/state/omarchy/transactions-tracked.json`. A chevron (or
  Left/Right while focused) expands the card in place to show the raw
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
  underlying data — purely a display override. Persists to
  `~/.local/state/omarchy/transactions-custom-names.json`.
- **Filter** — a single compact popover (`FilterMenuButton`) replacing the
  old always-expanded account-chip row and the standalone "Show archived"
  row: an account list ("All accounts" + one per distinct account, from
  `Model.accountOptions`, not hardcoded — click/Enter closes the popover).
  An accent dot on the trigger
  shows at a glance whether any non-default filter is active, without
  opening it. Costs one small row whether open or closed — it's a popover,
  not an inline disclosure, so opening it doesn't push RECENT down.
  Account display names: the card's real scraped name for credit
  accounts, "Savings" for the checking account — overridable by
  hand-editing `~/.local/state/omarchy/transactions-account-names.json`
  (keyed by `last4`; no in-UI editor for this one, unlike per-transaction
  renames).
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
  name), the card name, and the
  outstanding amount — denser than the old toggle-switch-plus-
  description-line layout, same information. Three states, purely
  numeric (not tied to the scrape's own "FULLY PAID"/"NO DUES" text,
  which can say paid while new unbilled spend still sits there): green
  ✓ when outstanding is zero or negative (bank owes you); amber ● when
  there's a positive outstanding/unbilled amount but nothing has
  actually come due yet (`upcoming_payment_due` is still ₹0); red ! once
  an amount has actually come due. Click anywhere on a row, or focus it
  and press Enter/Space, to expand full details below it (unbilled
  amount, total outstanding, upcoming due, spend/credit this cycle, last
  payment, raw status) — or Left/Right while focused. Click (mouse only)
  the status avatar specifically to flip the manual "mark as paid"
  override, independent of the row's own color/glyph — it still drives
  the bill-due reminder/badge below, for the "I paid through another
  channel and the scrape hasn't caught up yet" case. Persists to
  `~/.local/state/omarchy/transactions-bills.json`.
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
