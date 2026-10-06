// Model.js — transaction data for the Transactions bar widget.
//
// Rows come from the sibling hdfc-statement-fetcher project, written to
// output/hdfc_transactions.json (see Panel.qml's fetcherOutputDir).
//
// Row shape:
//   id                 - stable string id ("hdfc-<hash>")
//   date               - ISO "YYYY-MM-DD"
//   merchant           - display description
//   amount             - number, negative = debit, positive = credit
//   currency           - ISO 4217, e.g. "INR"
//   bank               - issuing bank name, e.g. "HDFC"
//   accountType        - "checking" | "credit" (credit = credit card)
//   last4              - last 4 digits of the account/card number
//   source             - "bank-scrape"
//   rawStatementRowId  - opaque id from the bank statement row
//   tracked            - boolean, user-toggled "already recorded elsewhere"

function currencySymbol(currency) {
  if (currency === "INR") return "₹"
  if (currency === "USD") return "$"
  return (currency || "") + " "
}

// Indian digit grouping: 1,00,000.00 / 12,68,339.40 — the last three
// integer digits group together, then pairs (lakh/crore style).
function formatGrouped(n) {
  var fixed = Math.abs(Number(n)).toFixed(2)
  var parts = fixed.split(".")
  var int = parts[0]
  var last3 = int.slice(-3)
  var rest = int.slice(0, -3)
  if (rest !== "") last3 = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ",") + "," + last3
  return last3 + "." + parts[1]
}

function formatAmount(t) {
  var sign = t.amount < 0 ? "-" : "+"
  return sign + currencySymbol(t.currency) + formatGrouped(t.amount)
}

var _WEEKDAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var _WEEKDAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var _MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "Sat, Oct 5" — full (non-relative) date for the expanded transaction-card
// detail panel, where "Today"/"Yesterday" phrasing (formatRelativeDate)
// would be less useful than an unambiguous calendar date. No year: this
// widget only ever shows the current year's data in practice, and the
// other date helpers here already omit it too.
function formatFullDate(dateIso) {
  var parts = dateIso.split("-")
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  return _WEEKDAY_SHORT[d.getDay()] + ", " + _MONTH_NAMES[d.getMonth()] + " " + d.getDate()
}

// "Today" / "Yesterday" / "Saturday, 4 Oct" (within the last week) /
// "4 Oct" (older) — named manually (not toLocaleDateString) since
// Intl/ICU locale data isn't guaranteed available in Quickshell's JS
// engine.
function formatRelativeDate(dateIso) {
  var parts = dateIso.split("-")
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  var today = new Date()
  today.setHours(0, 0, 0, 0)
  d.setHours(0, 0, 0, 0)

  var diffDays = Math.round((today - d) / 86400000)
  var dayMonth = d.getDate() + " " + _MONTH_NAMES[d.getMonth()]

  if (diffDays === 0) return "Today"
  if (diffDays === 1) return "Yesterday"
  if (diffDays > 1 && diffDays < 7) return _WEEKDAY_NAMES[d.getDay()] + ", " + dayMonth
  return dayMonth
}

var _MONTH_FULL_NAMES = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
]

// "Today, October 5" / "Yesterday, October 4" / "Saturday, October 3"
// (within the past week) / "October 2" eventually — used for RECENT's
// date-group headers (one per calendar day), not per-row.
function dateGroupLabel(dateIso) {
  var parts = dateIso.split("-")
  var d = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  var today = new Date()
  today.setHours(0, 0, 0, 0)
  d.setHours(0, 0, 0, 0)

  var diffDays = Math.round((today - d) / 86400000)
  var monthDay = _MONTH_FULL_NAMES[d.getMonth()] + " " + d.getDate()

  if (diffDays === 0) return "Today, " + monthDay
  if (diffDays === 1) return "Yesterday, " + monthDay
  if (diffDays > 1 && diffDays < 7) return _WEEKDAY_NAMES[d.getDay()] + ", " + monthDay
  return monthDay
}

