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
                   matchedBy: p.matchedBy || "", ref: p.ref || null, inDate: b.date,
                   certainty: p.certainty || 0, matchedAt: p.matchedAt || null, isNew: !!p.isNew,
                   outBank: p.outBank || a.bank, inBank: p.inBank || b.bank })
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
                 real: t, tracked: !!t.tracked, matchedBy: "self", ref: null, inDate: t.date,
                 certainty: 1, matchedAt: null, isNew: false, outBank: "", inBank: "" })
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
    // Money that only moved between your own accounts is not part of the day's net.
    if (!t.transferId && !t.transferSelf) bucket.total += t.amount
  }
  return order
}

// Flattens groupByDate's day buckets into one array for a single
// virtualized ListView (Panel.qml's txnList) — each row carries its own
// day's header label/total/currency plus `sectionFirst` (true for the
// first row of a new day), so the delegate can draw the same date-header +
// day-total design the old nested Repeaters drew, without needing a
// Repeater (or a model) per day.
function flattenGroups(groups) {
  var out = []
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i]
    for (var j = 0; j < g.rows.length; j++) {
      out.push(Object.assign({}, g.rows[j], {
        sectionFirst: j === 0,
        sectionLabel: g.label,
        sectionTotal: g.total,
        sectionCurrency: g.currency,
      }))
    }
  }
  return out
}

// Shallow-ish equality for two flattenGroups rows: same own keys, same
// values, except nested objects (a transfer row's `out`/`in`/`real` legs)
// get a deep string compare since those are fresh objects every rebuild
// even when their contents didn't change.
function _flatRowEqual(a, b) {
  var ak = Object.keys(a), bk = Object.keys(b)
  if (ak.length !== bk.length) return false
  for (var i = 0; i < ak.length; i++) {
    var k = ak[i]
    if (!b.hasOwnProperty(k)) return false
    var av = a[k], bv = b[k]
    if (av === bv) continue
    if (av && bv && typeof av === "object" && typeof bv === "object") {
      if (JSON.stringify(av) !== JSON.stringify(bv)) return false
      continue
    }
    return false
  }
  return true
}

// Updates a QML ListModel in place to match `newRows` (a flattenGroups()
// array, each row keyed by its stable `id` — a txn id, a transfer's
// "a>b" transferId, or "self:<id>" for a one-sided transfer), instead of
// replacing the model wholesale. Each ListModel element holds the row
// under a single "modelData" role, so the existing txnList delegate
// (`required property var modelData`) binds to it exactly like it did to
// a plain-array model — this only changes how updates are applied.
//
// Walks old and new in lockstep: rows with matching ids at the same
// position only get `.set()` when their content actually changed (no
// delegate destroy/recreate, just a property rebind); a dropped id gets
// `.remove()`; a new id gets `.insert()`. This is not a minimal diff for
// heavy reordering, but tracking/filtering/renaming/etc. mostly inserts,
// removes or updates rows in place without reordering survivors, which is
// exactly what this is cheap for.
function syncFlatRowsModel(listModel, newRows) {
  var newIds = {}
  for (var n = 0; n < newRows.length; n++) newIds[newRows[n].id] = true

  var i = 0, j = 0
  while (j < newRows.length) {
    if (i < listModel.count) {
      var oldRow = listModel.get(i).modelData
      var newRow = newRows[j]
      if (oldRow.id === newRow.id) {
        if (!_flatRowEqual(oldRow, newRow)) listModel.set(i, { modelData: newRow })
        i++; j++
      } else if (!newIds.hasOwnProperty(oldRow.id)) {
        listModel.remove(i)
        // i stays put (next old row shifts into position i); j unchanged.
      } else {
        listModel.insert(i, { modelData: newRow })
        i++; j++
      }
    } else {
      listModel.append({ modelData: newRows[j] })
      j++
    }
  }
  while (listModel.count > i) listModel.remove(i)
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
  var bp = billParts(overviewEntry)
  return bp.payNow <= 0 || bp.awaiting
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

// When the bill closes next, worked out from the billing day each time it is
// asked, not at fetch time (txdb's statementDate freezes when the fetch ran,
// so a card not fetched since its closing day kept showing the old date).
// Returns { known, closesOn (YYYY-MM-DD), days, today } - `today` is true on
// the closing day itself, when the spend is about to become a bill.
function cycleClose(overviewEntry) {
  var day = overviewEntry && Number(overviewEntry.billingDay)
  if (!day) return { known: false, closesOn: "", days: 0, today: false }
  var now = new Date()
  var t = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  function on(y, mo) { return new Date(y, mo, Math.min(day, new Date(y, mo + 1, 0).getDate())) }
  function iso(d) { return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2) }
  var next = on(t.getFullYear(), t.getMonth())
  if (next < t) next = on(t.getFullYear(), t.getMonth() + 1)
  // The closing day itself is still "next": the bill is made later that day.
  var prev = on(next.getFullYear(), next.getMonth() - 1)
  return { known: true, closesOn: iso(next), lastClosed: iso(prev), days: Math.round((next - t) / 86400000), today: next.getTime() === t.getTime() }
}

// "bill closes 12 Dec · 30 days left" / "bill closes today" / "".
function cycleCloseLine(overviewEntry) {
  var c = cycleClose(overviewEntry)
  if (!c.known) return ""
  if (c.today) return "bill closes today"
  return "bill closes " + formatShortDate(c.closesOn) + "  ·  " + (c.days === 1 ? "tomorrow" : c.days + " days left")
}

