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
// Folds the two sides of a transfer between your own accounts (txdb/transfers.py
// tags both with the same `transferId`) into ONE entry, at the place its first
// side appears: { isTransfer, id, date, amount: 0, currency, out, in, tracked,
// matchedBy, ref }. Only when both sides are present - with one side filtered
// away (an account filter, a search) that side stays an ordinary row. The
// entry's amount is 0 so a day's net total is not thrown off by money that
// only moved between your own accounts.
function collapseTransfers(rows, transferList) {
  var byId = {}
  rows.forEach(function (t) { byId[t.id] = t })
  var info = {}
  ;(transferList || []).forEach(function (p) { info[p.id] = p })
  var seen = {}
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i]
    if (seen[t.id]) continue
    if (t.transferId) {
      var ids = t.transferId.split(">")
      var a = byId[ids[0]], b = byId[ids[1]]
      if (a && b) {
        seen[a.id] = true
        seen[b.id] = true
        var p = info[t.transferId] || {}
        out.push({ isTransfer: true, id: t.transferId, date: a.date, amount: 0, currency: a.currency,
                   out: a, in: b, tracked: !!(a.tracked && b.tracked),
                   matchedBy: p.matchedBy || "", ref: p.ref || null, inDate: b.date })
        continue
      }
    }
    // Your own name on the other side, but the other side is not in the data:
    // still a transfer, with the missing side drawn as a placeholder.
    if (t.transferSelf && !t.transferId) {
      var ghost = { ghost: true, bank: t.transferOther || "", accountType: "checking", last4: "",
                    amount: -t.amount, currency: t.currency, date: t.date, merchant: "", balance: null }
      out.push({ isTransfer: true, oneSided: true, id: "self:" + t.id, date: t.date, amount: 0,
                 currency: t.currency, out: t.amount < 0 ? t : ghost, in: t.amount > 0 ? t : ghost,
                 real: t, tracked: !!t.tracked, matchedBy: "self", ref: null, inDate: t.date })
      continue
    }
    out.push(t)
  }
  return out
}

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
  // No name at all when the bank prints none. It used to fall back to the
  // words "Credit Card", which a card sitting under BILLS beside its
  // network mark had already said twice — SBI's RuPay card read "Rupay
  // Credit Card ••5896" where "••5896" and the mark say everything.
  return overview && overview.name ? overview.name : ""
}

// A label and its masked number, with the label left out when there is
// none: "SimplyCLICK ••5896", or just "••5896".
function accountLabel(label, last4) {
  var text = String(label || "").trim()
  return (text ? text + " " : "") + "••" + last4
}

// ---- The short account tag shown next to the bank / network logo ---------
// The logo already says which bank (or card network) it is, so the tag does
// not repeat it:
//   bank account  ->  "••7367"                  (never "HDFC ••7367" / "Savings")
//   credit card   ->  "HDFC Millennia ••7462"   (the card's own name, the words
//                     Mastercard / Visa / RuPay / Credit / Card / Bank dropped -
//                     the mark beside it is the network - and the BANK kept in
//                     front, because a card mark alone does not say whose it is)
var _ACRONYMS = { UPI: true, EMI: true, HDFC: true, ICICI: true, SBI: true, IDFC: true, RBL: true, AU: true }
var _CARD_FILLER_RE = /\b(MASTERCARD|VISA|RUPAY|CREDIT|CARD|BANK|HDFC|ICICI|SBI|AXIS|IDFC|RBL)\b/gi
var _BANKISH_RE = /\b(HDFC|ICICI|SBI|AXIS|IDFC|RBL|BANK|SAVINGS|SAVING|ACCOUNT|A\/C)\b/gi

function prettyCardName(raw) {
  var s = String(raw || "").replace(_CARD_FILLER_RE, " ").replace(/\s+/g, " ").trim()
  if (!s) return ""
  return s.split(" ").map(function (w) {
    var up = w.toUpperCase()
    if (_ACRONYMS[up]) return up
    return up.charAt(0) + w.slice(1).toLowerCase()
  }).join(" ")
}