// Buckets `transactions` into one entry per calendar date:
// { date, label, rows, total }. Relies on `transactions` already being
// sorted newest-first (hdfc-statement-fetcher always writes/merges in
// that order, and nothing in this widget re-sorts it), so the returned
// groups — and each group's rows — come out newest-first too.
function groupByDate(transactions) {
  var order = []
  var byDate = {}
  for (var i = 0; i < transactions.length; i++) {
    var t = transactions[i]
    var bucket = byDate[t.date]
    if (!bucket) {
      bucket = { date: t.date, label: dateGroupLabel(t.date), rows: [], total: 0, currency: t.currency }
      byDate[t.date] = bucket
      order.push(bucket)
    }
    bucket.rows.push(t)
    bucket.total += t.amount
  }
  return order
}

// Resolves the display name for an account: a user-set override (from
// ~/.local/state/omarchy/transactions-account-names.json, keyed by last4)
// if one exists, else `fallback` (the card's real scraped name, or
// "Savings" for the checking account).
function accountDisplayName(fallback, last4, accountNameOverrides) {
  var override = accountNameOverrides && accountNameOverrides[last4]
  return override || fallback
}

// "HDFC Rupay ••0220" / "Savings ••7367" (or whatever the user renamed them
// to). Transaction rows don't carry the card's real scraped name, only
// bank/accountType/last4, so the fallback here is generic.
// Credit cards take their real name from the billing overview (e.g. "MASTERCARD
// MILLENNIA"), so several cards stay distinguishable; "Credit Card" only when
// no overview is known for that last4.
// Fallback name for a bank account: "Savings" for HDFC, "Axis Savings" for
// Axis, so the two are told apart in the filter, the pill and the balances.
function savingsName(bank) {
  return bank === "AXIS" ? "Axis Savings" : "Savings"
}

function cardFallbackName(accountType, last4, cardOverviewsByLast4, bank) {
  if (accountType !== "credit") return savingsName(bank)
  var overview = cardOverviewsByLast4 && cardOverviewsByLast4[last4]
  return overview && overview.name ? overview.name : "Credit Card"
}

// Network of a card ("MASTERCARD" / "RUPAY" / "VISA" / "") for its brand mark.
function cardNetwork(t, cardOverviewsByLast4) {
  if (t.accountType !== "credit") return ""
  return cardBrandParts(cardFallbackName("credit", t.last4, cardOverviewsByLast4)).network
}

function formatAccount(t, accountNameOverrides, cardOverviewsByLast4) {
  var fallback = cardFallbackName(t.accountType, t.last4, cardOverviewsByLast4, t.bank)
  return accountDisplayName(fallback, t.last4, accountNameOverrides) + " ••" + t.last4
}

function isCreditCard(t) {
  return t.accountType === "credit"
}

// Groups a transaction to one account. Needed because every HDFC credit
// card shares bank:"HDFC" — only accountType+last4 actually distinguish them.
function accountKey(t) {
  return t.bank + "|" + t.accountType + "|" + t.last4
}

// Distinct accounts present in `transactions`, as filter-chip options, in a
// stable alphabetical-by-label order. `cardOverviewsByLast4` supplies the
// real card name for credit accounts as the fallback (checking accounts
// fall back to "Savings"); `accountNameOverrides` (last4 -> name set in
// ~/.local/state/omarchy/transactions-account-names.json) takes priority
// over either when set. Not user-editable from the UI — see
// transactionNameOverrides for the per-transaction rename feature that is.
function accountOptions(transactions, cardOverviewsByLast4, accountNameOverrides) {
  var seen = {}
  var options = []
  for (var i = 0; i < transactions.length; i++) {
    var t = transactions[i]
    var key = accountKey(t)
    if (seen[key]) continue
    seen[key] = true

    var fallback
    if (t.accountType === "credit") {
      var overview = cardOverviewsByLast4 && cardOverviewsByLast4[t.last4]
      fallback = overview && overview.name ? overview.name : "Credit Card"
    } else {
      fallback = savingsName(t.bank)
    }
    var name = accountDisplayName(fallback, t.last4, accountNameOverrides)
    options.push({ key: key, label: cardBrandParts(name).label + " ••" + t.last4, network: cardBrandParts(name).network, bank: t.bank, accountType: t.accountType, last4: t.last4 })
  }
  // Cards with no settled transactions this cycle still deserve a filter
  // entry — the billing overview lists every card, transactions don't.
  var overviews = cardOverviewsByLast4 || {}
  Object.keys(overviews).forEach(function (last4) {
    var key = "HDFC|credit|" + last4
    if (seen[key]) return
    seen[key] = true
    var overview = overviews[last4]
    var name = accountDisplayName(overview && overview.name ? overview.name : "Credit Card", last4, accountNameOverrides)
    options.push({ key: key, label: cardBrandParts(name).label + " ••" + last4, network: cardBrandParts(name).network, bank: "HDFC", accountType: "credit" })
  })
  options.sort(function (a, b) { return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0) })
  return options
}

