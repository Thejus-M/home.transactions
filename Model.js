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
// Indian digit grouping. Two decimals only when there are paise (1,234.50),
// and a whole amount shows none (1,234).
function formatGrouped(n) {
  var value = Math.abs(Number(n))
  var fixed = value.toFixed(2)
  var parts = fixed.split(".")
  var int = parts[0]
  var last3 = int.slice(-3)
  var rest = int.slice(0, -3)
  if (rest !== "") last3 = rest.replace(/\B(?=(\d{2})+(?!\d))/g, ",") + "," + last3
  var hasPaise = parts[1] !== "00"
  return hasPaise ? last3 + "." + parts[1] : last3
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
// Axis, "SBI Savings" for SBI, so they are told apart in the filter, the
// pill and the balances.
function savingsName(bank) {
  if (bank === "AXIS") return "Axis Savings"
  if (bank === "SBI") return "SBI Savings"
  return "Savings"
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

// SBI and Axis put their own account/reference numbers BEFORE the
// counterparty, so the HDFC rule above would cut every one of their UPI
// rows down to the same prefix ("UPI- TRANSFER TO", "UPI/P2A/") and a
// rename of one row would rename them all. These parse the counterparty
// out instead. Formats (confirmed on real data):
//   SBI:  "UPI- TRANSFER TO|FROM <acct> UPI/DR|CR/<ref>/<name>/<bank>/<vpa>/<remark>"
//         (cut by SBI at ~80 chars, so the tail can be missing)
//   SBI:  "NEFT- TRANSFER FROM <acct> NEFT*<ifsc>*<ref>*<name>"
//   Axis: "UPI/P2A|P2M/<ref>/<name>/<bank>/<remark>/"
var _SBI_UPI_RE = /^UPI- TRANSFER (?:TO|FROM) \d+ UPI\/(?:DR|CR)\/\d+\/([^/]*)(?:\/([^/]*))?(?:\/[^/]*)?(?:\/(.*))?/
var _SBI_NEFT_RE = /^NEFT- TRANSFER (?:TO|FROM) \d+ NEFT\*[^*]*\*[^*]*\*(.+)$/
var _AXIS_UPI_RE = /^UPI\/P2[AMV]\/\d+\/([^/]*)\/([^/]*)(?:\/([^/]*))?/
// "UPI-LAKSHMI MOHAN-LMLAKSHMIMOHAN2002@OKSBI-SBIN0070528-627610349848-NO REMARK".
// The VPA is masked on some rows and not others, so it is never keyed on.
var _HDFC_UPI_RE = /^UPI-([^-]*)-([^-]*)-([^-]*)-(\d+)(?:-(.*))?$/

function _clean(s) {
  return (s || "").replace(/\s+/g, " ").trim()
}

// Bank codes vary in case and suffix between rows ("HDFC", "HDFC BANK", "utib").
function _bankCode(s) {
  return _clean(s).toUpperCase().replace(/ BANK$/, "")
}

// { key, name, remark } for a UPI/NEFT row of any of the three banks, or
// null. One counterparty gets one key whichever bank the row came from and
// whatever its VPA looked like ("UPI|LAKSHMI MOHAN"), so renaming a person
// once renames every transaction with them. Mirrors txdb/keys.py, which is
// what actually writes the key stored on each row.
function parsedCounterparty(t) {
  var m
  if (t.bank === "SBI" && (m = _SBI_UPI_RE.exec(t.merchant))) {
    return _counterparty(m[1], m[3])
  }
  if (t.bank === "SBI" && (m = _SBI_NEFT_RE.exec(t.merchant))) {
    return { key: "NEFT|" + _clean(m[1]).toUpperCase(), name: _clean(m[1]), remark: "" }
  }
  if (t.bank === "AXIS" && (m = _AXIS_UPI_RE.exec(t.merchant))) {
    return _counterparty(m[1], m[3])
  }
  if (t.bank === "HDFC" && (m = _HDFC_UPI_RE.exec(t.merchant)) && _clean(m[1])) {
    return _counterparty(m[1], m[5])
  }
  return null
}

function _counterparty(rawName, rawRemark) {
  var name = _clean(rawName)
  return { key: "UPI|" + name.toUpperCase(), name: name, remark: _clean(rawRemark) }
}

function transactionGroupKey(t) {
  // Rows from the database carry their key (txdb/keys.py).
  if (t.groupKey) return t.groupKey
  var parsed = parsedCounterparty(t)
  if (parsed) return parsed.key
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
// True for empty/boilerplate remarks, including ones SBI cut short ("NO RE").
function _isBoilerplateNote(note) {
  var n = note.toUpperCase()
  if (_NON_INFORMATIVE_NOTES[n]) return true
  return n.length >= 2 && ("NO REMARKS".indexOf(n) === 0)
}

function transactionNote(t) {
  if (t.note !== undefined) return t.note
  var parsed = parsedCounterparty(t)
  if (parsed) return _isBoilerplateNote(parsed.remark) ? "" : parsed.remark
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
  if (override) return override
  // SBI/Axis: the counterparty's name reads better than the raw reference
  // string (which stays visible as "Raw:" in the expanded row).
  if (t.counterparty) return t.counterparty
  var parsed = parsedCounterparty(t)
  return parsed && parsed.name ? parsed.name : t.merchant
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

// Paid means nothing left to pay on the bill already generated: the money
// decides it, not the scrape's own wording, because HDFC says "PARTIALLY
// PAID" while ₹595 is still owed and "FULLY PAID" while this cycle's new
// spend sits unbilled. The status text is only read when the card has no
// amounts at all (nothing scraped yet).
function isBillPaid(overviewEntry, manualOverride) {
  if (manualOverride && manualOverride.markedPaid) return true
  if (!overviewEntry) return true // no overview data for this card -> nothing to flag
  if (!overviewEntry.total_outstanding) {
    return !!PAID_STATUSES[String(overviewEntry.payment_status || "").toUpperCase()]
  }
  return billParts(overviewEntry).payNow <= 0
}

// --- Credit card bill dates (statementDate / dueDate / nextStatementDate are
// YYYY-MM-DD, worked out by txdb.ingest.bill_dates from HDFC's "Billing
// cycle : 12th of every month" and "Due on 1st Nov") ---

function _localDate(iso) {
  var p = String(iso).split("-")
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
}

// Whole days from today to `iso` (negative = in the past).
function daysUntil(iso) {
  var now = new Date()
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  return Math.round((_localDate(iso) - today) / 86400000)
}

// "12 Oct", or "12 Oct 2026" with `withYear`.
function formatShortDate(iso, withYear) {
  if (!iso) return ""
  var d = _localDate(iso)
  return d.getDate() + " " + _MONTH_NAMES[d.getMonth()] + (withYear ? " " + d.getFullYear() : "")
}

// "18 days left" / "due tomorrow" / "due today" / "3 days overdue".
function dueCountdown(iso) {
  var n = daysUntil(iso)
  if (n > 1) return n + " days left"
  if (n === 1) return "due tomorrow"
  if (n === 0) return "due today"
  return (-n) + (n === -1 ? " day" : " days") + " overdue"
}

// "overdue", "soon" (3 days or less) or "" for an unpaid bill with a due date.
function billUrgency(overviewEntry, paid) {
  if (paid || !overviewEntry || !overviewEntry.dueDate) return ""
  var n = daysUntil(overviewEntry.dueDate)
  return n < 0 ? "overdue" : (n <= 3 ? "soon" : "")
}

// "Bill 12 Oct · Pay by 1 Nov · 18 days left" for an unpaid bill;
// "" when the bill dates aren't known.
function billDatesLine(overviewEntry) {
  if (!overviewEntry || !overviewEntry.dueDate) return ""
  var parts = []
  if (overviewEntry.statementDate) parts.push("Bill " + formatShortDate(overviewEntry.statementDate))
  parts.push("Pay by " + formatShortDate(overviewEntry.dueDate))
  parts.push(dueCountdown(overviewEntry.dueDate))
  return parts.join("  ·  ")
}

// Everything a BILLS row says about one card, as numbers.
//
// HDFC's Overview tab splits the total four ways under "Outstanding
// Summary", and they add up:
//
//   last statement - credits paid in + unbilled purchases + unsettled
//     = total outstanding
//
// So what has to be cleared now is the whole outstanding except this
// cycle's unbilled purchases, and those purchases are next month's bill.
// Exact to the paise, deliberately: HDFC's own "Upcoming Payment" rounds
// to whole rupees (₹595.00 against ₹595.38 outstanding) and drops the
// unsettled remainder.
//
// `hasBreakdown` is false for a card scraped before that block was read (or
// a non-HDFC card later): the bill and the amount paid into the card are
// then unknown and left at 0, while payNow and nextBill still work off
// "Unbilled Amount" and "Total Outstanding".
//
// Returns { billThisMonth, paidIn, payNow, nextBill, inCredit, hasBreakdown }.
// payNow is signed — negative is the bank owing the cardholder.
function billParts(overviewEntry) {
  if (!overviewEntry) {
    return { billThisMonth: 0, paidIn: 0, payNow: 0, nextBill: 0, inCredit: false, hasBreakdown: false }
  }

  var outstanding = _money(parseCurrencyString(overviewEntry.total_outstanding))
  var hasBreakdown = !!overviewEntry.last_statement_amount
  // Next month's bill is this cycle's spend whether or not the merchant has
  // settled it yet. HDFC's "Unbilled Amount" counts only settled spend, and
  // parks the rest under "Loans and/or unsettled transactions" — leaving it
  // out billed a purchase made today as due now (₹646.38 on one live card)
  // while the row claimed no new spend. Adding it back makes pay-now agree
  // with the bank's own ask to the rupee on both cards.
  var nextBill = _money(parseCurrencyString(
    hasBreakdown ? overviewEntry.unbilled_purchases : overviewEntry.unbilled_amount)
    + parseCurrencyString(overviewEntry.unsettled_amount))
  var payNow = _money(outstanding - nextBill)

  return {
    billThisMonth: hasBreakdown ? _money(parseCurrencyString(overviewEntry.last_statement_amount)) : 0,
    // The page shows credits as a negative ("- ₹3,779.00"); this is the
    // money already sitting in the card, so it reads positive here.
    paidIn: hasBreakdown ? Math.abs(_money(parseCurrencyString(overviewEntry.unbilled_credits))) : 0,
    payNow: payNow,
    nextBill: nextBill,
    inCredit: payNow < 0,
    hasBreakdown: hasBreakdown
  }
}

// Sub-paise leftovers are noise, not money: HDFC's split leaves ₹0.38 of
// "loans and/or unsettled transactions" behind, and floating point leaves
// less than that.
function _money(n) {
  var rounded = Math.round(n * 100) / 100
  return Math.abs(rounded) < 0.005 ? 0 : rounded
}

// What every card still wants, added up, for the BILLS header.
//
// Three deliberate rules:
//   - a card the user marked paid by hand drops out, so this reaches zero
//     at the same moment the bar's bill badge clears — both go through
//     isBillPaid;
//   - a card in credit contributes 0, never a negative: the bank owing
//     ₹626 on one card does not reduce what another card asks for;
//   - this cycle's unbilled spend is not counted. Nobody has asked for it.
function billsDueTotal(cardOverviewList, billOverridesByLast4) {
  var list = cardOverviewList || []
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry) continue
    var override = billOverridesByLast4 ? billOverridesByLast4[entry.last4] : null
    if (isBillPaid(entry, override)) continue
    var payNow = billParts(entry).payNow
    if (payNow > 0) total += payNow
  }
  return _money(total)
}

// This cycle's spend across every card — what next month's bills add up to
// so far. Not filtered by the paid override: marking a bill paid says
// nothing about spend that has not been billed yet.
function billsNextTotal(cardOverviewList) {
  var list = cardOverviewList || []
  var total = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i]) total += billParts(list[i]).nextBill
  }
  return _money(total)
}