// `a`: { bank, accountType, last4 }. A user-set name (accountNameOverrides) is
// kept but tidied the same way; for a bank account it only survives if it says
// more than the bank's name.
function accountChipText(a, cardOverviewsByLast4, accountNameOverrides) {
  var override = String((accountNameOverrides && accountNameOverrides[a.last4]) || "").trim()
  if (a.accountType !== "credit") {
    var custom = override.replace(_BANKISH_RE, " ").replace(/\s+/g, " ").trim()
    return (custom ? custom + " " : "") + "••" + a.last4
  }
  var overview = cardOverviewsByLast4 && cardOverviewsByLast4[a.last4]
  var name = prettyCardName(override || (overview && overview.name) || "")
  var bank = String(a.bank || (overview && overview.bank) || "").toUpperCase()
  return [bank, name].filter(function (x) { return x !== "" }).join(" ") + " ••" + a.last4
}

// Network of a card ("MASTERCARD" / "RUPAY" / "VISA" / "") for its brand mark.
function cardNetwork(t, cardOverviewsByLast4) {
  if (t.accountType !== "credit") return ""
  var overview = cardOverviewsByLast4 && cardOverviewsByLast4[t.last4]
  if (overview && overview.network) return String(overview.network).toUpperCase()
  return cardBrandParts(cardFallbackName("credit", t.last4, cardOverviewsByLast4)).network
}