// Most urgent first: a bill to pay (soonest due date first), then the card
// with the biggest running spend.
function billOrder(a, b) {
  var pa = billParts(a), pb = billParts(b)
  var da = pa.payNow > 0, db = pb.payNow > 0
  if (da !== db) return da ? -1 : 1
  if (da) {
    var x = a.dueDate || "9999", y = b.dueDate || "9999"
    if (x !== y) return x < y ? -1 : 1
  }
  if (pb.nextBill !== pa.nextBill) return pb.nextBill - pa.nextBill
  return String(a.last4).localeCompare(String(b.last4))
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
    return { billThisMonth: 0, paidIn: 0, payNow: 0, nextBill: 0, inCredit: false, hasBreakdown: false, awaiting: false, awaitingAmount: 0, awaitingDate: "" }
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
  // A bank page that does not report credits (SBI) can keep asking for a
  // bill that was paid. The widget never clears it on its own: it waits for
  // the bank's page to say so (user's choice, 2026-11-12). It only notes
  // that a payment covering the bill is in the card's transactions
  // ("awaiting"). The bank rounds a bill up to the rupee (588.82 shown as
  // 589.00), hence the 1 rupee slack.
  var paidSince = Number(overviewEntry.paidSinceBill) || 0
  var awaiting = !overviewEntry.unbilled_credits && payNow > 0 && paidSince > 0 && paidSince + 1 >= payNow

  return {
    billThisMonth: hasBreakdown ? _money(parseCurrencyString(overviewEntry.last_statement_amount)) : 0,
    // The page shows credits as a negative ("- ₹3,779.00"); this is the
    // money already sitting in the card, so it reads positive here.
    paidIn: hasBreakdown ? Math.abs(_money(parseCurrencyString(overviewEntry.unbilled_credits))) : 0,
    payNow: payNow,
    nextBill: nextBill,
    inCredit: payNow < 0,
    hasBreakdown: hasBreakdown,
    awaiting: awaiting,
    awaitingAmount: awaiting ? _money(paidSince) : 0,
    awaitingDate: awaiting ? (overviewEntry.paidSinceDate || "") : ""
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
    var bp = billParts(entry)
    if (bp.payNow > 0 && !bp.awaiting) total += bp.payNow
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

// The tax as the bill prints it, one editable row per figure:
// "CGST (2.5%)" 8.52 - CGST/SGST each carry half the slab rate, IGST and
// cess the whole of it. `rate` is the slab (what the database addresses).
// A slab with no rate shows no rate at all (nothing is guessed from the
// figures); a bill with one lump "Taxes" figure and no slabs gets one row
// with field "tax".
function receiptTaxRows(r) {
  var rows = []
  ;(r.taxes || []).forEach(function (t) {
    ;[["cgst", "CGST", 2], ["sgst", "SGST", 2], ["igst", "IGST", 1], ["cess", "CESS", 1]].forEach(function (p) {
      if (t[p[0]] == null || t[p[0]] === 0) return
      var shown = Math.round((t.rate || 0) / p[2] * 100) / 100
      rows.push({ rate: t.rate, field: p[0], label: p[1] + (shown ? " (" + shown + "%)" : ""), value: t[p[0]] })
    })
  })
  if (!rows.length && r.tax) rows.push({ rate: null, field: "tax", label: "Taxes", value: r.tax })
  return rows
}

// Total tax printed on the bill, from the slabs.
function receiptTaxSum(r) {
  var slabs = (r.taxes || []).reduce(function (m, t) {
    return m + (t.cgst || 0) + (t.sgst || 0) + (t.igst || 0) + (t.cess || 0)
  }, 0)
  return slabs > 0 ? slabs : (r.tax || 0)
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
  return (r.fees || []).reduce(function (m, f) { return m + (f.waived ? 0 : (f.amount || 0)) }, 0)
}

// What the bill says was paid: the printed total, and for older reads that
// have none, the stored total.
function receiptPrinted(r) {
  return r.printedTotal != null ? r.printedTotal : (r.total != null ? r.total : null)
}

function receiptTaxMode(r) {
  var tax = receiptTaxSum(r), printed = receiptPrinted(r)
  if (!(tax > 0) || printed == null || r.subtotal == null) return "inside"
  if ((r.items || []).length && Math.abs(receiptItemsSum(r) - tax - r.subtotal) <= 0.5) return "inclusive"
  // what the printed total holds beyond subtotal - discount + round off + charges
  if (printed - (r.subtotal - Math.abs(r.discount || 0) + (r.roundOff || 0)) - receiptFeesSum(r) > tax / 2) return "on-top"
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
  var src = m.date_source
  add("Date used", src === "taken" ? "photo taken date" : src === "modified" ? "file modified date"
    : src === "printed" ? "printed on the bill (photo has no date)" : "")
  add("Bill time", m.time)
  if (m.printed_date && m.printed_date !== r.date) add("Printed on the bill", m.printed_date)
  if (m.printed_time && m.printed_time !== m.time) add("Printed time", m.printed_time)
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

function _money2(x) { return Math.round(x * 100) / 100 }

// The bill's parts against what it says was paid (the printed total):
//   computed = item total - |discount| + charges + tax +/- round off
// `charges` carry the struck-through original and the waived flag (a waived
// charge adds 0). Tax counts, except for a bill whose item prices already
// hold it (then the parts match without it, `taxIncluded`). `gap` is
// printed - computed; `ok` needs a printed total and |gap| within
// max(1, |round off| + 0.5).
function receiptParts(r) {
  var items = r.items || []
  var itemTotal = r.subtotal != null ? r.subtotal : (items.length ? receiptItemsSum(r) : 0)
  var discount = Math.abs(r.discount || 0), roundOff = r.roundOff || 0
  var tax = receiptTaxSum(r), fees = receiptFeesSum(r)
  var printed = receiptPrinted(r)
  var tol = Math.max(1, Math.abs(roundOff) + 0.5)
  var computed = _money2(itemTotal - discount + fees + tax + roundOff)
  var taxIncluded = false
  if (printed != null && tax > 0 && Math.abs(computed - printed) > tol && Math.abs(computed - tax - printed) <= tol) {
    computed = _money2(computed - tax)
    taxIncluded = true
  }
  var gap = printed == null ? null : _money2(printed - computed)
  return {
    itemTotal: itemTotal,
    charges: (r.fees || []).map(function (f) {
      return { label: f.label, amount: f.waived ? 0 : (f.amount || 0), original: f.original == null ? null : f.original, waived: !!f.waived }
    }),
    discount: discount, tax: tax, taxIncluded: taxIncluded, roundOff: roundOff,
    computed: computed, printed: printed, gap: gap,
    ok: printed != null && Math.abs(gap) <= tol
  }
}

// The quiet line under the printed total.
function receiptCheckLine(r) {
  var p = receiptParts(r)
  if (p.printed == null) return "No total printed on the bill"
  var sym = currencySymbol(r.currency)
  if (p.ok) {
    return "Parts add to " + sym + p.computed.toFixed(2) + (p.gap !== 0 ? " · round off " + sym + Math.abs(p.gap).toFixed(2) : "")
  }
  if (p.gap > 0) return sym + p.gap.toFixed(2) + " not explained: add a charge or a tax"
  return "Parts add to " + sym + p.computed.toFixed(2) + ", " + sym + Math.abs(p.gap).toFixed(2) + " more than the bill says"
}

// Parser warnings plus more computed here: items that don't add up to
// the printed subtotal/total, and parts that don't add up to the printed
// total (the same check the Python referee makes), kept visible in the UI
// even if the parser's own list didn't catch it, and re-run live after
// every hand edit.
function receiptWarnings(r) {
  var out = (r.warnings || []).slice()
  var items = r.items || []
  var printed = receiptPrinted(r)
  if (items.length) {
    var sum = receiptItemsSum(r)
    var target = r.subtotal != null ? r.subtotal : printed
    // Item prices may already include GST: then they add up to the subtotal
    // plus the tax, or to the grand total, instead of to the subtotal.
    var taxIn = receiptTaxSum(r)
    var inclusiveOk = r.subtotal != null && ((taxIn > 0 && Math.abs(sum - (r.subtotal + taxIn)) <= 0.5)
      || (taxIn > 0 && printed != null && Math.abs(sum - printed) <= 0.5))
    if (target != null && Math.abs(sum - target) > 0.5 && !inclusiveOk) {
      out.push("items add up to " + sum.toFixed(2) + ", the bill says " + target.toFixed(2))
    }
  }
  if (printed != null && (r.subtotal != null || r.printedTotal != null)) {
    var p = receiptParts(r)
    if (!p.ok) {
      out.push("subtotal " + p.itemTotal.toFixed(2) + " - discount " + p.discount.toFixed(2) +
              " + round-off " + p.roundOff.toFixed(2) + (receiptFeesSum(r) > 0 ? " + fees " + receiptFeesSum(r).toFixed(2) : "") +
              (p.tax > 0 && !p.taxIncluded ? " + tax " + p.tax.toFixed(2) : "") +
              " = " + p.computed.toFixed(2) + ", not the total " + printed.toFixed(2))
    }
  }
  return out
}

// True when the bill's own arithmetic holds: a printed total exists, no
// parser warning is left, and the live checks in receiptWarnings agree, so a
// hand edit that breaks them turns this false again at once.
function receiptIsBalanced(r) {
  return receiptPrinted(r) != null && receiptWarnings(r).length === 0
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

// --- Transfer kinds and the "i" explain panel -------------------------------

var _INFO_GLYPH = "󰋽"
var _TRANSFER_META = {
  ref:     { glyph: "󰌷", tag: "SAME REFERENCE", pips: 3, tone: "accent", certainty: "very sure" },
  card:    { glyph: "󰿯", tag: "CARD BILL", pips: 2, tone: "accent", certainty: "sure" },
  self:    { glyph: "󰓢", tag: "OWN NAME", pips: 2, tone: "accent", certainty: "fairly sure" },
  missing: { glyph: "󰋗", tag: "ONE SIDE MISSING", pips: 1, tone: "amber", certainty: "a guess" },
  lone:    { glyph: "󰌷", tag: "ONE LEG SHOWN", pips: 0, tone: "dim", certainty: "" }
}

// "ref" | "card" | "self" | "missing" | "lone" | "" for a collapsed entry or a transaction.
function transferKind(x) {
  if (!x) return ""
  if (x.isTransfer) {
    if (x.oneSided) return "missing"
    return x.matchedBy === "card" ? "card" : (x.matchedBy === "self" ? "self" : "ref")
  }
  if (x.transferId) return "lone"
  if (x.transferSelf) return "missing"
  return ""
}

function transferMeta(kind) { return _TRANSFER_META[kind] || null }

// "124028795174" -> "1240 2879 5174"
function groupRef(ref) {
  return String(ref || "").replace(/\s+/g, "").replace(/(.{4})(?=.)/g, "$1 ")
}

// "2026-11-08T10:00:00" -> "8 Nov 2026"; "" when unknown.
function formatMatchedOn(iso) {
  if (!iso) return ""
  return formatShortDate(String(iso).slice(0, 10), true)
}

function _legRow(k, leg) {
  return { k: k, v: formatShortDate(leg.date, true) + "  " + (leg.bank || "") + "  " + formatAmount(leg) }
}

// Texts for the "i" panel of a transfer (entry from collapseTransfers, or a lone-leg
// transaction). ctx: { lastFetched: {BANK: iso}, accountTag }.
function transferExplain(x, ctx) {
  ctx = ctx || {}
  var kind = transferKind(x)
  var meta = _TRANSFER_META[kind]
  if (!meta) return null
  var res = { kind: kind, title: meta.tag, glyph: meta.glyph, certainty: meta.certainty, rows: [], why: "", next: "" }
  var rows = res.rows
  if (kind === "lone") {
    var peer = x.transferPeerBank
    rows.push({ k: "Other side", v: peer || "another account" })
    if (ctx.accountTag) rows.push({ k: "This side", v: ctx.accountTag })
    res.why = "The other side is hidden by a filter. Clear the filter to see both sides."
    return res
  }
  var matchedOn = formatMatchedOn(x.matchedAt)
  if (kind === "missing") {
    var real = x.real || x
    var ghost = x.out && x.out.ghost ? x.out : (x.in && x.in.ghost ? x.in : null)
    var bank = String((ghost ? ghost.bank : real.transferOther) || "").toUpperCase()
    var amt = formatAmount({ amount: -real.amount, currency: real.currency })
    rows.push({ k: "Matched by", v: "your own name on this side only" })
    rows.push({ k: "Missing", v: (bank ? bank + " side" : "Another account") + " (" + amt + " around "
                                  + formatShortDate(real.date, true) + ")" })
    var fetched = bank && ctx.lastFetched ? ctx.lastFetched[bank] : ""
    res.why = "The other account is not in your data."
    if (bank) res.why += " " + bank + " was last fetched " + (fetched ? formatShortDate(String(fetched).slice(0, 10), true) : "never") + "."
    if (bank && fetched && String(fetched).slice(0, 10) > real.date)
      res.next = "That fetch did not include this transfer. It may be older than the statement."
    else
      res.next = (bank ? "Fetch " + bank : "Fetch the other account") + " again. This will pair by itself."
    return res
  }
  if (kind === "ref") rows.push({ k: "Matched by", v: "UPI reference " + groupRef(x.ref) })
  else if (kind === "card") rows.push({ k: "Matched by", v: "amount, date and payment words" })
  else rows.push({ k: "Matched by", v: "your name, same amount, 1 day or less, banks agree" })
  if (matchedOn) rows.push({ k: "Matched on", v: matchedOn })
  rows.push(_legRow("OUT", x.out))
  rows.push(_legRow("IN", x.in))
  res.why = kind === "ref" ? "Both sides carry the same UPI reference."
    : (kind === "card" ? "A bank account paid your credit card."
    : "No shared reference exists. Your own name and the amount match.")
  return res
}

// Texts for the "i" panel of an ordinary transaction.
// ctx: { accountTag, receiptMerchant }
function txnExplain(t, ctx) {
  ctx = ctx || {}
  var rows = []
  rows.push({ k: "Counterparty", v: t.counterparty || t.merchant })
  rows.push({ k: "Account", v: [ctx.accountTag, t.accountType === "credit" ? "credit card" : "savings"]
                              .filter(function (s) { return s }).join("  ") })
  var note = transactionNote(t)
  if (note) rows.push({ k: "Remark", v: note })
  rows.push({ k: "Statement", v: t.merchant })
  if (t.reference) rows.push({ k: "Reference", v: groupRef(t.reference) })
  rows.push({ k: "Status", v: (t.tracked ? "Tracked" : "Not tracked")
                              + (ctx.receiptMerchant ? "  Receipt: " + ctx.receiptMerchant : "") })
  return { kind: "", title: "Transaction", glyph: _INFO_GLYPH, certainty: "", rows: rows, why: "", next: "" }
}

// --- RECENT filter ------------------------------------------------------------
//
// One plain object describes every filter on RECENT, so the panel, the
// summary chips and the saved file all work from the same shape:
//   q          search text (name, raw merchant, counterparty, note); never saved
//   accounts   account keys (accountKey); empty = all accounts
//   dir        "any" | "in" | "out"
//   tracked    "any" | "tracked" | "untracked"
//   transfers  "any" | "only" | "hide"
//   bill       "any" | "has" | "none"   (has / has no linked receipt)
//   min, max   bounds on |amount| in RUPEES (t.amount is rupees, see
//              formatAmount: no division by 100), or null; inclusive
//   month      "" (all) | "YYYY-MM" | "30d"; never saved
// Pure functions only, so tests/test_filter_js.py can run them under node.

function defaultFilter() {
  return { q: "", accounts: [], dir: "any", tracked: "any", transfers: "any", bill: "any", min: null, max: null, month: "" }
}

function _pad2(n) { return (n < 10 ? "0" : "") + n }

// Today as local "YYYY-MM-DD" (bank dates are local dates, so local time).
function todayIso() {
  var d = new Date()
  return d.getFullYear() + "-" + _pad2(d.getMonth() + 1) + "-" + _pad2(d.getDate())
}

// ISO date `days` before `iso` (calendar arithmetic in UTC, so no DST drift).
function _isoMinusDays(iso, days) {
  var p = iso.split("-")
  var d = new Date(Date.UTC(Number(p[0]), Number(p[1]) - 1, Number(p[2])))
  d.setUTCDate(d.getUTCDate() - days)
  return d.getUTCFullYear() + "-" + _pad2(d.getUTCMonth() + 1) + "-" + _pad2(d.getUTCDate())
}

var _YM_RE = /^\d{4}-(0[1-9]|1[0-2])$/

// "2026-11" moved by `delta` months. "" for anything that is not "YYYY-MM"
// (for example "30d"), so a bad value never becomes "NaN-NaN".
function shiftMonth(ym, delta) {
  if (!_YM_RE.test(ym || "")) return ""
  var p = ym.split("-")
  var idx = Number(p[0]) * 12 + (Number(p[1]) - 1) + delta
  return Math.floor(idx / 12) + "-" + _pad2((idx % 12) + 1)
}

function monthLabel(ym) {
  if (!_YM_RE.test(ym || "")) return ""
  var p = ym.split("-")
  return _MONTH_NAMES[Number(p[1]) - 1] + " " + p[0]
}

function _isTransferRow(t) { return !!(t.transferId || t.transferSelf) }

// Lower-case and strip accents, so "cafe" finds "Café".
function _fold(s) {
  s = String(s === null || s === undefined ? "" : s).toLowerCase()
  if (typeof s.normalize === "function") s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  return s
}

// Search text per row, built once and kept between calls: typing a search
// re-runs the filter on every pause, and the display name / note parsing is
// regex work. Entry = { m, c, n, hay }; rebuilt when the raw fields change,
// and the whole cache is dropped when the rename map is replaced.
var _hayCache = {}
var _hayCount = 0
var _hayOverrides = null

function _haystack(t, overrides) {
  if (overrides !== _hayOverrides || _hayCount > 60000) {
    _hayCache = {}
    _hayCount = 0
    _hayOverrides = overrides
  }
  var e = _hayCache[t.id]
  if (e && e.m === t.merchant && e.c === t.counterparty && e.n === t.note) return e.hay
  var name = "", note = ""
  try { name = transactionDisplayName(t, overrides) } catch (x) { name = t.counterparty || "" }
  try { note = transactionNote(t) } catch (y) { note = "" }
  var hay = _fold([name, t.merchant, t.counterparty, note].join("\n"))
  if (!e) _hayCount++
  _hayCache[t.id] = { m: t.merchant, c: t.counterparty, n: t.note, hay: hay }
  return hay
}

// id -> row, kept for the last `rows` array: the panel passes the same array
// on every filter change, so the map is built once per data refresh.
var _idRows = null
var _idMapCache = null
function _idMap(rows) {
  if (rows === _idRows && _idMapCache && _idCount === rows.length) return _idMapCache
  var map = {}
  for (var r = 0; r < rows.length; r++) map[rows[r].id] = rows[r]
  _idRows = rows
  _idMapCache = map
  _idCount = rows.length
  return map
}
var _idCount = 0

// ctx: { nameOverrides, linkedIds (txn id -> true), today (ISO, for tests) }
// A transfer belongs to BOTH accounts it moved money between: filtering to
// Axis keeps the HDFC side of an HDFC -> Axis transfer too, so the pair
// still folds into one card instead of leaving a lone half that looks like
// income. Its peer is found through the transferId "a>b" (ids of the two
// legs) in a lookup map that is built only when an account is selected.
function filterTransactions(rows, f, ctx) {
  ctx = ctx || {}
  var nAcc = f.accounts.length
  var acct = null, byId = null
  if (nAcc) {
    acct = {}
    for (var a = 0; a < nAcc; a++) acct[f.accounts[a]] = true
    byId = _idMap(rows)
  }
  var tokens = _fold((f.q || "")).split(/\s+/).filter(function (w) { return w !== "" })
  var nTok = tokens.length
  var today = ctx.today || todayIso()
  var since = f.month === "30d" ? _isoMinusDays(today, 29) : ""
  var ym = f.month === "30d" ? "" : (f.month || "")
  var linked = ctx.linkedIds || {}
  var hasMin = f.min !== null && f.min !== undefined
  var hasMax = f.max !== null && f.max !== undefined
  var dirIn = f.dir === "in", dirOut = f.dir === "out"
  var trackedWant = f.tracked === "any" ? null : f.tracked === "tracked"
  var transfersWant = f.transfers === "any" ? null : f.transfers === "only"
  var billWant = f.bill === "any" ? null : f.bill === "has"
  var out = []
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i]
    if (nAcc && !acct[t.bank + "|" + t.accountType + "|" + t.last4]) {
      if (!t.transferId) continue
      var ids = t.transferId.split(">")
      var peer = byId[ids[0] === t.id ? ids[1] : ids[0]]
      if (!peer || !acct[peer.bank + "|" + peer.accountType + "|" + peer.last4]) continue
    }
    if (dirIn && !(t.amount > 0)) continue
    if (dirOut && !(t.amount < 0)) continue
    if (trackedWant !== null && trackedWant !== !!t.tracked) continue
    if (transfersWant !== null && transfersWant !== _isTransferRow(t)) continue
    if (billWant !== null && billWant !== !!linked[t.id]) continue
    if (hasMin || hasMax) {
      var abs = Math.abs(Number(t.amount))
      if (abs !== abs) continue               // NaN amount: never inside a range
      if (hasMin && abs < f.min) continue
      if (hasMax && abs > f.max) continue
    }
    var date = t.date || ""
    if (since && date < since) continue
    if (ym && date.slice(0, 7) !== ym) continue
    if (nTok) {
      var hay = _haystack(t, ctx.nameOverrides)
      var ok = true
      for (var k = 0; k < nTok; k++) if (hay.indexOf(tokens[k]) === -1) { ok = false; break }
      if (!ok) continue
    }
    out.push(t)
  }
  return out
}

// Sensible limits for the amount fields and month stepper, from the data.
// max rounds UP to the next 1,000 (57,614 -> 58,000).
function filterBounds(rows) {
  var max = 0, first = "", last = ""
  for (var i = 0; i < rows.length; i++) {
    var t = rows[i]
    var a = Math.abs(Number(t.amount))
    if (a > max) max = a
    var m = (t.date || "").slice(0, 7)
    if (m && (!first || m < first || m > last) && _YM_RE.test(m)) {
      if (!first || m < first) first = m
      if (m > last) last = m
    }
  }
  return { min: 0, max: Math.ceil(max / 1000) * 1000, firstMonth: first, lastMonth: last }
}

function _amountText(n) { return formatGrouped(n) }

// One entry per active part, in display order: { id, label }. Ids:
// "q", "acct:<key>", "dir", "tracked", "transfers", "bill", "min", "max", "month".
function activeFilterChips(f, options) {
  var chips = []
  if (f.q) chips.push({ id: "q", label: "“" + f.q + "”" })
  f.accounts.forEach(function (key) {
    var label = key
    for (var i = 0; i < (options || []).length; i++) {
      var o = options[i]
      // A bank account's label is just "••9373"; the chip needs the bank too.
      if (o.key === key) label = (o.accountType === "checking" && o.bank ? o.bank + " " : "") + o.label
    }
    chips.push({ id: "acct:" + key, label: label })
  })
  if (f.dir === "in") chips.push({ id: "dir", label: "In" })
  if (f.dir === "out") chips.push({ id: "dir", label: "Out" })
  if (f.tracked !== "any") chips.push({ id: "tracked", label: f.tracked === "tracked" ? "Tracked" : "Not tracked" })
  if (f.transfers !== "any") chips.push({ id: "transfers", label: f.transfers === "only" ? "Transfers only" : "No transfers" })
  if (f.bill !== "any") chips.push({ id: "bill", label: f.bill === "has" ? "Has bill" : "No bill" })
  if (f.min !== null && f.min !== undefined && f.min > 0) chips.push({ id: "min", label: "≥ " + _amountText(f.min) })
  if (f.max !== null && f.max !== undefined) chips.push({ id: "max", label: "≤ " + _amountText(f.max) })
  if (f.month === "30d") chips.push({ id: "month", label: "Last 30 days" })
  else if (f.month) chips.push({ id: "month", label: monthLabel(f.month) })
  return chips
}

// A copy of `f` with the part named by a chip id reset.
function removeFilterPart(f, id) {
  var n = JSON.parse(JSON.stringify(f))
  if (id === "q") n.q = ""
  else if (id.indexOf("acct:") === 0) {
    var key = id.slice(5)
    n.accounts = n.accounts.filter(function (k) { return k !== key })
  }
  else if (id === "dir") n.dir = "any"
  else if (id === "tracked") n.tracked = "any"
  else if (id === "transfers") n.transfers = "any"
  else if (id === "bill") n.bill = "any"
  else if (id === "min") n.min = null
  else if (id === "max") n.max = null
  else if (id === "month") n.month = ""
  return n
}

// How many parts besides the search text are active (the Filter button's count).
function countActive(f) {
  return activeFilterChips(f, []).filter(function (c) { return c.id !== "q" }).length
}

var _MAX_AMOUNT = 1e12

// "5k" -> 5000, "1.2L" -> 120000, "2cr" -> 20000000, "1.5m" -> 1500000, "1,200" -> 1200.
// null for empty, negative or unreadable text.
function parseAmountInput(s) {
  var text = String(s === null || s === undefined ? "" : s).replace(/[,\s₹]/g, "").toLowerCase()
  if (text === "") return null
  var m = /^(\d+(?:\.\d*)?|\.\d+)(k|l|lac|lakh|cr|crore|m)?$/.exec(text)
  if (!m) return null
  var mult = { k: 1e3, l: 1e5, lac: 1e5, lakh: 1e5, cr: 1e7, crore: 1e7, m: 1e6 }[m[2] || ""] || 1
  var value = Math.round(Number(m[1]) * mult * 100) / 100
  return value <= _MAX_AMOUNT ? value : null
}

// What is saved between restarts: never the search text or the month.
function serializeFilter(f) {
  return JSON.stringify({
    accounts: f.accounts.slice().sort(), dir: f.dir, tracked: f.tracked,
    transfers: f.transfers, bill: f.bill, min: f.min, max: f.max
  })
}

function restoreFilter(json, options) {
  var f = defaultFilter()
  var data
  try { data = JSON.parse(json) } catch (e) { return f }
  if (!data || typeof data !== "object") return f
  var known = {}
  ;(options || []).forEach(function (o) { known[o.key] = true })
  if (Array.isArray(data.accounts)) {
    f.accounts = data.accounts.filter(function (k) { return typeof k === "string" && known[k] })
  }
  if (["in", "out"].indexOf(data.dir) !== -1) f.dir = data.dir
  if (["tracked", "untracked"].indexOf(data.tracked) !== -1) f.tracked = data.tracked
  if (["only", "hide"].indexOf(data.transfers) !== -1) f.transfers = data.transfers
  if (["has", "none"].indexOf(data.bill) !== -1) f.bill = data.bill
  ;["min", "max"].forEach(function (k) {
    var v = data[k]
    if (typeof v === "number" && isFinite(v) && v > 0 && v <= _MAX_AMOUNT) f[k] = v
  })
  return f
}

// ---------------------------------------------------------------- Cashew
// Pure helpers for the Cashew verify window. Drafts come from
// `txdb cashew-draft`; every function returns a NEW array or object so the
// window replaces its property once per edit.

// Main categories the picker offers for an amount string: income ones for a
// credit, expense ones for a debit; "balance" types (Balance Correction,
// Uncategorized) always.
function cashewCategoriesFor(categories, amount) {
  var debit = String(amount || "").charAt(0) === "-"
  return (categories || []).filter(function (c) {
    return c.type === "balance" || c.type === (debit ? "expense" : "income")
  })
}

function cashewIsDebit(d) { return String(d.amount || "").charAt(0) === "-" }

// New array with draft `idx` merged with `patch`.
function cashewPatch(drafts, idx, patch) {
  if (idx < 0 || idx >= drafts.length) return drafts
  var out = drafts.slice()
  out[idx] = Object.assign({}, drafts[idx], patch)
  return out
}

// The same merchant (group key) and direction as drafts[idx], transfers excluded.
function _cashewSameMerchant(a, b) {
  return !!a.groupKey && a.groupKey === b.groupKey && a.kind === b.kind && a.kind !== "transfer"
}

// Sets the category on drafts[idx]; with `spread`, on every other draft of
// the same merchant and direction too.
function cashewApplyCategory(drafts, idx, category, subcategory, spread) {
  if (idx < 0 || idx >= drafts.length) return drafts
  var src = drafts[idx]
  return drafts.map(function (d, i) {
    if (i === idx || (spread && _cashewSameMerchant(src, d)))
      return Object.assign({}, d, { category: category, subcategory: subcategory, touched: true, guessed: false })
    return d
  })
}

// A row that still has no category: not a transfer, and the category is
// Uncategorized (or empty) or the draft carries a warning.
function cashewNeedsCategory(d) {
  if (!d || d.kind === "transfer") return false
  return !d.category || d.category === "Uncategorized" || (d.warn || "") !== ""
}

// Indexes (into drafts) of the shown rows that still need a category.
function cashewNeedIdxs(drafts, shown) {
  var out = []
  for (var k = 0; k < shown.length; k++) if (cashewNeedsCategory(drafts[shown[k]])) out.push(shown[k])
  return out
}

// The rows `cashew-guess` reads: no category yet, and at least ONE of
// title/merchant/notes has real text for the model to reason from (empty
// string on all three means there is nothing to send - no clue at all). A
// row with a category from any source, a transfer, a row edited by hand and
// a row already guessed are never sent. The rest is asked from the user.
// cashew_guess.py's own prompt already treats merchant text, the UPI remark
// and notes as three separate clues ("Use the merchant text, the UPI remark
// and the notes as clues") - requiring notes specifically used to exclude
// every row with a real merchant name but no UPI remark (most non-UPI card/
// bank-fee rows, which is why "needs category" could show rows while the AI
// button stayed disabled: none of them happened to have a note).
// `groupKey` rides along (same identity as the UPI-rename feature, Model.
// transactionGroupKey) so the grouping functions below can tell which rows
// are really the same UPI counterparty asked N times.
function cashewGuessRows(drafts, shown) {
  var out = []
  for (var k = 0; k < shown.length; k++) {
    var d = drafts[shown[k]]
    if (!d || d.touched || d.guessed || !cashewNeedsCategory(d)) continue
    var title = String(d.title || "").trim()
    var merchant = String(d.merchant || "").trim()
    var note = String(d.notes || "").trim()
    if (title === "" && merchant === "" && note === "") continue
    out.push({ id: d.id, title: title, merchant: merchant, notes: note,
               amount: d.amount || "", kind: d.kind || "", bank: d.bank || "", accountType: d.accountId ? String(d.accountId).split("|")[1] || "" : "",
               groupKey: d.groupKey || "" })
  }
  return out
}

// Groups `cashewGuessRows` output by UPI counterparty ("if it is just the
// UPI id" - the user's own framing): rows whose groupKey is a UPI identity
// (the same "UPI|BANK|NAME" key the rename feature uses, see Model.
// transactionGroupKey / txdb/keys.py) and share that key become one group.
// Anything else - card transactions, bank fees, a lone UPI counterparty with
// only one untracked row right now - gets its own group of 1, so singletons
// behave exactly as before (no grouping chrome, no change in flow).
function cashewGuessGroups(rows) {
  var byKey = {}, out = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    var upi = !!r.groupKey && r.groupKey.indexOf("UPI|") === 0
    var key = upi ? r.groupKey : ("row:" + r.id)
    var g = byKey[key]
    if (!g) { g = { key: key, upi: upi, rows: [] }; byKey[key] = g; out.push(g) }
    g.rows.push(r)
  }
  return out
}

// The one row that represents a whole group when asking the model - the
// member with the richest note, so the AI sees the most informative text for
// what is really one question asked about N transactions.
function cashewGuessGroupRep(g) {
  var rep = g.rows[0]
  for (var i = 1; i < g.rows.length; i++) {
    if (String(g.rows[i].notes || "").length > String(rep.notes || "").length) rep = g.rows[i]
  }
  return rep
}

// What actually gets sent to cashew-guess: one row per group instead of one
// per transaction, so a UPI counterparty with several untracked transactions
// is asked about once, not N times.
function cashewGuessRequestRows(groups) {
  return groups.map(cashewGuessGroupRep)
}

// Representative transaction id -> every member id of its group (itself
// included), so a result keyed by the representative's id can be copied onto
// every transaction it stands in for.
function cashewGuessGroupMap(groups) {
  var m = {}
  groups.forEach(function (g) {
    var rep = cashewGuessGroupRep(g)
    m[rep.id] = g.rows.map(function (r) { return r.id })
  })
  return m
}

// Expands the model's per-representative results into one entry per actual
// transaction id, using the map above. A result for an ungrouped row (group
// of 1) just passes through unchanged.
function cashewGuessExpandResults(results, groupMap) {
  var out = []
  for (var i = 0; i < (results || []).length; i++) {
    var r = results[i]
    if (!r) continue
    var ids = (groupMap && groupMap[r.id]) || [r.id]
    for (var j = 0; j < ids.length; j++) out.push({ id: ids[j], category: r.category, subcategory: r.subcategory })
  }
  return out
}

// The ask-me flow: the first row index after `from` (draft index, -1 = start)
// in list order that needs a category, wrapping once. `order` is the list rows
// [{idx, partner}] as shown; returns the draft index or -1.
function cashewNextNeed(drafts, order, from) {
  var start = -1, i
  if (from >= 0) for (i = 0; i < order.length; i++) if (order[i].idx === from || order[i].partner === from) { start = i; break }
  for (var n = 1; n <= order.length; n++) {
    var r = order[(start + n + order.length) % order.length]
    if (r && cashewNeedsCategory(drafts[r.idx])) return r.idx
  }
  return -1
}

// A few confirmed merchants as examples for the model (at most 20).
function cashewTaught(state) {
  var cats = (state && state.categories) || {}
  var out = {}, n = 0
  for (var k in cats) {
    if (n >= 20) break
    if (cats[k] && cats[k].category && cats[k].category !== "Uncategorized") { out[k] = cats[k]; n++ }
  }
  return out
}

// New array with the guesses applied: [{id, category, subcategory}]. An
// empty category is "no guess"; a row the user edited meanwhile is kept.
function cashewApplyGuesses(drafts, results) {
  var byId = {}
  for (var i = 0; i < results.length; i++) if (results[i] && results[i].category) byId[results[i].id] = results[i]
  var changed = false
  var out = drafts.map(function (d) {
    var g = byId[d.id]
    if (!g || d.touched) return d
    changed = true
    return Object.assign({}, d, { category: g.category, subcategory: g.subcategory || "", guessed: true, warn: "" })
  })
  return changed ? out : drafts
}

// {drafts, state}: every guessed draft remembered for its merchant, mark cleared.
function cashewAcceptGuesses(drafts, state) {
  var st = state
  var out = drafts.map(function (d) {
    if (!d.guessed) return d
    st = cashewRememberCategory(st, d.groupKey, d.category, d.subcategory)
    return Object.assign({}, d, { guessed: false })
  })
  return { drafts: out, state: st }
}

function cashewGuessedCount(drafts) {
  var n = 0
  for (var i = 0; i < drafts.length; i++) if (drafts[i].guessed) n++
  return n
}

// ---- guess results log: one entry per row sent to the model.
// state: pending | guessed | no-guess | skipped-touched | accepted | reverted
function _cashewById(drafts) {
  var m = {}
  for (var i = 0; i < drafts.length; i++) m[drafts[i].id] = i
  return m
}

// A new log for the rows being sent; `before` is the draft as it is now. One
// entry per actual transaction (not per group/request row sent to the
// model) - the log is the record of what happened to every real row, so
// accept/revert/display stay correct per transaction even when several of
// them were asked about together. `groupKey` rides along so the results UI
// can tell which entries are the same UPI counterparty.
function cashewGuessLogNew(rows, drafts) {
  var at = _cashewById(drafts)
  return rows.map(function (r) {
    var d = drafts[at[r.id]] || ({})
    return { id: r.id, title: d.title || r.title || "", amount: d.amount || r.amount || "",
             groupKey: r.groupKey || "",
             before: { category: d.category || "", subcategory: d.subcategory || "", warn: d.warn || "" },
             sent: true, guess: null, state: "pending" }
  })
}

// Settles the pending entries a batch answered. Call it BEFORE the drafts
// get the guesses: a row touched by the user until now is skipped.
function cashewGuessLogApply(log, drafts, results) {
  var byId = {}
  for (var i = 0; i < results.length; i++) if (results[i]) byId[results[i].id] = results[i]
  var at = _cashewById(drafts), changed = false
  var out = log.map(function (e) {
    if (e.state !== "pending" || !byId[e.id]) return e
    var d = drafts[at[e.id]]
    var g = byId[e.id]
    changed = true
    if (d && d.touched) return Object.assign({}, e, { state: "skipped-touched" })
    if (!g.category) return Object.assign({}, e, { state: "no-guess" })
    return Object.assign({}, e, { state: "guessed", guess: { category: g.category, subcategory: g.subcategory || "" } })
  })
  return changed ? out : log
}

// The run is over: rows the model never answered have no guess.
function cashewGuessLogFinish(log) {
  var changed = false
  var out = log.map(function (e) {
    if (e.state !== "pending") return e
    changed = true
    return Object.assign({}, e, { state: "no-guess" })
  })
  return changed ? out : log
}

// The shown state of an entry: a guess the user has since edited by hand
// is "skipped-touched" too.
function _cashewGuessState(e, d) {
  if ((e.state === "guessed" || e.state === "pending") && d && d.touched && !d.guessed) return "skipped-touched"
  if (e.state === "guessed" && d && !d.guessed) return "skipped-touched"
  return e.state
}

// Ids of the entries whose draft still carries the guess.
function cashewGuessLogLive(log, drafts) {
  var at = _cashewById(drafts), ids = []
  for (var i = 0; i < log.length; i++) {
    var d = drafts[at[log[i].id]]
    if (log[i].state === "guessed" && d && d.guessed) ids.push(log[i].id)
  }
  return ids
}

// The rows of the results list. filter: "all" | "guessed" | "none". Rows
// that share a UPI counterparty (same groupKey, the rename feature's
// identity - see cashewGuessGroups above) collapse into one group card with
// `isGroup: true`, so the same question asked once for N transactions shows
// once, with "Apply to all N" / "Revert all" alongside the usual per-row
// actions (kept in `members`, for reviewing or adjusting one at a time). A
// lone UPI counterparty, or any non-UPI row, stays a plain single row -
// `isGroup: false`, `count: 1` - with no visible change.
function cashewGuessLogView(log, drafts, filter) {
  var at = _cashewById(drafts), rows = []
  for (var i = 0; i < log.length; i++) {
    var e = log[i], idx = at[e.id] === undefined ? -1 : at[e.id]
    var st = _cashewGuessState(e, drafts[idx])
    if (filter === "guessed" && !e.guess) continue
    if (filter === "none" && st !== "no-guess") continue
    rows.push({ gid: "x:" + e.id, rawId: e.id, idx: idx, title: e.title, amount: e.amount, st: st,
               beforeCat: e.before.category, beforeSub: e.before.subcategory,
               guessCat: e.guess ? e.guess.category : "", guessSub: e.guess ? e.guess.subcategory : "",
               groupKey: e.groupKey || "", isGroup: false, count: 1, members: [] })
  }
  var byKey = {}, order = [], out = []
  for (var r = 0; r < rows.length; r++) {
    var row = rows[r]
    if (row.groupKey.indexOf("UPI|") !== 0) { out.push(row); continue }
    if (!byKey[row.groupKey]) { byKey[row.groupKey] = []; order.push(row.groupKey) }
    byKey[row.groupKey].push(row)
  }
  for (var k = 0; k < order.length; k++) {
    var members = byKey[order[k]]
    if (members.length === 1) { out.push(members[0]); continue }
    var sameSt = true
    for (var si = 1; si < members.length; si++) if (members[si].st !== members[0].st) sameSt = false
    var guessCat = "", guessSub = "", sameGuess = true
    for (var gi = 0; gi < members.length; gi++) {
      if (members[gi].guessCat === "") continue
      if (guessCat === "") { guessCat = members[gi].guessCat; guessSub = members[gi].guessSub }
      else if (members[gi].guessCat !== guessCat || members[gi].guessSub !== guessSub) sameGuess = false
    }
    if (!sameGuess) { guessCat = ""; guessSub = "" }
    out.push({
      gid: "g:" + order[k], rawId: members[0].rawId, idx: members[0].idx,
      title: members[0].title, amount: members[0].amount,
      st: sameSt ? members[0].st : "mixed",
      beforeCat: members[0].beforeCat, beforeSub: members[0].beforeSub,
      guessCat: guessCat, guessSub: guessSub,
      groupKey: order[k], isGroup: true, count: members.length, members: members
    })
  }
  return out
}

function cashewGuessLogCounts(log) {
  var n = 0
  for (var i = 0; i < log.length; i++) if (log[i].guess) n++
  return { guessed: n, sent: log.length }
}

// Sets `state` on the entries in `ids` (an id list).
function cashewGuessLogMark(log, ids, state) {
  var set = {}
  ids.forEach(function (id) { set[id] = true })
  return log.map(function (e) { return set[e.id] ? Object.assign({}, e, { state: state }) : e })
}

// {drafts, state}: the guess of row `id` remembered for its merchant.
function cashewAcceptOne(drafts, state, id) {
  return cashewAcceptSome(drafts, state, [id])
}

// {drafts, state}: every guessed row in `ids` remembered for its merchant,
// mark cleared - the group-accept path ("Apply to all N") and the
// single-row path both go through this; a row in `ids` that is not (or no
// longer) guessed is left untouched, so passing a whole group's ids is
// always safe even when some members were already accepted/reverted/edited.
function cashewAcceptSome(drafts, state, ids) {
  var set = {}
  ids.forEach(function (id) { set[id] = true })
  var st = state
  var out = drafts.map(function (d) {
    if (!set[d.id] || !d.guessed) return d
    st = cashewRememberCategory(st, d.groupKey, d.category, d.subcategory)
    return Object.assign({}, d, { guessed: false })
  })
  return { drafts: out, state: st }
}

// New drafts with the guessed rows in `ids` back to what the log kept.
function cashewRevertGuesses(drafts, log, ids) {
  var set = {}, before = {}
  ids.forEach(function (id) { set[id] = true })
  log.forEach(function (e) { before[e.id] = e.before })
  return drafts.map(function (d) {
    if (!set[d.id] || !d.guessed || !before[d.id]) return d
    return Object.assign({}, d, { category: before[d.id].category, subcategory: before[d.id].subcategory,
                                  warn: before[d.id].warn || "", guessed: false })
  })
}

// Appends a raw output line; keeps the last `cap` (200).
function cashewGuessRawPush(lines, line, cap) {
  var out = lines.concat([String(line)])
  var max = cap || 200
  return out.length > max ? out.slice(out.length - max) : out
}

function cashewGuessSummary(sent, batches, seconds, model) {
  var s = sent + (sent === 1 ? " row" : " rows") + " in " + batches + (batches === 1 ? " batch" : " batches")
  s += seconds > 0 ? " \u00b7 " + Math.round(seconds) + " s" : " \u00b7 running"
  if (model) s += " \u00b7 " + model
  return s
}

// Sets the account name on drafts[idx]; with `spread`, on every draft of the
// same bank account.
function cashewApplyAccount(drafts, idx, name, spread) {
  if (idx < 0 || idx >= drafts.length) return drafts
  var src = drafts[idx]
  return drafts.map(function (d, i) {
    if (i === idx || (spread && src.accountId && d.accountId === src.accountId))
      return Object.assign({}, d, { account: name })
    return d
  })
}

// New state with the merchant's category remembered.
function cashewRememberCategory(state, groupKey, category, subcategory) {
  var s = JSON.parse(JSON.stringify(state || { version: 1 }))
  s.version = 1
  s.categories = s.categories || {}
  s.accounts = s.accounts || {}
  if (groupKey) s.categories[groupKey] = { category: category, subcategory: subcategory }
  return s
}

// New state with the bank account's Cashew name remembered.
function cashewRememberAccount(state, accountId, name) {
  var s = JSON.parse(JSON.stringify(state || { version: 1 }))
  s.version = 1
  s.categories = s.categories || {}
  s.accounts = s.accounts || {}
  if (accountId) s.accounts[accountId] = name
  return s
}

// Indexes of the drafts the table shows. With `onlyFilter`, only drafts whose
// id is a key of `idSet` (the ids the RECENT filter lets through).
// `closedSet` ({id: true}): rows of a closed account are skipped silently.
function cashewShownIndexes(drafts, onlyFilter, idSet, closedSet) {
  var out = []
  for (var i = 0; i < drafts.length; i++) {
    if (closedSet && closedSet[drafts[i].id]) continue
    if (!onlyFilter || (idSet && idSet[drafts[i].id])) out.push(i)
  }
  return out
}

// What `txdb cashew-links` reads: shown drafts only, `include` kept.
function cashewPayload(drafts, shown, maxChars) {
  var keep = {}
  shown.forEach(function (i) { keep[i] = true })
  return JSON.stringify({
    drafts: drafts.map(function (d, i) {
      return keep[i] ? d : Object.assign({}, d, { include: false })
    }),
    maxChars: maxChars || 6000
  })
}

function cashewIncluded(drafts, shown) {
  return shown.map(function (i) { return drafts[i] }).filter(function (d) { return d && d.include })
}

// ---- left list (grouped by day, Cashew style)

var _CASHEW_DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var _CASHEW_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December"]

// "2026-11-08" -> "Sunday, November 8"; the text itself when it is not a date.
function cashewDayLabel(date) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date || "").trim())
  if (!m) return String(date || "")
  var wd = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))).getUTCDay()
  return _CASHEW_DAYS[wd] + ", " + (_CASHEW_MONTHS[Number(m[2]) - 1] || m[2]) + " " + Number(m[3])
}