// The credit limits behind the cards, one entry per pool, newest-first
// order preserved from the list given.
//
// HDFC prints the same total and the same available figure on both of its
// cards, and total minus available is those two cards' outstanding added
// together: one pool, shared. ICICI's card carries its own, different
// limit. So a single summary was wrong as soon as a second bank arrived —
// the limits are grouped by bank, and a bank whose cards disagree about
// the total is split one pool per card rather than averaged into fiction.
//
// Each pool: { label, bank, limit, available, used, percent, cards,
// segments: [{ last4, amount, fraction }] }.
function creditLimitPools(cardOverviewList) {
  var list = cardOverviewList || []
  var byBank = {}
  var order = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || !entry.credit_limit_total) continue
    var bank = String(entry.bank || Model_accountBankOf(entry) || "")
    if (!byBank[bank]) { byBank[bank] = []; order.push(bank) }
    byBank[bank].push(entry)
  }

  var pools = []
  for (var b = 0; b < order.length; b++) {
    var cards = byBank[order[b]]
    var limits = cards.map(function (c) { return _money(parseCurrencyString(c.credit_limit_total)) })
    var shared = limits.every(function (l) { return l === limits[0] })
    if (shared) {
      pools.push(_pool(order[b], order[b], cards, limits[0],
                       _money(parseCurrencyString(cards[0].available_limit))))
    } else {
      for (var c = 0; c < cards.length; c++) {
        pools.push(_pool(order[b] + " ••" + cards[c].last4, order[b], [cards[c]], limits[c],
                         _money(parseCurrencyString(cards[c].available_limit))))
      }
    }
  }
  return pools.filter(function (pool) { return pool.limit > 0 })
}