function formatAccount(t, accountNameOverrides, cardOverviewsByLast4) {
  var fallback = cardFallbackName(t.accountType, t.last4, cardOverviewsByLast4, t.bank)
  return accountLabel(accountDisplayName(fallback, t.last4, accountNameOverrides), t.last4)
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
    var overview = cardOverviewsByLast4 && cardOverviewsByLast4[t.last4]
    if (t.accountType === "credit") {
      fallback = overview && overview.name ? overview.name : ""
    } else {
      fallback = savingsName(t.bank)
    }
    var name = accountDisplayName(fallback, t.last4, accountNameOverrides)
    var parts = cardLabelParts(name, "", overview && overview.network)
    options.push({ key: key, label: accountChipText(t, cardOverviewsByLast4, accountNameOverrides), network: parts.network, bank: t.bank, accountType: t.accountType, last4: t.last4 })
  }
  // Cards with no settled transactions this cycle still deserve a filter
  // entry — the billing overview lists every card, transactions don't.
  var overviews = cardOverviewsByLast4 || {}
  Object.keys(overviews).forEach(function (last4) {
    var overview = overviews[last4]
    // The bank comes from the overview itself. It used to be hardcoded
    // "HDFC", from when HDFC's were the only cards: a card of any other
    // bank with nothing settled yet — an ICICI or SBI card on its first
    // fetch — got an HDFC chip that matched none of its rows.
    var bank = (overview && overview.bank) || "HDFC"
    var key = bank + "|credit|" + last4
    if (seen[key]) return
    seen[key] = true
    var name = accountDisplayName(overview && overview.name ? overview.name : "", last4, accountNameOverrides)
    var parts = cardLabelParts(name, "", overview && overview.network)
    options.push({ key: key, label: accountChipText({ bank: bank, accountType: "credit", last4: last4 }, overviews, accountNameOverrides), network: parts.network, bank: bank, accountType: "credit" })
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
// null. The key is per bank ("UPI|HDFC|LAKSHMI MOHAN"): the same person on two
// of your banks is two groups, so a rename on one bank never touches the
// other (a transfer between your own accounts shows once on each). Within a
// bank the VPA is not part of it. Mirrors txdb/keys.py, which is what
// actually writes the key stored on each row.
function parsedCounterparty(t) {
  var m
  if (t.bank === "SBI" && (m = _SBI_UPI_RE.exec(t.merchant))) {
    return _counterparty(t.bank, m[1], m[3])
  }
  if (t.bank === "SBI" && (m = _SBI_NEFT_RE.exec(t.merchant))) {
    return { key: "NEFT|SBI|" + _clean(m[1]).toUpperCase(), name: _clean(m[1]), remark: "" }
  }
  if (t.bank === "AXIS" && (m = _AXIS_UPI_RE.exec(t.merchant))) {
    return _counterparty(t.bank, m[1], m[3])
  }
  if (t.bank === "HDFC" && (m = _HDFC_UPI_RE.exec(t.merchant)) && _clean(m[1])) {
    return _counterparty(t.bank, m[1], m[5])
  }
  return null
}

function _counterparty(bank, rawName, rawRemark) {
  var name = _clean(rawName)
  return { key: "UPI|" + bank + "|" + name.toUpperCase(), name: name, remark: _clean(rawRemark) }
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
function cardLabelParts(scrapedName, override, network) {
  var parts = cardBrandParts(scrapedName)
  var typed = String(override || "").trim()
  // `network` is the account's own, for a card whose name never spelled it
  // out; the name is still read for the cards whose does.
  return { label: typed || parts.label, network: String(network || "").toUpperCase() || parts.network }
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
    // Money that only moved between your own accounts (or paid a card bill)
    // is neither spending nor income.
    if (t.transferId || t.transferSelf) continue
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

// --- Receipts: photographed bills, stitched to the transaction that paid --
// -------------------------------------------------------------------------
// for them. See receipt-ledger-stitcher (a separate project; this file only
// ranks and formats what txdb/receipts.py already saved) and
// txdb/receipts.py for the storage side.

// Optimistic overrides on top of the raw snapshot, the same pattern
// trackedOverrides already uses: a link/unlink/park shows immediately and
// is replaced by the real snapshot once it lands.
function receiptsWithOverrides(list, overrides) {
  if (!overrides) return list
  return list.map(function (r) {
    var o = overrides[r.id]
    if (!o) return r
    return Object.assign({}, r, o)
  })
}

// Unmatched first (newest date within that group), then everything else by
// date — a receipt needing a decision always outranks one already filed.
function receiptsSorted(list) {
  var copy = (list || []).slice()
  copy.sort(function (a, b) {
    var aPending = a.state === "unmatched" ? 0 : 1
    var bPending = b.state === "unmatched" ? 0 : 1
    if (aPending !== bPending) return aPending - bPending
    var ad = a.date || "", bd = b.date || ""
    if (ad !== bd) return ad < bd ? 1 : -1
    return a.id < b.id ? 1 : -1
  })
  return copy
}

function receiptTitle(r) {
  return (r.merchant && r.merchant.trim()) || "Unreadable bill"
}

// "7 Oct · 12 items · GST ₹133" — never prints "undefined" or "NaN" for a
// bill missing a date or an item table (the two app screenshots have
// neither a printed date nor, sometimes, a priced item list).
function receiptSubtitle(r) {
  var parts = []
  if (r.date) {
    var d = new Date(r.date + "T00:00:00")
    if (!isNaN(d.getTime())) {
      parts.push(d.toLocaleDateString(undefined, { day: "numeric", month: "short" }))
    }
  }
  var n = (r.items || []).length
  if (n > 0) parts.push(n + (n === 1 ? " item" : " items"))
  var tax = receiptTaxTotal(r)
  if (tax > 0) parts.push("GST " + currencySymbol(r.currency) + formatGrouped(tax))
  return parts.join(" · ")
}

// "2026-11-05" -> "05-11-2026", the way a till prints it. Anything that is
// not an ISO date is handed back untouched rather than mangled.
function formatReceiptDate(iso) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "")
  return m ? m[3] + "-" + m[2] + "-" + m[1] : (iso || "")
}

// The inverse, for the edit box. Accepts what a person types: "05-11-2026",
// "5/11/26", "2026-11-05". Returns the ISO date, "" for an empty box (which
// clears the date), or null when it is not a real calendar date.
function parseReceiptDate(text) {
  var t = String(text || "").trim()
  if (t === "") return ""
  var y, mo, d
  var m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(t)
  if (m) { y = +m[1]; mo = +m[2]; d = +m[3] }
  else {
    m = /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2}|\d{4})$/.exec(t)
    if (!m) return null
    d = +m[1]; mo = +m[2]; y = +m[3]
    if (m[3].length === 2) y += 2000
  }
  var check = new Date(y, mo - 1, d)
  if (check.getFullYear() !== y || check.getMonth() !== mo - 1 || check.getDate() !== d) return null
  return y + "-" + ("0" + mo).slice(-2) + "-" + ("0" + d).slice(-2)
}

// "1 pc", "1.444kg", "2 L": a count of pieces keeps a space, a measure
// sits against its number, as on the printout.
function formatQty(item) {
  if (item.qty == null) return ""
  var unit = item.unit || ""
  var spaced = unit === "" || /^(pc|pcs|nos|no)$/i.test(unit)
  return String(Number(item.qty)) + (spaced && unit ? " " : "") + unit
}