// "-1234.5" -> "₹1,234.50" (no sign; the caller adds the arrow).
function cashewMoney(amount) {
  var n = Math.abs(Number(String(amount || "0").replace(/,/g, "")))
  if (!isFinite(n)) return "₹0.00"
  return "₹" + n.toFixed(2).replace(/\B(?=(\d{3})+(?!\d)\.)/g, ",")
}

// A transfer pair is one card: {out: idx of the debit leg, inn: idx of the
// credit leg}. Only legs that are both shown and share a pairId pair up.
function cashewPairLegs(drafts, shown) {
  var byPair = {}, pairs = []
  for (var k = 0; k < shown.length; k++) {
    var d = drafts[shown[k]]
    if (!d || d.kind !== "transfer" || !d.pairId) continue
    ;(byPair[d.pairId] = byPair[d.pairId] || []).push(shown[k])
  }
  Object.keys(byPair).forEach(function (id) {
    var l = byPair[id]
    if (l.length !== 2) return
    var a = cashewIsDebit(drafts[l[0]]), b = cashewIsDebit(drafts[l[1]])
    if (a === b) return
    pairs.push(a ? { out: l[0], inn: l[1] } : { out: l[1], inn: l[0] })
  })
  return pairs
}

// Rows for the grouped list: [{idx, day, partner}] for the shown drafts, sorted
// by date (newest first by default), ties kept in draft order. A transfer pair
// is ONE row under the out leg's day: idx = out leg, partner = in leg (else -1).
function cashewRowOrder(drafts, shown, newestFirst) {
  var partner = {}, hidden = {}
  cashewPairLegs(drafts, shown).forEach(function (p) { partner[p.out] = p.inn; hidden[p.inn] = true })
  var rows = []
  for (var k = 0; k < shown.length; k++) {
    var d = drafts[shown[k]]
    if (!d || hidden[shown[k]]) continue
    rows.push({ idx: shown[k], day: String(d.date || ""), partner: partner[shown[k]] === undefined ? -1 : partner[shown[k]] })
  }
  rows.sort(function (a, b) {
    if (a.day !== b.day) return a.day < b.day ? -1 : 1
    return a.idx - b.idx
  })
  if (newestFirst !== false) rows.reverse()
  return rows
}

