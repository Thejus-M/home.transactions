# omarchy-transactions

Omarchy bar widget (Quickshell/QML plugin) that reminds you which bank
transactions you haven't logged into your budget tracker yet.

Bar icon, top-right corner → click opens a popup listing recent
transactions → each row has a toggle for "already recorded elsewhere".

## Status: Phase 1 — dummy data

Currently ships with 10 hardcoded sample transactions (`Model.js`). Toggle
state persists to `~/.local/state/omarchy/transactions-tracked.json` so it
survives a shell restart, but there's no real bank connection yet.

## Files

- `manifest.json` — plugin manifest (id `home.transactions`, kind `bar-widget`)
- `Panel.qml` — bar icon + popup panel, entry point
- `Icon.qml` — bar icon glyph + untracked-count badge
- `Model.js` — dummy transaction data + amount formatting

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

## Phase 2 (future, not built yet)

- A separate sync process will log into the bank site with your credentials,
  scrape the statement, and write rows into a local SQLite DB — starting
  from the earliest transaction you care about, not full history.
- Credentials/scraping stay out of this QML code entirely; the panel will
  just read from wherever that process writes.
- `Model.js`'s row shape (`id`, `date`, `merchant`, `amount`, `currency`,
  `account`, `source`, `rawStatementRowId`, `tracked`) is already sized for
  real data, so this is additive — no UI rework needed.