// A line's amount is not always qty x rate: on a bill whose rates are before
// GST the amount carries the tax too (Toblerone: 1 pc x 228.72 = 240.16, which
// is 228.72 + 5%). When the line's own printed figures show such a factor, it is
// kept when qty or rate changes, so changing the quantity of an item does not
// quietly drop its GST. A weighed item's tiny rounding difference (1.444 kg x
// 71.35 = 103.03, printed 103.31) is under half a percent and is ignored.
// The unit (pc, kg, L ...) never enters the sum: it is only a label.
function receiptLineFactor(item) {
  if (item.qty == null || item.rate == null || item.amount == null) return 1
  var plain = item.qty * item.rate
  if (!(plain > 0)) return 1
  var f = item.amount / plain
  return (f > 1.005 && f < 1.5) ? f : 1
}

// The amount for `qty` x `rate` on this line, keeping its GST factor. `item` is
// the line as it was printed/before the change.
function receiptLineAmount(item, qty, rate) {
  return Math.round(qty * rate * receiptLineFactor(item) * 100) / 100
}

function receiptItemCount(r) {
  return (r.items || []).length
}

function receiptItemsSum(r) {
  return (r.items || []).reduce(function (sum, i) { return sum + (i.amount || 0) }, 0)
}

function receiptTaxTotal(r) {
  if (r.tax) return r.tax
  return (r.taxes || []).reduce(function (sum, t) {
    return sum + (t.cgst || 0) + (t.sgst || 0) + (t.igst || 0) + (t.cess || 0)
  }, 0)
}

// The tax split as the bill prints it, one editable row per figure:
// "CGST (2.5%)" 8.52 - CGST/SGST each carry half the slab rate, IGST and
// cess the whole of it. `rate` is the slab (what the database addresses).
function receiptTaxRows(r) {
  var rows = []
  var base = (r.subtotal != null ? r.subtotal : receiptItemsSum(r)) - Math.abs(r.discount || 0)
  ;(r.taxes || []).forEach(function (t) {
    ;[["cgst", "CGST", 2], ["sgst", "SGST", 2], ["igst", "IGST", 1], ["cess", "CESS", 1]].forEach(function (p) {
      if (t[p[0]] == null || t[p[0]] === 0) return
      var shown = Math.round((t.rate || 0) / p[2] * 100) / 100
      // A slab saved without its rate: read it off the bill's own figures
      // (19.32 on 772.80 is 2.5%), to the nearest half percent.
      if (!shown && base > 0) shown = Math.round(t[p[0]] / base * 100 * 2) / 2
      rows.push({ rate: t.rate, field: p[0], label: p[1] + (shown ? " (" + shown + "%)" : ""), value: t[p[0]] })
    })
  })
  return rows
}

// Total tax printed on the bill, from the slabs.
function receiptTaxSum(r) {
  return (r.taxes || []).reduce(function (m, t) {
    return m + (t.cgst || 0) + (t.sgst || 0) + (t.igst || 0) + (t.cess || 0)
  }, 0)
}

// How the bill's tax relates to its figures. The subtotal is always the
// amount BEFORE GST. Three shapes occur:
//   "inclusive": the item prices already include GST (they add up to
//                subtotal + tax), e.g. item 250, Sub Total 238.10, GST 11.90,
//                Grand Total 250;
//   "on-top":    the items add up to the subtotal and tax is added after;
//   "inside":    no tax to add - it is only a split of the printed figures.
// The bill's own numbers say which. The same rule recalc_totals uses on disk.
// Platform / delivery / service fees printed on the bill: extra charges on
// top of the subtotal, neither tax nor discount.
function receiptFeesSum(r) {
  return (r.fees || []).reduce(function (m, f) { return m + (f.amount || 0) }, 0)
}

function receiptTaxMode(r) {
  var tax = receiptTaxSum(r)
  if (!(tax > 0) || r.total == null || r.subtotal == null) return "inside"
  if ((r.items || []).length && Math.abs(receiptItemsSum(r) - tax - r.subtotal) <= 0.5) return "inclusive"
  if (r.total - r.subtotal - receiptFeesSum(r) > tax / 2) return "on-top"
  return "inside"
}

function receiptTaxExclusive(r) {
  return receiptTaxMode(r) === "on-top"
}