// New array with every draft in `idxs` merged with `patch`.
function cashewPatchMany(drafts, idxs, patch) {
  var out = drafts
  for (var i = 0; i < idxs.length; i++) if (idxs[i] >= 0) out = cashewPatch(out, idxs[i], patch)
  return out
}

// Net total per day of the shown drafts: { "2026-11-08": "-₹9.78" }.
function cashewDayTotals(drafts, shown) {
  var paise = {}, dayOf = {}
  cashewPairLegs(drafts, shown).forEach(function (p) { dayOf[p.inn] = drafts[p.out].date })   // the card sits under the out leg
  for (var k = 0; k < shown.length; k++) {
    var d = drafts[shown[k]]
    if (!d) continue
    var day = String(dayOf[shown[k]] !== undefined ? dayOf[shown[k]] : (d.date || ""))
    paise[day] = (paise[day] || 0) + Math.round(Number(d.amount || 0) * 100)
  }
  var out = {}
  Object.keys(paise).forEach(function (day) {
    var v = paise[day]
    out[day] = (v < 0 ? "-" : (v > 0 ? "+" : "")) + cashewMoney(v / 100)
  })
  return out
}

// {name: {icon, color}} from the `categories` of cashew-draft.
function cashewCategoryMap(categories) {
  var out = {}
  ;(categories || []).forEach(function (c) { out[c.name] = { icon: c.icon || "❓", color: c.color || "#37474F" } })
  return out
}

