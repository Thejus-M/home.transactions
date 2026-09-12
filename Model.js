// Model.js — transaction data for the Transactions bar widget.
//
// Phase 1: dummyTransactions() returns hardcoded sample rows.
// Phase 2 (future): a sync process will populate the same field shape from a
// real bank statement, so no schema change is needed when that lands.
//
// Row shape:
//   id                 - stable string id (phase 1: "dummy-N"; phase 2: bank txn id / row hash)
//   date               - ISO "YYYY-MM-DD"
//   merchant           - display description
//   amount             - number, negative = debit, positive = credit
//   currency           - ISO 4217, e.g. "USD"
//   account            - source account label, e.g. "Checking ••1234"
//   source             - "dummy" | "manual" | "bank-scrape"
//   rawStatementRowId  - opaque id from the bank statement row, null until phase 2
//   tracked            - boolean, user-toggled "already recorded elsewhere"

function dummyTransactions() {
  return [
    { id: "dummy-1",  date: "2026-09-10", merchant: "Trader Joe's",        amount: -42.17,   currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-2",  date: "2026-09-09", merchant: "Spotify",             amount: -11.99,   currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: true  },
    { id: "dummy-3",  date: "2026-09-08", merchant: "Shell Gas Station",   amount: -55.40,   currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-4",  date: "2026-09-07", merchant: "Amazon.com",          amount: -89.23,   currency: "USD", account: "Credit ••9821",   source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-5",  date: "2026-09-05", merchant: "Payroll Deposit",     amount: 2450.00,  currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: true  },
    { id: "dummy-6",  date: "2026-09-04", merchant: "Netflix",             amount: -15.49,   currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-7",  date: "2026-09-03", merchant: "Starbucks",           amount: -6.75,    currency: "USD", account: "Credit ••9821",   source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-8",  date: "2026-09-01", merchant: "Rent - Sunview Apts", amount: -1850.00, currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: true  },
    { id: "dummy-9",  date: "2026-08-30", merchant: "Chipotle",            amount: -13.28,   currency: "USD", account: "Credit ••9821",   source: "dummy", rawStatementRowId: null, tracked: false },
    { id: "dummy-10", date: "2026-08-28", merchant: "Electric Co-op",      amount: -74.12,   currency: "USD", account: "Checking ••1234", source: "dummy", rawStatementRowId: null, tracked: false }
  ]
}

function formatAmount(t) {
  var sign = t.amount < 0 ? "-" : "+"
  return sign + "$" + Math.abs(t.amount).toFixed(2)
}
