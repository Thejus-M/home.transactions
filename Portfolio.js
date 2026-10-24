// Portfolio.js — the investments maths for the Transactions widget.
//
// Computation only. Nothing in here formats money or dates: the QML side
// already imports Model.js for that, and keeping the two apart means a
// rupee is grouped the same way in BANK and in PORTFOLIO.
//
// Shapes come straight from `txdb snapshot` (see txdb/portfolio.py):
//
//   portfolio  { asOf, netWorth, assets, liabilities, invested, value,
//                pnl, pnlPct, dayChange, dayChangePct, xirr, stale,
//                lastFetch, lastOutcome, lastMessage }
//   holdings   [{ instrumentId, kind, name, symbol, isin, category, amc,
//                 broker, units, avgCost, invested, price, value, pnl,
//                 pnlPct, xirr, dayChange, weight, firstHeld, asOf }]
//   allocation [{ bucket, value, pct }]
//   activity   [{ id, date, instrumentId, name, kind, broker, units,
//                 price, amount, inferred, note, tracked }]   newest first
//   history    [{ asOf, value, invested }]                    oldest first
//
// Every total is recomputed from the holdings rather than trusted from
// the server, for the same reason the bank side re-adds its balances:
// a figure that disagrees with the rows under it should show as wrong,
// not quietly replace them.

// Display names for the kinds txdb stores. One place, so a bucket cannot
// read "mf" in one section and "Mutual funds" in another.
var KIND_LABELS = {
  mf: "Mutual funds",
  equity: "Stocks",
  us_equity: "US stocks",
  etf: "ETFs",
  bond: "Bonds",
  epf: "EPF",
  nps: "NPS",
  fd: "Fixed deposits",
  gold: "Gold",
  crypto: "Crypto",
  reit: "REITs",
  pms: "PMS",
  aif: "AIF",
  cash: "Cash",
  other: "Other"
}

// The order sections appear in: what you look at most, first. Anything
// unlisted sorts after these, alphabetically, rather than vanishing.
var KIND_ORDER = ["mf", "equity", "us_equity", "etf", "reit", "gold", "crypto",
                  "bond", "fd", "epf", "nps", "pms", "aif", "cash", "other"]

// Short words for an activity row's pill.
var ACTIVITY_LABELS = {
  buy: "BUY", sell: "SELL", sip: "SIP", new: "NEW", exit: "EXIT", corporate: "BONUS"
}

function kindLabel(kind) {
  return KIND_LABELS[kind] || String(kind || "Other")
}

function activityLabel(kind) {
  return ACTIVITY_LABELS[kind] || String(kind || "").toUpperCase()
}

// Money in (buy/sip/new) reads as an outflow, money back (sell/exit) as
// an inflow — the same sign convention a bank row uses, so the colours
// mean one thing across both tabs.
// INDmoney equates invested with market value, and reports no profit, for
// a holding whose purchase price it never had -- stock held at another
// broker, mostly. A position whose price moved today cannot also be exactly
// flat since purchase, so that pairing means the cost is unknown rather than
// the gain nil. Reporting "+0.0%" there would state something untrue.
// A fractional US share can be a few thousandths of a unit, so two decimal
// places round it to a flat "0". Keep roughly four significant figures
// below one unit, and drop the zeros that buys back.
function formatUnits(units) {
  var n = Number(units) || 0
  if (!n) return "0"
  var abs = Math.abs(n)
  var decimals = Math.min(8, Math.max(2, 4 - Math.floor(Math.log(abs) / Math.LN10)))
  var text = n.toFixed(decimals)
  if (text.indexOf(".") !== -1) text = text.replace(/0+$/, "").replace(/\.$/, "")
  return text
}
function costKnown(holding) {
  if (!holding) return false
  var invested = holding.invested || 0
  return !((holding.pnl || 0) === 0 && (holding.dayChange || 0) !== 0
           && invested !== 0 && invested === (holding.value || 0))
}
function activityIsOutflow(kind) {
  return kind === "buy" || kind === "sip" || kind === "new"
}