// The subtotal and total this bill's items give, under `mode`.
function receiptRecompute(r, mode) {
  var sum = Math.round(receiptItemsSum(r) * 100) / 100
  var tax = receiptTaxSum(r)
  var disc = Math.abs(r.discount || 0), round = r.roundOff || 0
  var sub = mode === "inclusive" ? Math.round((sum - tax) * 100) / 100 : sum
  var total = Math.round((sub - disc + round + (mode === "inside" ? 0 : tax) + receiptFeesSum(r)) * 100) / 100
  return { subtotal: sub, total: total }
}

// total = subtotal - |discount| + round off + fees (+ tax when it is on top).
function receiptExpectedTotal(r, subtotal, exclusive) {
  return Math.round((subtotal - Math.abs(r.discount || 0) + (r.roundOff || 0) + receiptFeesSum(r)
    + (exclusive ? receiptTaxSum(r) : 0)) * 100) / 100
}

// The bill's money lines for the small widget view, in print order:
// Subtotal, Bill Discount (with its minus sign), Round Off, then the tax
// rows - only the ones the bill actually has. {label, value} with value
// already formatted to two decimals.
function receiptSummaryLines(r) {
  var lines = []
  if (r.subtotal != null) lines.push({ label: "Subtotal", value: r.subtotal.toFixed(2) })
  if (r.discount) lines.push({ label: "Bill Discount", value: "-" + Math.abs(r.discount).toFixed(2) })
  ;(r.fees || []).forEach(function (f) { lines.push({ label: f.label, value: (f.amount || 0).toFixed(2) }) })
  if (r.roundOff) lines.push({ label: "Round Off", value: r.roundOff.toFixed(2) })
  receiptTaxRows(r).forEach(function (t) { lines.push({ label: t.label, value: t.value.toFixed(2) }) })
  return lines
}

// What became of the bill's photo. Nothing is ever deleted: once the bill is
// linked the photo is compressed and kept inside the database.
function receiptPhotoNote(r) {
  var saved = r.imageSaved
  if (saved && saved.bytes) {
    var was = saved.originalBytes && saved.originalBytes > saved.bytes ? ", was " + formatBytes(saved.originalBytes) : ""
    return "Photo compressed and kept in the database (" + formatBytes(saved.bytes) + was + ")"
  }
  if (r.imageDeleted) return "Photo deleted"
  if (r.state === "linked") return "Photo will be compressed and kept in the database"
  return ""
}

// "2026-06-25 22:39:08" -> "25-06-2026 22:39"; a bare date loses the time.
function formatStamp(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?/.exec(text || "")
  if (!m) return text || ""
  return m[3] + "-" + m[2] + "-" + m[1] + (m[4] ? " " + m[4] + ":" + m[5] : "")
}

function formatBytes(n) {
  if (n == null) return ""
  if (n < 1024) return n + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(0) + " KB"
  return (n / 1024 / 1024).toFixed(1) + " MB"
}

// The info panel's rows: what the photo file knew and where the bill came
// from - [{label, value}], only rows that have something to say.
function receiptInfoRows(r) {
  var m = r.imageMeta || {}
  var rows = []
  function add(label, value) { if (value !== undefined && value !== null && value !== "") rows.push({ label: label, value: String(value) }) }
  add("Photo taken", formatStamp(m.taken))
  if (m.taken && r.date) {
    var apart = _daysBetween(r.date, m.taken.slice(0, 10))
    if (apart !== null) add("Bill date vs photo", apart === 0 ? "same day"
      : apart + (apart === 1 ? " day apart" : " days apart"))
  }
  add("Camera", m.camera)
  var dims = m.width && m.height ? m.width + " × " + m.height + " px" : ""
  add("Image", [dims, m.format, formatBytes(m.size_bytes != null ? m.size_bytes : r.sourceSize)]
    .filter(function (x) { return x }).join("  ·  "))
  add("File", m.file_name || (r.sourcePath ? String(r.sourcePath).split("/").pop() : ""))
  add("File modified", formatStamp(m.modified || r.sourceMtime))
  add("Photo", receiptPhotoNote(r))
  add("Imported", formatStamp(r.importedAt))
  add("Last read", [formatStamp(r.parsedAt), r.method].filter(function (x) { return x }).join("  ·  "))
  return rows
}