function _pool(label, bank, cards, limit, available) {
  // More available than the limit means money sitting in the card: the
  // ICICI card shows ₹1,30,040 available against a ₹1,30,000 limit, which
  // is the ₹40 it is in credit. Nothing is used in that case, and a bar
  // drawn from a negative would read as a sliver of debt.
  var used = Math.max(0, _money(limit - available))
  var credit = Math.max(0, _money(available - limit))
  return {
    label: label, bank: bank, limit: limit, available: available, used: used, credit: credit,
    percent: limit > 0 ? _money(used / limit * 100) : 0,
    cards: cards.length, segments: _limitSegments(cards, limit, used),
  }
}

// How each card fills its pool: [{ last4, amount, fraction }] from each
// card's own outstanding, in the order given. The total is clamped to
// `used`, so a card whose outstanding is missing — or a bank that rounds
// differently — can never draw past the limit it is drawn against.
function _limitSegments(list, limit, used) {
  var segments = []
  var running = 0
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry) continue
    var amount = _money(parseCurrencyString(entry.total_outstanding))
    if (amount <= 0) continue
    amount = Math.min(amount, _money(used - running))
    if (amount <= 0) break
    running = _money(running + amount)
    segments.push({ last4: entry.last4, amount: amount, fraction: amount / limit })
  }
  return segments
}