// A "new" row is a position that was already there the first time it was
// seen, not a purchase made that day — on the very first fetch every
// holding produces one. Its amount is the cost basis, which is real, but
// counting it as money moved would say the whole portfolio was bought on
// the day the widget started looking. So it colours like money in, and
// counts as nothing.
function activityMoved(kind) {
  return kind !== "new" && kind !== "corporate"
}

function _sum(list, field) {
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var value = list[i][field]
    if (typeof value === "number") total += value
  }
  return total
}

function _round(value) {
  return Math.round(value * 100) / 100
}

// --- totals -----------------------------------------------------------------

// What the header block shows. Figures are re-added from the holdings;
// net worth and liabilities are the server's, because they cover things
// that are not holdings (loans, card dues, EPF).
function summary(portfolio, holdings) {
  portfolio = portfolio || {}
  holdings = holdings || []
  var value = _sum(holdings, "value")
  var invested = _sum(holdings, "invested")
  var dayChange = _sum(holdings, "dayChange")
  var pnl = _round(value - invested)
  return {
    asOf: portfolio.asOf || "",
    netWorth: typeof portfolio.netWorth === "number" ? portfolio.netWorth : value,
    liabilities: portfolio.liabilities || 0,
    invested: _round(invested),
    value: _round(value),
    pnl: pnl,
    pnlPct: invested ? _round(pnl / invested * 100) : 0,
    dayChange: _round(dayChange),
    dayChangePct: (value - dayChange) ? _round(dayChange / (value - dayChange) * 100) : 0,
    xirr: typeof portfolio.xirr === "number" ? portfolio.xirr : null,
    count: holdings.length,
    stale: !!portfolio.stale,
    // True disagreement between the server's own total and the rows it
    // sent. A rupee of rounding is not news; a thousand is.
    disagrees: typeof portfolio.value === "number"
      && Math.abs(portfolio.value - value) > Math.max(1, Math.abs(value) * 0.01)
  }
}

// "2 days old", "today", "" when there is nothing to say. The widget
// shows how old the figures are rather than hiding it: a wrong number
// that looks current is the failure worth avoiding.
function ageLabel(asOf, todayIso) {
  if (!asOf) return ""
  var today = todayIso ? new Date(todayIso + "T00:00:00") : new Date()
  var then = new Date(asOf + "T00:00:00")
  if (isNaN(then.getTime())) return ""
  var days = Math.round((today.setHours(0, 0, 0, 0) - then.getTime()) / 86400000)
  if (days <= 0) return "today"
  if (days === 1) return "yesterday"
  if (days < 30) return days + " days old"
  var months = Math.round(days / 30)
  return months + (months === 1 ? " month old" : " months old")
}

// --- grouping ---------------------------------------------------------------

// Holdings as one section per asset kind, biggest section first within
// the fixed order above, biggest holding first inside each.
function groupByKind(holdings) {
  var buckets = {}
  for (var i = 0; i < holdings.length; i++) {
    var h = holdings[i]
    var kind = h.kind || "other"
    if (!buckets[kind]) buckets[kind] = []
    buckets[kind].push(h)
  }
  var out = []
  var kinds = Object.keys(buckets).sort(function (a, b) {
    var ia = KIND_ORDER.indexOf(a), ib = KIND_ORDER.indexOf(b)
    if (ia === -1 && ib === -1) return a.localeCompare(b)
    if (ia === -1) return 1
    if (ib === -1) return -1
    return ia - ib
  })
  for (var k = 0; k < kinds.length; k++) {
    var rows = buckets[kinds[k]].slice().sort(function (a, b) { return (b.value || 0) - (a.value || 0) })
    var value = _sum(rows, "value")
    var invested = _sum(rows, "invested")
    out.push({
      kind: kinds[k],
      label: kindLabel(kinds[k]),
      rows: rows,
      value: _round(value),
      invested: _round(invested),
      pnl: _round(value - invested),
      pnlPct: invested ? _round((value - invested) / invested * 100) : 0,
      // A group whose every holding has an unknown cost sums to no profit,
      // which would read as "broke even" rather than "nothing to compare
      // against". The header leaves the figure out instead -- see costKnown.
      costKnown: rows.some(costKnown)
    })
  }
  return out
}