// One row per GST slab: "GST 5% · on ₹890" / "₹44.50 (C 22.25 + S 22.25)".
function receiptGstLines(r) {
  return (r.taxes || []).map(function (t) {
    var total = (t.cgst || 0) + (t.sgst || 0) + (t.igst || 0) + (t.cess || 0)
    var parts = []
    if (t.cgst) parts.push("C " + t.cgst.toFixed(2))
    if (t.sgst) parts.push("S " + t.sgst.toFixed(2))
    if (t.igst) parts.push("I " + t.igst.toFixed(2))
    if (t.cess) parts.push("cess " + t.cess.toFixed(2))
    return {
      label: "GST " + (t.rate || 0) + "%" + (t.taxable ? "  ·  on " + currencySymbol(r.currency) + formatGrouped(t.taxable) : ""),
      value: currencySymbol(r.currency) + total.toFixed(2) + (parts.length ? "  (" + parts.join(" + ") + ")" : "")
    }
  })
}

// Parser warnings plus one more computed here: items that don't add up to
// the printed subtotal/total, the same check the Python referee makes, kept
// visible in the UI even if the parser's own list didn't catch it.
function receiptWarnings(r) {
  var out = (r.warnings || []).slice()
  var items = r.items || []
  if (items.length) {
    var sum = receiptItemsSum(r)
    var target = r.subtotal != null ? r.subtotal : r.total
    // Item prices may already include GST: then they add up to the subtotal
    // plus the tax, or to the grand total, instead of to the subtotal.
    var taxIn = receiptTaxSum(r)
    var inclusiveOk = r.subtotal != null && ((taxIn > 0 && Math.abs(sum - (r.subtotal + taxIn)) <= 0.5)
      || (taxIn > 0 && r.total != null && Math.abs(sum - r.total) <= 0.5))
    if (target != null && Math.abs(sum - target) > 0.5 && !inclusiveOk) {
      out.push("items add up to " + sum.toFixed(2) + ", the bill says " + target.toFixed(2))
    }
  }
  // subtotal - discount + round-off == total - the same identity
  // receipt-ledger-stitcher's referee() checks before a bill is ever saved
  // (discount is always a positive amount taken off, whatever sign a stray
  // hand edit gave it). Checked again here, live, so a hand edit to any one
  // of the four figures that breaks the bill's own arithmetic is caught at
  // once, not just at the next re-parse.
  if (r.subtotal != null && r.total != null) {
    var discount = Math.abs(r.discount || 0)
    var roundOff = r.roundOff || 0
    var tax = receiptTaxSum(r)
    var fees = receiptFeesSum(r)
    var inclusive = r.subtotal - discount + roundOff + fees
    var onTop = inclusive + tax
    if (Math.abs(inclusive - r.total) > 0.5 && !(tax > 0 && Math.abs(onTop - r.total) <= 0.5)) {
      out.push("subtotal " + r.subtotal.toFixed(2) + " - discount " + discount.toFixed(2) +
              " + round-off " + roundOff.toFixed(2) + (fees > 0 ? " + fees " + fees.toFixed(2) : "") +
              (tax > 0 ? " + tax " + tax.toFixed(2) : "") +
              " = " + (tax > 0 ? onTop : inclusive).toFixed(2) +
              ", not the total " + r.total.toFixed(2))
    }
  }
  return out
}

// True when the bill's own arithmetic holds - no parser warning, and the
// live checks in receiptWarnings (items vs. subtotal, subtotal - discount
// + round-off vs. total) agree too, so a hand edit that breaks either one
// turns this false again at once, same as a parser warning always did.
function receiptIsBalanced(r) {
  return receiptWarnings(r).length === 0
}

// {glyph, pill, tone} for the row's status gutter. "CHECK" covers both
// the parser's own doubt (needsReview) and a live arithmetic mismatch -
// a hand edit that breaks the bill's own sums needs the same red flag a
// shaky OCR/LLM read always got, not just at the next re-parse.
function receiptStateMark(r) {
  if (r.state === "linked") return { glyph: "✓", pill: "FILED", tone: "credit" }
  if (r.state === "cash") return { glyph: "₹", pill: "CASH", tone: "muted" }
  if (r.state === "ignored") return { glyph: "−", pill: "IGNORED", tone: "muted" }
  if (r.needsReview || !receiptIsBalanced(r)) return { glyph: "!", pill: "CHECK", tone: "debit" }
  return { glyph: "?", pill: "TO LINK", tone: "pending" }
}