// Every pool added up, for the one bar the section leads with:
// { limit, used, available, credit, percent, pools }.
//
// Each pool's `used` is already clamped at zero, so a card in credit
// (ICICI's ₹40) counts as nothing used rather than subtracting from
// another bank's usage — credit is reported separately instead. `pools`
// is the list it came from, so the bar can draw a segment per pool and
// open into their own strips.
function creditLimitTotal(pools) {
  var list = pools || []
  var limit = 0
  var used = 0
  var available = 0
  var credit = 0
  for (var i = 0; i < list.length; i++) {
    limit += list[i].limit
    used += list[i].used
    available += list[i].available
    credit += list[i].credit || 0
  }
  limit = _money(limit)
  used = _money(used)
  return {
    limit: limit, used: used, available: _money(available), credit: _money(credit),
    percent: limit > 0 ? _money(used / limit * 100) : 0,
    pools: list,
  }
}

// "HDFC" out of a card entry that predates the snapshot carrying its bank.
function Model_accountBankOf(entry) {
  return accountBank(entry.accountId)
}

// "Paid ₹8,965.00 · 30th Sept 2026" — last-payment line for a BILLS row.
// last_payment_amount/_date are already scraper-formatted display strings,
// so this is plain concatenation, not a formatted number.
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

// Label and network for one card row, keeping the two apart: the network is
// always read from the bank's own scraped name, never from a rename.
// Passing a rename through cardBrandParts cut the network word out of it
// — "HDFC Rupay" rendered as "HDFC ••0220" — and renaming a card to
// something without a network word silently dropped its brand mark. A
// rename now shows exactly as typed, and the mark still follows the bank.
function cardLabelParts(scrapedName, override) {
  var parts = cardBrandParts(scrapedName)
  var typed = String(override || "").trim()
  return { label: typed || parts.label, network: parts.network }
}

// "HDFC" out of an account id like "HDFC|credit|0220"; "" when there is none.
function accountBank(accountId) {
  return String(accountId || "").split("|")[0].toUpperCase()
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