// HDFC's UPI merchant text is "UPI-<name>-<vpa>-<ifsc>-<refnum>-<remark>",
// e.g. "UPI-GREESHA RAJ-GREESHARAJ01@OKICICI-SBIN0070025-627610349848-UPI".
// `<refnum>` is always a long (8+ digit) run unique to that one payment,
// and `<remark>` after it can vary between payments to the same
// counterparty too (confirmed on real data: the same person's two
// transactions differed only in refnum AND remark: "...-627610349848-UPI"
// vs "...-125049675707-NO REMARK"). Truncating at the first long digit
// run and dropping everything from there on leaves "UPI-<name>-<vpa>-
// <ifsc>", which is identical across repeat transactions to the same
// counterparty — confirmed against real data. Non-UPI merchants (credit
// card vendor names, bank-generated labels) have no such digit run, so
// the key is just the merchant text itself, unchanged — already stable
// since those repeat verbatim.
var _LONG_DIGIT_RUN_RE = /\d{8,}/

function transactionGroupKey(t) {
  var match = _LONG_DIGIT_RUN_RE.exec(t.merchant)
  var key = match ? t.merchant.slice(0, match.index) : t.merchant
  return key.replace(/[-\s]+$/, "")
}

// The free-text remark HDFC's UPI merchant string carries after the
// refnum, e.g. "UPI-TIMBER FUELS-...-221805950920-NO REMARK" -> "NO
// REMARK", "...-627610349848-UPI" -> "UPI". Non-UPI merchants (no long
// digit run — credit card vendor names, bank-generated labels) have no
// such trailing remark, so this returns "" for those.
var _NON_INFORMATIVE_NOTES = { "": true, "UPI": true, "NO REMARK": true, "NO REMARKS": true }
var _LONG_DIGIT_RUN_GLOBAL_RE = /\d{8,}/g

// Unlike transactionGroupKey (which deliberately truncates at the FIRST
// long digit run — usually the sender's own UPI-registered phone number,
// stable across every payment from them, which is exactly what makes it
// a good grouping key), the remark sits after the LAST long digit run
// (the actual per-payment refnum). Using the first run here would grab
// everything from the phone number onward — including the varying VPA/
// IFSC in between — as "the remark", which it isn't (confirmed on real
// data: "...-8921768575@UPI-UTIB0000802-125226240762-MF AND FD" has TWO
// 8+ digit runs; the real remark is only "MF AND FD", after the second).
function transactionNote(t) {
  var matches = t.merchant.match(_LONG_DIGIT_RUN_GLOBAL_RE)
  if (!matches) return ""
  var lastRun = matches[matches.length - 1]
  var idx = t.merchant.lastIndexOf(lastRun)
  var note = t.merchant.slice(idx + lastRun.length).replace(/^[-\s]+/, "").trim()
  return _NON_INFORMATIVE_NOTES[note.toUpperCase()] ? "" : note
}

// Resolves the display merchant for one transaction: a user-set rename
// (keyed by transactionGroupKey, so it applies to every past AND future
// transaction from the same UPI counterparty, not just this one row) if
// one exists, else the raw scraped merchant text.
function transactionDisplayName(t, transactionNameOverrides) {
  var override = transactionNameOverrides && transactionNameOverrides[transactionGroupKey(t)]
  return override || t.merchant
}

// The billing-overview scrape's amount fields ("unbilled_amount",
// "total_outstanding", "upcoming_payment_due", ...) are pre-formatted
// display strings, not numbers — e.g. "₹12,683.39", or "- ₹1,993.62" for
// a negative/credit balance (the "-" sign is separated from the "₹" by a
// space). Strips everything but digits/dot, then reapplies the sign.
// Returns 0 for "", null, or anything unparseable.
function parseCurrencyString(s) {
  if (!s) return 0
  var str = String(s)
  var negative = str.indexOf("-") !== -1
  var n = parseFloat(str.replace(/[^0-9.]/g, ""))
  if (isNaN(n)) return 0
  return negative ? -n : n
}