function cashewValidDate(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text).trim())
  if (!m) return false
  var mo = Number(m[2]), da = Number(m[3])
  return mo >= 1 && mo <= 12 && da >= 1 && da <= 31
}

// "-250" -> "-250.00"; null when it is not a plain number.
function cashewNormAmount(text) {
  var t = String(text).trim().replace(/,/g, "")
  if (!/^[-+]?\d+(\.\d+)?$/.test(t)) return null
  var n = Number(t)
  if (!isFinite(n)) return null
  return n.toFixed(2).replace(/^\+/, "")
}

// Link counts for the card title: "Link 2 of 5  ·  17 transactions  ·  5,310 characters".
function cashewLinkLabel(i, n, count, chars) {
  var c = String(chars).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return "Link " + (i + 1) + " of " + n + "  ·  " + count + (count === 1 ? " transaction" : " transactions")
    + "  ·  " + c + " characters"
}

// Transfer card line: "HDFC → SBI  ₹1.00  ·  2026-11-07".
function cashewTransferLine(t) {
  return (t.accountFrom || "?") + " → " + (t.accountTo || "?") + " " + cashewMoney(t.amount) + " · " + t.date
}

// "Mark 81 as tracked (8 transfers need a tap on Save in Cashew)?"
function cashewMarkQuestion(n, transfers) {
  var tail = transfers > 0
    ? " (" + transfers + (transfers === 1 ? " transfer needs" : " transfers need") + " a tap on Save in Cashew)" : ""
  return "Mark " + n + " as tracked" + tail + "?"
}