// Filter + search, kept here rather than in the QML so the same rules
// are testable without a running shell.
function filterHoldings(holdings, kinds, brokers, query) {
  var needle = (query || "").toLowerCase()
  return (holdings || []).filter(function (h) {
    if (kinds && kinds.length && kinds.indexOf(h.kind) === -1) return false
    if (brokers && brokers.length && brokers.indexOf(h.broker || "") === -1) return false
    if (!needle) return true
    return ((h.name || "") + " " + (h.symbol || "") + " " + (h.category || "") + " " + (h.amc || ""))
      .toLowerCase().indexOf(needle) !== -1
  })
}

// The kinds and brokers actually present, for the filter popover —
// derived, never hardcoded, the same way accountOptions is.
function kindOptions(holdings) {
  var seen = {}
  for (var i = 0; i < (holdings || []).length; i++) seen[holdings[i].kind || "other"] = true
  return Object.keys(seen).sort(function (a, b) {
    var ia = KIND_ORDER.indexOf(a), ib = KIND_ORDER.indexOf(b)
    return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib)
  }).map(function (kind) { return { key: kind, label: kindLabel(kind) } })
}

function brokerOptions(holdings) {
  var seen = {}
  for (var i = 0; i < (holdings || []).length; i++) {
    var broker = holdings[i].broker || ""
    if (broker) seen[broker] = true
  }
  return Object.keys(seen).sort().map(function (b) { return { key: b, label: b } })
}

// --- allocation --------------------------------------------------------------

// Segments for the one bar the section leads with, in the same shape the
// credit-limit bar already takes: a fraction each, plus a key under it.
function allocationSegments(allocation, holdings) {
  var buckets = (allocation && allocation.length) ? allocation.slice() : groupByKind(holdings || []).map(function (g) {
    return { bucket: g.label, value: g.value, pct: 0 }
  })
  // A bucket that has gone to zero is not a slice of anything; keeping
  // it would draw a 1px segment and a "0%" entry in the key.
  buckets = buckets.filter(function (b) { return (b.value || 0) > 0 })
  var total = _sum(buckets, "value")
  if (!total) return { total: 0, segments: [] }
  buckets.sort(function (a, b) { return (b.value || 0) - (a.value || 0) })
  return {
    total: _round(total),
    segments: buckets.map(function (b) {
      return {
        bucket: b.bucket,
        value: _round(b.value || 0),
        fraction: (b.value || 0) / total,
        percent: _round((b.value || 0) / total * 100)
      }
    })
  }
}

// --- the analysis lines --------------------------------------------------------

// How much of the portfolio the biggest few holdings are. A single line
// that answers "am I actually diversified" better than a list does.
function concentration(holdings, top) {
  top = top || 5
  var rows = (holdings || []).slice().sort(function (a, b) { return (b.value || 0) - (a.value || 0) })
  var total = _sum(rows, "value")
  if (!total || !rows.length) return null
  var head = rows.slice(0, Math.min(top, rows.length))
  return {
    count: head.length,
    percent: _round(_sum(head, "value") / total * 100),
    largest: head[0].name,
    largestPercent: _round((head[0].value || 0) / total * 100)
  }
}

// Several funds in one category is the overlap nobody notices: three
// flexi-caps are one bet held three times. Only reported once a category
// holds more than one fund and more than a fifth of the whole.
function categoryOverlap(holdings, minPercent) {
  minPercent = minPercent === undefined ? 20 : minPercent
  var byCategory = {}
  var total = 0
  for (var i = 0; i < (holdings || []).length; i++) {
    var h = holdings[i]
    total += h.value || 0
    var key = h.category || ""
    if (!key) continue
    if (!byCategory[key]) byCategory[key] = { category: key, count: 0, value: 0 }
    byCategory[key].count += 1
    byCategory[key].value += h.value || 0
  }
  if (!total) return []
  return Object.keys(byCategory).map(function (key) {
    var entry = byCategory[key]
    return { category: entry.category, count: entry.count, value: _round(entry.value),
             percent: _round(entry.value / total * 100) }
  }).filter(function (entry) {
    return entry.count > 1 && entry.percent >= minPercent
  }).sort(function (a, b) { return b.percent - a.percent })
}