// Known "nothing owed" statuses from the billing-overview scrape (case-
// insensitive). Anything else — UNPAID / OVERDUE / PARTIALLY PAID / an
// unseen future value — counts as a bill still due.
var PAID_STATUSES = { "FULLY PAID": true, "NO DUES": true }

function isBillPaid(overviewEntry, manualOverride) {
  if (manualOverride && manualOverride.markedPaid) return true
  if (!overviewEntry) return true // no overview data for this card -> nothing to flag
  return !!PAID_STATUSES[String(overviewEntry.payment_status || "").toUpperCase()]
}

// "Due ₹0.00  ·  FULLY PAID" — description line for a BILLS row.
function billDescription(overviewEntry) {
  if (!overviewEntry) return ""
  return "Due " + overviewEntry.upcoming_payment_due + "  ·  " + overviewEntry.payment_status
}

// "Paid ₹8,965.00 · 30th Sept 2026" — last-payment line for a BILLS row.
// last_payment_amount/_date are already scraper-formatted display strings,
// so this is plain concatenation, same as billDescription above.
function billPaidLine(overviewEntry) {
  if (!overviewEntry || !overviewEntry.last_payment_amount) return ""
  return "Paid " + overviewEntry.last_payment_amount
    + (overviewEntry.last_payment_date ? "  ·  " + overviewEntry.last_payment_date : "")
}

// Strips a known card-network word (Mastercard/Visa/Rupay) out of a card's
// display name, e.g. "MASTERCARD MILLENNIA" -> { label: "MILLENNIA",
// network: "MASTERCARD" }, so the caller can show a compact brand mark
// instead of spelling the network out. { label: name, network: "" } when
// no known network word is present.
var _CARD_NETWORK_RE = /\b(MASTERCARD|VISA|RUPAY)\b/i

function cardBrandParts(name) {
  var raw = (name || "").trim()
  var match = _CARD_NETWORK_RE.exec(raw)
  if (!match) return { label: raw, network: "" }
  var label = raw.replace(_CARD_NETWORK_RE, "").replace(/\s+/g, " ").trim()
  return { label: label || raw, network: match[1].toUpperCase() }
}

// Total spent/income/net within the calendar month of `referenceDateIso`
// (defaults to today). `spent`/`income` are non-negative; `net` is signed
// (income - spent). Reads the full, unfiltered transaction list — this is
// a "whole picture" stat, not scoped to whatever account chip is selected.
function monthSummary(transactions, referenceDateIso) {
  var ym = (referenceDateIso || new Date().toISOString().slice(0, 10)).slice(0, 7)
  var spent = 0
  var income = 0
  for (var i = 0; i < transactions.length; i++) {
    var t = transactions[i]
    if (t.date.slice(0, 7) !== ym) continue
    if (t.amount < 0) spent += -t.amount
    else income += t.amount
  }
  return {
    spent: spent,
    income: income,
    net: income - spent,
    currency: transactions.length > 0 ? transactions[0].currency : "INR",
    monthLabel: _MONTH_FULL_NAMES[Number(ym.slice(5, 7)) - 1]
  }
}

// "Savings ••7367: ₹21,524.34" — one entry from hdfc_account_balances.json
// (bank/accountType/last4/balance/currency — see hdfc-statement-fetcher's
// fetch_savings.fetch_savings_balance()). Same name-resolution rule as
// formatAccount: "Savings" fallback for checking accounts, "Credit Card"
// for credit (in case a card's available-credit ever gets added to this
// same file), overridable the same way via accountNameOverrides.
function formatAccountBalance(entry, accountNameOverrides, cardOverviewsByLast4) {
  var fallback = cardFallbackName(entry.accountType, entry.last4, cardOverviewsByLast4, entry.bank)
  var name = accountDisplayName(fallback, entry.last4, accountNameOverrides)
  return name + " ••" + entry.last4 + ": " + currencySymbol(entry.currency) + formatGrouped(entry.balance)
}