function cashewPrettyJson(text) {
  try { return JSON.stringify(JSON.parse(text), null, 1) } catch (e) { return String(text) }
}

// ---------------------------------------------------------- Cashew link builder
// Port of txdb/cashew.py build_links: same links, same warnings, byte for byte
// (tests/test_cashew_js.py checks it against the Python). `categories` is the
// list from `cashew-draft` ({name, type}); `shown` the indexes the table
// shows (other drafts count as excluded). Runs in microseconds, so the window
// builds the links in-process instead of spawning the CLI.
var CASHEW_APP_BASE = "https://cashewapp.web.app/"
var CASHEW_WEB_BASE = "https://budget-track.web.app/"
var CASHEW_BASE_URL = CASHEW_APP_BASE + "addTransaction?JSON="

// Python urllib.parse.quote(text, safe=""): encodeURIComponent also keeps ! ' ( ) *
function _cashewQuote(text) {
  return encodeURIComponent(text).replace(/[!'()*]/g, function (c) {
    return "%" + c.charCodeAt(0).toString(16).toUpperCase()
  })
}

// Python slices by code point, JS by UTF-16 unit.
function _cashewCut(s, n) {
  if (s.length <= n) return s
  var cp = Array.from(s)
  return cp.length <= n ? s : cp.slice(0, n).join("")
}
function _cashewLen(s) { return s.length <= 250 ? s.length : Array.from(s).length }