// Cash and cash-like as a share of everything — the drag that explains a
// portfolio returning less than its holdings did.
function cashDrag(holdings) {
  var total = _sum(holdings || [], "value")
  if (!total) return null
  var cash = 0
  for (var i = 0; i < holdings.length; i++) {
    if (holdings[i].kind === "cash" || holdings[i].kind === "fd") cash += holdings[i].value || 0
  }
  return { value: _round(cash), percent: _round(cash / total * 100) }
}

// Money actually put in over a month, buys less sells. The number that
// separates "the portfolio grew" from "I paid into the portfolio".
function netInvested(activity, monthIso) {
  var prefix = monthIso || new Date().toISOString().slice(0, 7)
  var inflow = 0, outflow = 0, sips = 0, opening = 0
  for (var i = 0; i < (activity || []).length; i++) {
    var row = activity[i]
    if (String(row.date || "").slice(0, 7) !== prefix) continue
    var amount = Math.abs(row.amount || 0)
    if (!activityMoved(row.kind)) {
      opening += amount
    } else if (activityIsOutflow(row.kind)) {
      outflow += amount
      if (row.kind === "sip") sips += amount
    } else if (row.kind === "sell" || row.kind === "exit") {
      inflow += amount
    }
  }
  return { month: prefix, invested: _round(outflow), withdrawn: _round(inflow),
           net: _round(outflow - inflow), sip: _round(sips),
           // Positions that were simply already there, kept apart so a
           // first fetch does not read as a month of enormous buying.
           opening: _round(opening) }
}

// Best and worst mover by percentage, ignoring positions too small for
// the answer to be interesting.
function movers(holdings, minValue) {
  minValue = minValue === undefined ? 1000 : minValue
  var rows = (holdings || []).filter(function (h) {
    return typeof h.pnlPct === "number" && (h.value || 0) >= minValue
  })
  if (!rows.length) return null
  var sorted = rows.slice().sort(function (a, b) { return b.pnlPct - a.pnlPct })
  return { best: sorted[0], worst: sorted[sorted.length - 1] }
}

// --- the value line ------------------------------------------------------------

// Points for the sparkline, in 0..1 of the drawing area, y already
// flipped so 0 is the top. Returns null below two points: one point is
// not a line, and drawing a flat one would imply a history that is not
// there.
function sparkline(history, field) {
  field = field || "value"
  var rows = (history || []).filter(function (p) { return typeof p[field] === "number" })
  if (rows.length < 2) return null
  var min = rows[0][field], max = rows[0][field]
  for (var i = 1; i < rows.length; i++) {
    if (rows[i][field] < min) min = rows[i][field]
    if (rows[i][field] > max) max = rows[i][field]
  }
  var span = max - min
  var points = rows.map(function (row, index) {
    return {
      x: rows.length === 1 ? 0 : index / (rows.length - 1),
      y: span ? 1 - (row[field] - min) / span : 0.5,
      asOf: row.asOf,
      value: row[field]
    }
  })
  return {
    points: points, min: min, max: max,
    first: rows[0][field], last: rows[rows.length - 1][field],
    change: _round(rows[rows.length - 1][field] - rows[0][field]),
    changePct: rows[0][field] ? _round((rows[rows.length - 1][field] - rows[0][field]) / rows[0][field] * 100) : 0,
    days: rows.length
  }
}

// How far below its best the portfolio is now. Worth a line only while
// it is actually down.
function drawdown(history) {
  var rows = (history || []).filter(function (p) { return typeof p.value === "number" })
  if (rows.length < 2) return null
  var peak = rows[0].value
  for (var i = 1; i < rows.length; i++) if (rows[i].value > peak) peak = rows[i].value
  var last = rows[rows.length - 1].value
  if (peak <= 0 || last >= peak) return null
  return { peak: _round(peak), now: _round(last), off: _round(peak - last),
           percent: _round((peak - last) / peak * 100) }
}

// How long a position has been held, from the first snapshot that saw it.
function daysHeld(holding, todayIso) {
  if (!holding || !holding.firstHeld) return null
  var today = todayIso ? new Date(todayIso + "T00:00:00") : new Date()
  var then = new Date(holding.firstHeld + "T00:00:00")
  if (isNaN(then.getTime())) return null
  return Math.max(0, Math.round((today.setHours(0, 0, 0, 0) - then.getTime()) / 86400000))
}