var _RECEIPT_NOISE = /\b(UPI|P2M|P2A|P2V|DR|CR|NEFT|IMPS|RTGS|ACH|NACH|ECS|BANK|LTD|LIMITED|PVT|PRIVATE|INDIA|THE|AND|PAY|PAYMENT|PAYMENTS|TRANSFER|TO|FROM|BRN|POS|ATM|REF|TXN|STORE|SHOP|RETAIL|IN|OF|AT|HDFC|ICICI|AXIS|SBI|KOTAK|YES|PAYTM|GPAY|PHONEPE)\b/g

// A shop name's identifying words, same rule as the Python matcher
// (match.py:tokens) so the two cannot silently disagree about what counts
// as a real word versus a bank/rail name riding along in a UPI string.
function _receiptTokens(text) {
  var out = {}
  String(text || "").toUpperCase().replace(_RECEIPT_NOISE, " ").split(/[^A-Z0-9]+/).forEach(function (t) {
    if (t.length >= 3 && !/^\d+$/.test(t)) out[t] = true
  })
  return out
}

function _daysBetween(a, b) {
  if (!a || !b) return null
  var da = new Date(a + "T00:00:00"), db = new Date(b + "T00:00:00")
  if (isNaN(da.getTime()) || isNaN(db.getTime())) return null
  return Math.round(Math.abs(da - db) / 86400000)
}

// 0-100 and why; 0 = disqualified. Mirrors receipt-ledger-stitcher's
// src/match.py:score() against a shared set of cases (tests/test_receipts_js.py)
// so the picker here and the offline auto-match cannot silently drift apart.
// Amount carries the most weight (the one field OCR/LLM reads reliably);
// the merchant can SUBTRACT, not just fail to add, because a same-amount,
// close-date mismatch (a restaurant bill vs. a cinema ticket, both ₹250,
// three days apart) is a real case this caught during testing.
function receiptMatchScore(receipt, txn) {
  if (txn.amount == null || txn.amount >= 0) return { score: 0, reasons: ["not a spend"] }
  var spent = Math.round(Math.abs(txn.amount) * 100) / 100
  if (receipt.total == null) return { score: 0, reasons: ["the bill has no total to match on"] }
  var total = Math.round(receipt.total * 100) / 100
  var gap = Math.abs(spent - total)
  var points, reasons
  if (gap <= 0.011) { points = 60; reasons = ["exact amount"] }
  else if (gap <= 1.0) { points = 55; reasons = ["amount off by " + gap.toFixed(2) + " (rounding)"] }
  else if (gap <= Math.max(5.0, total * 0.01)) { points = 40; reasons = ["amount off by " + gap.toFixed(2)] }
  else return { score: 0, reasons: ["amount off by " + gap.toFixed(2)] }

  var days = _daysBetween(receipt.date, txn.date)
  if (days === null) reasons.push("no date on the bill")
  else if (days === 0) { points += 25; reasons.push("same day") }
  else if (days === 1) { points += 18; reasons.push("1 day apart") }
  else if (days <= 3) { points += 8; reasons.push(days + " days apart") }
  else if (days <= 5) { points += 2; reasons.push(days + " days apart") }
  else reasons.push(days + " days apart")

  var billWords = _receiptTokens(receipt.merchant)
  var txnWords = _receiptTokens(txn.merchant)
  Object.keys(_receiptTokens(txn.counterparty)).forEach(function (k) { txnWords[k] = true })
  var billKeys = Object.keys(billWords), txnKeys = Object.keys(txnWords)
  if (billKeys.length && txnKeys.length) {
    var shared = billKeys.filter(function (k) { return txnWords[k] })
    if (shared.length) { points += Math.min(15, 6 + 3 * shared.length); reasons.push("merchant '" + shared[0] + "' matches") }
    else if (billKeys.some(function (x) { return txnKeys.some(function (y) { return x.length >= 4 && y.length >= 4 && (x.indexOf(y) >= 0 || y.indexOf(x) >= 0) }) })) {
      points += 6; reasons.push("merchant partly matches")
    } else { points -= 15; reasons.push("merchant does not match") }
  }
  return { score: Math.max(0, Math.min(points, 100)), reasons: reasons }
}

