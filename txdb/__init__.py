"""Transactions database shared by the widget and the bank fetchers.

One SQLite file (data/transactions.db) holds every persistent piece of data:
accounts, transactions (a shared table plus raw per-bank tables), tracked
flags, renames, balances, card billing cycles, bill reminders and fetch run
history. The fetchers write through txdb.ingest; the widget reads a JSON
snapshot and writes small changes through the txdb CLI (bin/txdb).

Pure standard library, so the system python3 and every fetcher venv can
import it."""