function _cashewRepr(s) {
  return s.indexOf("'") >= 0 && s.indexOf('"') < 0 ? '"' + s + '"' : "'" + s.replace(/'/g, "\\'") + "'"
}

function _cashewPct(s) { return s.replace(/%/g, "%25") }

function _cashewStr(v) { return v ? String(v) : "" }

function _cashewAbs(amount) { return _cashewStr(amount).replace(/^[+-]+/, "") }

// pairId -> [out leg, in leg] for each pair with exactly one debit and one credit included.
function _cashewTransferLegs(inc) {
  var groups = {}, order = []
  inc.forEach(function (d) {
    if (!d.pairId) return
    if (!groups.hasOwnProperty(d.pairId)) { groups[d.pairId] = []; order.push(d.pairId) }
    groups[d.pairId].push(d)
  })
  var out = {}
  order.forEach(function (pid) {
    var legs = groups[pid]
    var outs = legs.filter(function (d) { return _cashewStr(d.amount).charAt(0) === "-" })
    var ins = legs.filter(function (d) { return _cashewStr(d.amount).charAt(0) !== "-" })
    if (legs.length === 2 && outs.length === 1 && ins.length === 1) out[pid] = [outs[0], ins[0]]
  })
  return out
}

function _cashewTransfer(o, i, root) {
  var title = _cashewStr(o.title), date = _cashewStr(o.date)
  var from = _cashewStr(o.account), to = _cashewStr(i.account)
  var parts = [["amountFrom", _cashewAbs(o.amount)], ["amountTo", _cashewAbs(i.amount)],
               ["accountFrom", from], ["accountTo", to], ["title", title], ["date", date]]
  var query = parts.filter(function (p) { return p[1] }).map(function (p) {
    return p[0] + "=" + _cashewQuote(_cashewPct(p[1]))
  }).join("&")
  return { url: root + "addTransferRoute?" + query, pairId: o.pairId, title: title, date: date,
           amount: _cashewAbs(o.amount), accountFrom: from, accountTo: to, ids: [o.id, i.id] }
}

// `base`: "app" (default) or "web". Returns {links, transfers, warnings}.
function cashewBuildLinks(drafts, shown, maxChars, categories, base) {
  var max = maxChars || 6000
  var root = base === "web" ? CASHEW_WEB_BASE : CASHEW_APP_BASE
  var prefix = root + "addTransaction?JSON="
  var types = {}
  ;(categories || []).forEach(function (c) { types[c.name] = c.type })
  var keep = null
  if (shown) { keep = {}; shown.forEach(function (i) { keep[i] = true }) }
  var warnings = []
  var inc = []
  for (var i = 0; i < drafts.length; i++) {
    var dd = drafts[i]
    if (keep && !keep[i]) continue
    if (dd.include === undefined ? true : dd.include) inc.push(dd)
  }
  var key = function (d) { return [_cashewStr(d.date), _cashewStr(d.id)] }
  var cmp = function (a, b) {
    var x = key(a), y = key(b)
    return x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : x[1] < y[1] ? -1 : x[1] > y[1] ? 1 : 0
  }
  inc.sort(cmp)
  var paired = _cashewTransferLegs(inc)
  var legSet = []
  var pairList = []
  Object.keys(paired).forEach(function (pid) { pairList.push(paired[pid]); legSet.push(paired[pid][0], paired[pid][1]) })
  var bulk = inc.filter(function (d) { return legSet.indexOf(d) < 0 })

  var entryOf = function (d) {
    var label = (d.title || d.id) + " (" + (d.date === undefined || d.date === null ? "" : d.date) + ")"
    var title = _cashewStr(d.title), notes = _cashewStr(d.notes)
    if (_cashewLen(title) > 250) { warnings.push("title cut to 250 characters: " + label); title = _cashewCut(title, 250) }
    if (_cashewLen(notes) > 500) { warnings.push("notes cut to 500 characters: " + label); notes = _cashewCut(notes, 500) }
    var cat = _cashewStr(d.category), sub = _cashewStr(d.subcategory), acct = _cashewStr(d.account)
    var amount = _cashewStr(d.amount)
    if (cat === "Uncategorized") warnings.push("no category: " + label)
    else if (types.hasOwnProperty(cat)) {
      var t = types[cat], neg = amount.charAt(0) === "-"
      var friendOk = cat === "Friend Settlement" && sub === "Split Paid"
      if (!(t === "balance" || (neg ? t === "expense" : t === "income")) && !friendOk)
        warnings.push("category " + _cashewRepr(cat) + " does not fit the amount sign: " + label)
    }
    var e = { amount: amount, title: _cashewPct(title), date: _cashewStr(d.date), notes: _cashewPct(notes), category: _cashewPct(cat) }
    if (sub) e.subcategory = _cashewPct(sub)
    if (acct) e.account = _cashewPct(acct)
    e.fallbackCategory = "Uncategorized"
    return JSON.stringify(e)
  }
  var entries = bulk.map(entryOf)
  // the URL length is additive: quote(prefix) + sum(quote(entry)) + "%2C" per comma + quote("]}")
  var head = '{"transactions":['
  var fixed = _cashewQuote(head).length + _cashewQuote("]}").length + prefix.length
  var elen = entries.map(function (e) { return _cashewQuote(e).length })

  inc.forEach(function (d) {
    if (d.kind === "transfer" && legSet.indexOf(d) < 0)
      warnings.push("transfer leg without partner: " + d.title + " (" + d.date + ")")
  })
  var transfers = pairList.sort(function (p, q) { return cmp(p[0], q[0]) }).map(function (p) {
    return _cashewTransfer(p[0], p[1], root)
  })

  var units = [], byPair = {}
  bulk.forEach(function (d, k) {
    if (d.pairId) {
      if (!byPair.hasOwnProperty(d.pairId)) { byPair[d.pairId] = []; units.push(byPair[d.pairId]) }
      byPair[d.pairId].push(k)
    } else units.push([k])
  })
  var batches = [], cur = [], curLen = 0
  var lenOf = function (idx) {
    var n = fixed + 3 * Math.max(idx.length - 1, 0)
    idx.forEach(function (k) { n += elen[k] })
    return n
  }
  units.forEach(function (unit) {
    var trial = cur.concat(unit)
    if (cur.length && lenOf(trial) > max) { batches.push(cur); cur = unit.slice() }
    else cur = trial
  })
  if (cur.length) batches.push(cur)

  var links = []
  batches.forEach(function (b) {
    b.sort(function (p, q) { return cmp(bulk[p], bulk[q]) })
    var text = head + b.map(function (k) { return entries[k] }).join(",") + "]}"
    var url = prefix + _cashewQuote(text)
    if (url.length > max)
      warnings.push("one link is " + url.length + " characters, over the " + max + " limit: " + bulk[b[0]].title)
    links.push({ url: url, count: b.length, chars: url.length, ids: b.map(function (k) { return bulk[k].id }), json: text })
  })
  return { links: links, transfers: transfers, warnings: warnings }
}

// Short stand-in for a ~6,000 character link: the start, an ellipsis, the end.
function cashewPreview(url, head, tail) {
  var h = head || 140, t = tail || 20
  return url.length <= h + t + 1 ? url : url.slice(0, h) + "…" + url.slice(url.length - t)
}