// Ranked candidate transactions for the link picker. `opts`:
//   excludeIds: {txnId: true} already claimed by another receipt
//   untrackedOnly: restrict to not-yet-tracked rows (the auto-match rule;
//     the picker itself defaults to false, since a tracked row — the KSBC
//     liquor bill's case — is still something you may want to file by hand)
//   query: free-text filter on amount or merchant
//   limit: how many to return (default 12)
//
// Every transaction on the receipt's own date is always included, even at
// score 0: a parse the arithmetic couldn't trust (a wrong total from a bad
// OCR/LLM read, which is exactly when a human needs to link by hand) scores
// nothing against the real transaction, and used to vanish from this list
// entirely - leaving nothing to click on the one bill that most needed it.
// Same-day rows sort first regardless of score, then by score, so the
// picker reads as "here's what happened that day" rather than "here's
// what the arithmetic liked".
function receiptCandidates(receipt, transactions, opts) {
  opts = opts || {}
  var exclude = opts.excludeIds || {}
  var query = (opts.query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < transactions.length; i++) {
    var t = transactions[i]
    if (exclude[t.id]) continue
    if (opts.untrackedOnly && t.tracked) continue
    if (query) {
      var hay = (String(t.merchant || "") + " " + String(t.counterparty || "") + " " + String(Math.abs(t.amount))).toLowerCase()
      if (hay.indexOf(query) === -1) continue
    }
    var sameDay = !!receipt.date && t.date === receipt.date
    var r = receiptMatchScore(receipt, t)
    // opts.nearDays: also offer anything within that many days of the bill,
    // whatever its score - a card payment can post a day or two after the
    // bill is dated, and a bad amount read scores 0 against the real one.
    var apart = _daysBetween(receipt.date, t.date)
    var near = !!opts.nearDays && apart !== null && apart <= opts.nearDays
    if (r.score > 0 || sameDay || near) {
      var reasons = r.reasons.length ? r.reasons.slice() : (sameDay ? ["same day"] : [])
      if (near && !sameDay && !reasons.some(function (x) { return /apart/.test(x) }))
        reasons.push(apart + (apart === 1 ? " day apart" : " days apart"))
      // The one to look at first: the very amount, on the bill's own date.
      var exact = reasons.indexOf("exact amount") >= 0
      out.push({ txn: t, score: r.score, sameDay: sameDay, reasons: reasons,
                 exact: exact, match: exact && sameDay })
    }
  }
  out.sort(function (a, b) {
    if (a.sameDay !== b.sameDay) return a.sameDay ? -1 : 1
    if (b.score !== a.score) return b.score - a.score
    var da = _daysBetween(receipt.date, a.txn.date), db = _daysBetween(receipt.date, b.txn.date)
    return (da == null ? 999 : da) - (db == null ? 999 : db)
  })
  // The limit trims the long tail of cross-date candidates, never the
  // receipt's own date: a day with more same-day transactions than the
  // limit used to lose some of them silently off the end of this list,
  // which is exactly the day a human most needs to see all of them.
  var limit = opts.limit || 12
  var sameDayCount = out.filter(function (c) { return c.sameDay }).length
  return out.slice(0, Math.max(limit, sameDayCount))
}

// The linked receipt's own text, read live off `store.receipts` rather than
// stored on the transaction: `note` (txdb/keys.py) is recomputed and
// overwritten on every re-fetch of that statement row (ingest.py upserts
// `note = excluded.note`), so a receipt's merchant/items would be silently
// wiped out the next time the bank is fetched if it lived there instead.
// A transaction holds at most one linked receipt (receipt_links is unique
// on transaction_id), so the first match is the only one there can be.
function linkedReceiptForTransaction(txn, receipts) {
  for (var i = 0; i < (receipts || []).length; i++) {
    var r = receipts[i]
    if (r.state === "linked" && r.transactionId === txn.id) return r
  }
  return null
}

// "FRESH MART — Rice (Matta), Sunflower Oil, Toor Dal, …" — the bill's own
// merchant and item list, shown as a note under the transaction it paid
// for. "" when nothing is linked, so the caller's `visible:` needs no
// separate null check.
function receiptNoteForTransaction(txn, receipts) {
  var r = linkedReceiptForTransaction(txn, receipts)
  if (!r) return ""
  var parts = []
  var merchant = (r.merchant && r.merchant.trim()) || ""
  if (merchant) parts.push(merchant)
  var descriptions = (r.items || []).map(function (i) { return i.description }).filter(Boolean)
  if (descriptions.length) {
    parts.push(descriptions.slice(0, 6).join(", ") + (descriptions.length > 6 ? ", …" : ""))
  }
  return parts.join(" — ")
}
