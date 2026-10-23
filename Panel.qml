import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Transactions widget: bar icon + click-to-open popup listing recent
// transactions, each with a toggle for "already recorded elsewhere".
// A BILLS section shows each HDFC credit card's billing status with a
// mark-as-paid toggle, and fires a desktop notification once per card per
// day while a bill is still due. An account filter row narrows RECENT to
// one account at a time.
//
// Real transaction + billing data is read from the sibling
// hdfc-statement-fetcher project's output/ directory (see
// fetcherOutputDir below) — that project scrapes HDFC NetBanking and
// writes flat JSON in exactly the row shape Model.js expects.
Panel {
  id: root
  moduleName: "home.transactions"
  ipcTarget: "home.transactions"
  manageIpc: false

  // Sibling repo on this machine. Change here if that repo ever moves —
  // a single hardcoded path is simpler than a settings UI for a value
  // that changes approximately never on one personal machine.
  readonly property string fetcherDir: "/home/pc/Work/hdfc-statement-fetcher"
  // Progress written by the fetcher (output/fetch-status.json): stage,
  // message, and the path to the published login QR while the stage is
  // "qr-ready". Read through activeStatus below, with the other banks'.
  property var fetchStatus: ({})
  readonly property string fetcherOutputDir: fetcherDir + "/output"
  // Second source: the Axis fetcher writes the same shapes into its output/
  // folder (balances, transactions) and its own status file.
  readonly property string axisDir: "/home/pc/Work/axis-statement-fetcher"
  readonly property string axisOutputDir: axisDir + "/output"
  property var axisFetchStatus: ({})
  readonly property bool axisOtpNeeded: axisFetchProc.running && axisFetchStatus.stage === "otp-needed"
  // Third source: the SBI fetcher, same shapes and its own status file. It
  // solves the login CAPTCHA itself and asks for the OTP like Axis does.
  // Fourth source: the ICICI fetcher. A credit card only — that profile
  // has no linked bank account — so it writes a card_cycles row and no
  // transactions, and its chip shows the card rather than a balance.
  readonly property string iciciDir: "/home/pc/Work/icici-statement-fetcher"
  readonly property string iciciOutputDir: iciciDir + "/output"
  property var iciciFetchStatus: ({})

  readonly property string sbiDir: "/home/pc/Work/sbi-statement-fetcher"
  readonly property string sbiOutputDir: sbiDir + "/output"
  property var sbiFetchStatus: ({})
  readonly property bool sbiOtpNeeded: sbiFetchProc.running && sbiFetchStatus.stage === "otp-needed"
  readonly property bool anyFetchRunning: fetchProc.running || axisFetchProc.running
    || sbiFetchProc.running || iciciFetchProc.running

  // Only one fetch runs at a time (see BankBalance.allowed), so "the fetch
  // that is running" is a single thing: its bank, and its status file's
  // contents. Every progress line, the error colour and the QR popup read
  // this rather than one bank's properties — each bank keeps its own, which
  // the chips and the reload buttons still read.
  readonly property string activeBank: fetchProc.running ? "HDFC"
    : axisFetchProc.running ? "Axis"
      : sbiFetchProc.running ? "SBI"
        : iciciFetchProc.running ? "ICICI" : ""
  readonly property var activeStatus: fetchProc.running ? fetchStatus
    : axisFetchProc.running ? axisFetchStatus
      : sbiFetchProc.running ? sbiFetchStatus
        : iciciFetchProc.running ? iciciFetchStatus : ({})
  readonly property string activeStatusText: (activeStatus.message || "") !== ""
    ? activeBank + ": " + activeStatus.message : ""
  readonly property color activeStatusColor: activeStatus.stage === "error"
    ? Color.urgent : Color.accent

  // The QR popup, for whichever bank asks for a scan: HDFC and ICICI do
  // today, and a fetcher that writes the same qr-ready stage gets the popup
  // for free. Gated on the fetch running too, so a status file left at
  // qr-ready by a killed run cannot show a dead code.
  readonly property bool showQr: activeBank !== ""
    && activeStatus.stage === "qr-ready" && !!activeStatus.qr

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property var transactions: store.transactions
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked }).length
  readonly property int pendingTrackedCount: transactions.filter(function (t) { return t.tracked }).length
  // Rows picked with their checkboxes (map: transaction id -> true). Separate
  // from "tracked": Track / Untrack act on the selection.
  property var selectedIds: ({})
  // Checkboxes and the selection controls show only in selection mode, which
  // the check button beside search turns on.
  property bool selectionMode: false
  readonly property var selectedRows: transactions.filter(function (t) { return !!root.selectedIds[t.id] })
  readonly property int selectedCount: selectedRows.length
  readonly property bool allVisibleSelected: filteredTransactions.length > 0
    && filteredTransactions.every(function (t) { return !!root.selectedIds[t.id] })
  function toggleSelected(id) {
    var map = Object.assign({}, selectedIds)
    if (map[id]) delete map[id]
    else map[id] = true
    selectedIds = map
  }
  // Selects every row currently shown (after filters and search); when they
  // are all selected already, clears them instead.
  function toggleSelectAll() {
    var on = !allVisibleSelected
    var map = Object.assign({}, selectedIds)
    filteredTransactions.forEach(function (t) {
      if (on) map[t.id] = true
      else delete map[t.id]
    })
    selectedIds = map
  }
  function setSelectionMode(on) {
    selectionMode = on
    if (!on) selectedIds = ({})
  }
  // Marks every selected row tracked (or untracked), then clears the selection.
  function trackSelected(value) {
    store.setTrackedMany(selectedRows, value)
    selectedIds = ({})
  }

  // Selected account keys (Model.accountKey); empty means "all accounts".
  property var accountFilters: []
  function toggleAccountFilter(key) {
    var list = root.accountFilters.slice()
    var at = list.indexOf(key)
    if (at === -1) list.push(key)
    else list.splice(at, 1)
    root.accountFilters = list
  }
  property string searchQuery: ""
  // Search box is hidden by default (toggled via "/" or the search button)
  // — see the header Row replacing the old always-visible TextField.
  property bool searchVisible: false
  readonly property var accountOptions: Model.accountOptions(store.transactions, store.cardOverviews, store.accountNameOverrides)
  // Tracking view from the Filter popover: "all", "tracked" or "untracked".
  property string trackFilter: "all"
  readonly property var filteredTransactions: root.transactions
    .filter(function (t) { return root.accountFilters.length === 0 || root.accountFilters.indexOf(Model.accountKey(t)) !== -1 })
    .filter(function (t) {
      if (root.trackFilter === "all") return true
      return (root.trackFilter === "tracked") === !!t.tracked
    })
    .filter(function (t) {
      if (!root.searchQuery) return true
      return Model.transactionDisplayName(t, store.transactionNameOverrides)
        .toLowerCase().indexOf(root.searchQuery.toLowerCase()) !== -1
    })
  readonly property var groupedTransactions: Model.groupByDate(root.filteredTransactions)

  // Biggest bill first, then by card, so rows do not reshuffle between
  // snapshots. (Object.values alone put ••7462 before ••0220: JavaScript
  // walks integer-like keys first, and "0220" is not one.)
  readonly property var cardOverviewList: Object.values(store.cardOverviews).sort(function (a, b) {
    var byAmount = Model.billParts(b).payNow - Model.billParts(a).payNow
    return byAmount !== 0 ? byAmount : String(a.last4).localeCompare(String(b.last4))
  })
  // Two fixed columns for every bill row, so each row gets the same budget
  // for its card name and the figures line up down the popup. Sized from the
  // widest content either can hold: "IN CREDIT" at caption size, and
  // "₹16,005.39" at subtitle size. Without them the row with the longer
  // secondary text stole the other's name and elided away its last4.
  // The chevron on the combined limit bar sits in a slot of its own, so
  // every percentage under it keeps the same right edge whether or not
  // its row has one. Without it the combined "8%" sat ~15px left of the
  // per-pool "15%" and read as a misalignment, which it was.
  readonly property int limitChevronSlot: Style.space(14)
  readonly property int billStatusWidth: Style.space(63)
  readonly property int billFigureWidth: Style.space(79)
  readonly property bool billDue: store.anyBillDue()
  // Section figures for the BILLS header: what every card still wants, what
  // this cycle has spent into next month's bills, and the limit behind them
  // all. Properties rather than inline bindings, so each re-evaluates on a
  // snapshot or a mark-as-paid instead of on every paint.
  readonly property real billsDueTotal: Model.billsDueTotal(root.cardOverviewList, store.billOverrides)
  readonly property real billsNextTotal: Model.billsNextTotal(root.cardOverviewList)
  // One entry per pool: HDFC's two cards share a limit, ICICI's card has
  // its own, so the section shows a strip each rather than one figure that
  // would be true of neither.
  readonly property var creditLimits: Model.creditLimitPools(root.cardOverviewList)
  // The one bar the section leads with; the pools open underneath it.
  readonly property var creditTotal: Model.creditLimitTotal(root.creditLimits)
  property bool limitsExpanded: false

  // "Whole picture" stats — read the full, unfiltered transaction list
  // (post-tracked-override, pre-account-filter/search) so they stay
  // stable regardless of which chip is selected or what's searched.
  readonly property var monthSummary: Model.monthSummary(root.transactions)
  readonly property var accountBalances: store.accountBalances

  // Credit/debit colors — single source of truth; TransactionCard derives
  // its direction color from these rather than
  // each hardcoding their own.
  readonly property color creditColor: "#3ea34d"
  readonly property color debitColor: Color.urgent
  // BILLS-only third state: spend exists but hasn't been billed yet
  // (upcoming_payment_due is ₹0 while outstanding/unbilled is still
  // positive) — distinct from "settled" (green) and "due" (red), since
  // there's nothing to act on yet.
  readonly property color pendingColor: "#D9A441"
  readonly property color creditBg: Util.alpha(root.creditColor, 0.20)
  readonly property color debitBg: Util.alpha(root.debitColor, 0.20)
  // Shared right inset for every row's amount, so BILLS and RECENT
  // amounts line up in one column. Leaves room for the hover pencil and the
  // expand chevron that sit to the right of the amount.
  // Credit utilisation reads green while it is low, amber past 30% and red
  // past 50% — the bands a card issuer scores, not arbitrary thirds.
  // Segments stay accent-coloured and only vary in weight: the green/amber/
  // red scale already means "how close to the limit", and a second meaning
  // on the same bar would fight it.
  function limitSegmentColor(index) {
    return index % 2 === 0 ? Color.accent : Util.alpha(Color.accent, 0.55)
  }

  function limitColor(percent) {
    return percent >= 50 ? root.debitColor : (percent >= 30 ? root.pendingColor : root.creditColor)
  }

  function rowBg(t) { return t.amount < 0 ? root.debitBg : root.creditBg }
  function directionColor(t) { return t.amount < 0 ? root.debitColor : root.creditColor }

  // Arrow-key navigation: every focusable item already participates in
  // the same chain Tab walks (and Tab order already matches visual
  // order), so arrows just walk that chain one step rather than needing
  // per-row manual KeyNavigation wiring.
  // Item.nextItemInFocusChain() is a raw tree walk — unlike the engine's
  // own built-in Tab handling, it does NOT skip non-tab-stop items, so
  // calling it once from script can land on a plain child (an avatar
  // Rectangle, a Text label) that has no Keys handlers and no focus-ring
  // binding: the key event then goes nowhere and the focus ring vanishes
  // (confirmed live — Down arrow silently dropped focus off-screen).
  // Walk the chain until landing on an actual tab stop instead, bounded
  // so a malformed chain can't loop forever.
  function focusNext(item, forward) {
    var next = item
    for (var i = 0; i < 64 && next; i++) {
      next = next.nextItemInFocusChain(forward)
      if (!next || next === item) return
      if (next.activeFocusOnTab) {
        next.forceActiveFocus()
        root.scrollIntoView(next)
        return
      }
    }
  }

  // Scrolls the popup's Flickable just enough to bring `item` fully into
  // view — Up/Down moving focus doesn't move the scroll position on its
  // own, so without this the newly focused row could land off-screen.
  function scrollIntoView(item) {
    if (!item) return
    var pos = item.mapToItem(column, 0, 0)
    var margin = Style.spacing.sm
    var top = pos.y - margin
    var bottom = pos.y + item.height + margin
    if (top < flick.contentY) {
      flick.contentY = Math.max(0, top)
    } else if (bottom > flick.contentY + flick.height) {
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), bottom - flick.height)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) root.refreshData()

  // --- Transactions database (data/transactions.db, see txdb/) ---
  // Every persistent piece of data lives in one SQLite file. The widget
  // reads it as one JSON snapshot (`txdb snapshot`) and writes small
  // changes with argv commands (no shell, so names need no quoting).
  // Writers (this widget and the fetchers) rewrite data/.changed after
  // each commit; watching it reloads the snapshot.
  readonly property string widgetDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string txdbBin: widgetDir + "/bin/txdb"
  property var txdbQueue: []
  property bool refreshPending: false

  function refreshData() {
    if (snapshotProc.running || txdbWriteProc.running || txdbQueue.length > 0) {
      refreshPending = true
      return
    }
    snapshotProc.running = true
  }

  // Queues one write; writes run one at a time, in order.
  function txdb(args) {
    txdbQueue = txdbQueue.concat([args])
    runNextWrite()
  }

  function runNextWrite() {
    if (txdbWriteProc.running) return
    if (txdbQueue.length === 0) {
      if (refreshPending) { refreshPending = false; refreshData() }
      return
    }
    txdbWriteProc.command = ["python3", root.txdbBin].concat(txdbQueue[0])
    txdbQueue = txdbQueue.slice(1)
    txdbWriteProc.running = true
  }

  Process {
    id: txdbWriteProc
    onExited: function (exitCode) {
      if (exitCode !== 0) console.warn("txdb write failed (" + exitCode + "): " + command.slice(2).join(" "))
      root.runNextWrite()
    }
  }

  Process {
    id: snapshotProc
    command: ["python3", root.txdbBin, "snapshot"]
    stdout: StdioCollector {
      onStreamFinished: store.applySnapshot(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) console.warn("txdb snapshot failed (" + exitCode + ")")
      if (root.refreshPending) { root.refreshPending = false; root.refreshData() }
    }
  }

  FileView {
    id: dbChangedFile
    path: root.widgetDir + "/data/.changed"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshData()
  }

  Component.onCompleted: refreshData()

  QtObject {
    id: store
    property var trackedOverrides: ({})   // optimistic tracked changes not yet in a snapshot
    property var rawTransactions: []
    property var transactions: []
    property var cardOverviews: ({})   // map: last4 -> overview entry
    property var accountBalances: []   // list of {bank, accountType, last4, balance, currency}
    property var billOverrides: ({})   // map: last4 -> { markedPaid, notifiedDate }
    property var accountNameOverrides: ({})   // map: last4 -> user-set display name
    property var transactionNameOverrides: ({})   // map: groupKey -> user-set merchant name

    // Loads one `txdb snapshot`. A snapshot that doesn't parse is ignored,
    // so the widget keeps showing the last good data. Everything is set
    // together before bill reminders run, so "marked paid" is never lost
    // to load order.
    function applySnapshot(text) {
      var snap
      try { snap = JSON.parse(text) } catch (e) { console.warn("txdb snapshot unreadable: " + e); return }
      if (root.txdbQueue.length > 0 || txdbWriteProc.running) { root.refreshPending = true; return }
      var cards = {}
      var overviews = snap.cardOverviews || []
      for (var i = 0; i < overviews.length; i++) {
        if (overviews[i] && overviews[i].last4) cards[overviews[i].last4] = overviews[i]
      }
      cardOverviews = cards
      accountBalances = snap.balances || []
      billOverrides = snap.bills || {}
      accountNameOverrides = snap.accountNames || {}
      transactionNameOverrides = snap.merchantNames || {}
      trackedOverrides = {}
      rawTransactions = snap.transactions || []
      recompute()
      checkBillReminders()
    }

    // `transactions` = the snapshot rows with optimistic tracked changes on top.
    function recompute() {
      var base = rawTransactions
      var list = []
      for (var j = 0; j < base.length; j++) {
        var row = base[j]
        if (Object.prototype.hasOwnProperty.call(trackedOverrides, row.id)) {
          row = Object.assign({}, row, { tracked: trackedOverrides[row.id] })
        }
        list.push(row)
      }
      transactions = list
    }

    function setTracked(id, value) {
      var overrides = Object.assign({}, trackedOverrides)
      overrides[id] = !!value
      trackedOverrides = overrides
      recompute()
      root.txdb(["set-tracked", id, value ? "1" : "0"])
    }

    // Sets the tracked state of several rows at once (Track / Untrack selected).
    function setTrackedMany(rows, value) {
      if (!rows || rows.length === 0) return
      var overrides = Object.assign({}, trackedOverrides)
      var ids = []
      for (var i = 0; i < rows.length; i++) {
        overrides[rows[i].id] = !!value
        ids.push(rows[i].id)
      }
      trackedOverrides = overrides
      recompute()
      root.txdb(["set-tracked-many", value ? "1" : "0"].concat(ids))
    }

    // --- Bills ---

    function isPaid(last4) {
      return Model.isBillPaid(cardOverviews[last4], billOverrides[last4])
    }

    function anyBillDue() {
      var last4s = Object.keys(cardOverviews)
      for (var i = 0; i < last4s.length; i++) {
        if (!isPaid(last4s[i])) return true
      }
      return false
    }

    function setBillPaid(last4, value) {
      var overrides = Object.assign({}, billOverrides)
      overrides[last4] = Object.assign({}, overrides[last4] || {}, { markedPaid: value })
      billOverrides = overrides
      root.txdb(["bill-paid", cardAccountId(last4), value ? "1" : "0"])
    }

    // Bills belong to credit cards; the database keys them by account id.
    function cardAccountId(last4) {
      var entry = cardOverviews[last4]
      return entry && entry.accountId ? entry.accountId : "HDFC|credit|" + last4
    }

    // --- Account renaming ---

    function setAccountName(last4, name) {
      var overrides = Object.assign({}, accountNameOverrides)
      var trimmed = String(name || "").trim()
      if (trimmed) overrides[last4] = trimmed
      else delete overrides[last4]
      accountNameOverrides = overrides
      root.txdb(trimmed ? ["account-name", last4, trimmed] : ["account-name", last4])
    }

    // --- Transaction renaming ---

    function setTransactionName(groupKey, name) {
      var overrides = Object.assign({}, transactionNameOverrides)
      var trimmed = String(name || "").trim()
      if (trimmed) overrides[groupKey] = trimmed
      else delete overrides[groupKey]
      transactionNameOverrides = overrides
      root.txdb(trimmed ? ["rename", groupKey, trimmed] : ["rename", groupKey])
    }

    // Fires a desktop notification for each unpaid card, at most once per
    // card per calendar day. Runs after every snapshot.
    function checkBillReminders() {
      var today = new Date().toISOString().slice(0, 10)
      var overrides = Object.assign({}, billOverrides)
      var changed = false
      var last4s = Object.keys(cardOverviews)
      for (var i = 0; i < last4s.length; i++) {
        var last4 = last4s[i]
        var entry = cardOverviews[last4]
        var override = overrides[last4] || {}
        if (Model.isBillPaid(entry, override)) continue
        if (override.notifiedDate === today) continue

        Quickshell.execDetached([
          Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
          "--app-name", "home.transactions",
          "Bill due: " + entry.name,
          "••" + last4 + "  ·  " + Model.currencySymbol("INR")
            + Model.formatGrouped(Model.billParts(entry).payNow)
            + (entry.dueDate ? "  ·  pay by " + Model.formatShortDate(entry.dueDate) + " (" + Model.dueCountdown(entry.dueDate) + ")" : "")
            + "  ·  " + entry.payment_status
        ])

        overrides[last4] = Object.assign({}, override, { notifiedDate: today })
        root.txdb(["bill-notified", cardAccountId(last4), today])
        changed = true
      }
      if (changed) billOverrides = overrides
    }
  }

  property bool fetchCancelled: false

  // When a fetch ends, the notification says what it added, from the run
  // the fetcher recorded in the database (`txdb last-run <BANK>`).
  property string notifyBank: ""

  function notifyFetchResult(bank) {
    notifyBank = bank
    lastRunProc.running = true
  }

  Process {
    id: lastRunProc
    command: ["python3", root.txdbBin, "last-run", root.notifyBank]
    stdout: StdioCollector {
      onStreamFinished: root.sendFetchNotification(text)
    }
  }

  function sendFetchNotification(text) {
    var run = {}
    try { run = JSON.parse(text) || {} } catch (e) {}
    var name = ({ HDFC: "HDFC", AXIS: "Axis", SBI: "SBI" })[notifyBank] || notifyBank
    // A run that started before this fetch is the previous one: this fetch
    // died before it could record anything.
    if (!run.started_at || new Date(run.started_at).getTime() < fetchStartedMs - 5000) run = {}
    var title, body
    if (run.outcome === "done" && typeof run.added === "number") {
      title = run.added === 0 ? name + ": no new transactions"
        : name + ": " + run.added + " new transaction" + (run.added === 1 ? "" : "s")
      body = (typeof run.total === "number" ? run.total + " saved in total" : run.message || "")
    } else if (run.outcome === "done") {
      title = name + " fetch finished"
      body = run.message || ""
    } else if (run.outcome === "cancelled") {
      return
    } else {
      title = name + " fetch failed"
      body = run.message || "See output/widget-fetch.log"
    }
    Quickshell.execDetached([
      Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
      "--app-name", "home.transactions", title, body
    ])
  }

  property real fetchStartedMs: 0

  function startFetch(bank) {
    fetchStartedMs = Date.now()
    if (bank === "axis") axisFetchProc.running = true
    else if (bank === "sbi") sbiFetchProc.running = true
    else if (bank === "icici") iciciFetchProc.running = true
    else fetchProc.running = true
  }

  function cancelFetch(bank) {
    if (bank === "axis") {
      axisFetchCancelled = true
      axisCancelProc.running = true
      axisFetchProc.running = false
    } else if (bank === "sbi") {
      sbiFetchCancelled = true
      sbiCancelProc.running = true
      sbiFetchProc.running = false
    } else if (bank === "icici") {
      iciciFetchCancelled = true
      iciciCancelProc.running = true
      iciciFetchProc.running = false
    } else {
      fetchCancelled = true
      cancelProc.running = true
      fetchProc.running = false
    }
  }

  // What a credit-card-only bank's chip shows in place of a balance: what
  // the card wants, or that it has nothing to pay.
  function cardTextFor(bank) {
    var cards = root.cardOverviewList.filter(function (c) { return (c.bank || "") === bank })
    if (cards.length === 0) return ""
    var parts = Model.billParts(cards[0])
    if (parts.payNow > 0) {
      return Model.currencySymbol("INR") + Model.formatGrouped(parts.payNow) + " due"
    }
    return parts.inCredit
      ? Model.currencySymbol("INR") + Model.formatGrouped(Math.abs(parts.payNow)) + " in credit"
      : "no dues"
  }

  // The balance amount(s) for one bank ("HDFC", "AXIS" or "SBI"), joined. Only the
  // amount: the bank's logo already says which account it is.
  // The same balances as balanceTextFor, to the rupee: four chips with
  // paise need ~647px against the popup's 548.
  function chipBalanceFor(bank) {
    return root.accountBalances
      .filter(function (b) { return b.bank === bank })
      .map(function (b) { return Model.currencySymbol(b.currency) + Model.formatGrouped(Math.round(b.balance)) })
      .join("  ·  ")
  }

  function balanceTextFor(bank) {
    return root.accountBalances
      .filter(function (b) { return b.bank === bank })
      .map(function (b) { return Model.currencySymbol(b.currency) + Model.formatGrouped(b.balance) })
      .join("  ·  ")
  }

  // Stops the running fetch: signals its whole process group, removes the
  // login QR, and records the cancelled stage for the widget.
  Process {
    id: cancelProc
    command: ["bash", "-c", "cd '" + root.fetcherDir + "' && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && grep -qa src.main /proc/$PID/cmdline 2>/dev/null && kill -TERM -- -$PID 2>/dev/null; rm -f output/qr.png; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/.fetch-status.json.tmp && mv output/.fetch-status.json.tmp output/fetch-status.json"]
  }

  // Runs the fetcher. Its output goes to output/widget-fetch.log, so a
  // failed run is readable without opening the popup.
  Process {
    id: fetchProc
    // No QR colours are passed: both fetchers draw the login code to sit on
    // QrCard's fixed #0B1628 tile, and theming the code without the tile
    // only puts a mismatched square inside it. The ICICI fetcher reads
    // QR_FG / QR_BG / QR_ACCENT (#rrggbb) if they are ever set here, and
    // the tile would have to follow them; HDFC's palette is fixed in its
    // own _render_qr.
    // setsid makes this run its own process group, so Cancel can stop the
    // fetcher and its browser together (see cancelProc).
    command: ["setsid", "bash", "-c", "cd '" + root.fetcherDir + "' && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.fetchCancelled) { root.fetchCancelled = false; return }
      root.notifyFetchResult("HDFC")
    }
  }

  property bool axisFetchCancelled: false

  Process {
    id: axisCancelProc
    command: ["bash", "-c", "cd '" + root.axisDir + "' && mkdir -p output && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && grep -qa src.main /proc/$PID/cmdline 2>/dev/null && kill -TERM -- -$PID 2>/dev/null; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/.axis-fetch-status.json.tmp && mv output/.axis-fetch-status.json.tmp output/axis-fetch-status.json"]
  }

  // Runs the Axis fetcher. stdinEnabled keeps its stdin open: the OTP the
  // user types goes down that pipe (see otpRow), never into a file.
  Process {
    id: axisFetchProc
    stdinEnabled: true
    command: ["setsid", "bash", "-c", "cd '" + root.axisDir + "' && mkdir -p output && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.axisFetchCancelled) { root.axisFetchCancelled = false; return }
      root.notifyFetchResult("AXIS")
    }
  }

  FileView {
    id: axisFetchStatusFile
    path: root.axisOutputDir + "/axis-fetch-status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.axisFetchStatus = JSON.parse(text() || "{}") } catch (e) { root.axisFetchStatus = {} }
    }
    onLoadFailed: root.axisFetchStatus = ({})
    onFileChanged: reload()
  }

  property bool iciciFetchCancelled: false

  Process {
    id: iciciCancelProc
    command: ["bash", "-c", "cd '" + root.iciciDir + "' && mkdir -p output && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && grep -qa src.main /proc/$PID/cmdline 2>/dev/null && kill -TERM -- -$PID 2>/dev/null; rm -f output/qr.png; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/.icici-fetch-status.json.tmp && mv output/.icici-fetch-status.json.tmp output/icici-fetch-status.json"]
  }

  // Runs the ICICI fetcher. Its login code is published as output/qr.png
  // and shown in the QR popup (HDFC does the same), so the browser window
  // is no longer the thing you scan off — ICICI_HEADED=0 in its .env hides
  // it. The window shows by default until that has been through a real
  // scan.
  Process {
    id: iciciFetchProc
    command: ["setsid", "bash", "-c", "cd '" + root.iciciDir + "' && mkdir -p output && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (code) {
      if (root.iciciFetchCancelled) { root.iciciFetchCancelled = false; return }
      root.notifyFetchResult("ICICI")
      store.reload()
    }
  }

  FileView {
    id: iciciFetchStatusFile
    path: root.iciciOutputDir + "/icici-fetch-status.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { root.iciciFetchStatus = JSON.parse(text() || "{}") } catch (e) { root.iciciFetchStatus = {} }
    }
    onLoadFailed: root.iciciFetchStatus = ({})
  }

  property bool sbiFetchCancelled: false

  Process {
    id: sbiCancelProc
    command: ["bash", "-c", "cd '" + root.sbiDir + "' && mkdir -p output && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && grep -qa src.main /proc/$PID/cmdline 2>/dev/null && kill -TERM -- -$PID 2>/dev/null; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/.sbi-fetch-status.json.tmp && mv output/.sbi-fetch-status.json.tmp output/sbi-fetch-status.json"]
  }

  // Runs the SBI fetcher. Like Axis, stdinEnabled keeps its stdin open for
  // the OTP typed into otpRow; it is never written to a file.
  Process {
    id: sbiFetchProc
    stdinEnabled: true
    command: ["setsid", "bash", "-c", "cd '" + root.sbiDir + "' && mkdir -p output && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.sbiFetchCancelled) { root.sbiFetchCancelled = false; return }
      root.notifyFetchResult("SBI")
    }
  }

  FileView {
    id: sbiFetchStatusFile
    path: root.sbiOutputDir + "/sbi-fetch-status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.sbiFetchStatus = JSON.parse(text() || "{}") } catch (e) { root.sbiFetchStatus = {} }
    }
    onLoadFailed: root.sbiFetchStatus = ({})
    onFileChanged: reload()
  }

  FileView {
    id: fetchStatusFile
    path: root.fetcherOutputDir + "/fetch-status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.fetchStatus = JSON.parse(text() || "{}") } catch (e) { root.fetchStatus = {} }
    }
    onLoadFailed: root.fetchStatus = ({})
    onFileChanged: reload()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Icon {
        anchors.centerIn: parent
        iconSize: Style.space(11)
        color: root.foreground
        untrackedCount: root.untrackedCount
        billDue: root.billDue
      }
    }
    onPressed: function (buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))
    focusTarget: column

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
        spacing: Style.spacing.lg

        // Unhandled key events (Escape not claimed by any focused child —
        // the rename TextField claims its own) bubble up here, closing
        // the popup from anywhere inside it.
        Keys.onEscapePressed: root.close()

        // Focus lands here when the popup opens (panel.focusTarget: column)
        // and whenever it's released back here (search close, Escape from a
        // row). Without these, the very first Down/Up press did nothing.
        Keys.onDownPressed: root.focusNext(column, true)
        Keys.onUpPressed: root.focusNext(column, false)

        // "/" toggles the search box (hidden by default — see the header
        // Row below). Only reaches here when no focused child already
        // claimed it: a focused TextField (search or rename) consumes the
        // printable "/" itself by typing it, the same reason F2 safely
        // no-ops while a TransactionCard is mid-rename.
        Keys.onPressed: function (event) {
          if (event.text === "/") {
            root.searchVisible = !root.searchVisible
            if (root.searchVisible) Qt.callLater(function () { searchField.forceActiveFocus() })
            else { root.searchQuery = ""; column.forceActiveFocus() }
            event.accepted = true
          }
        }

        // Compact month summary + top-3-spenders, two lines, no header or
        // separator of their own — replaces the old PanelHero block
        // (which just re-displayed "Transactions"/"N to track", redundant
        // with the icon the user already clicked) and a 5-row spender
        // list (now one elided line).
        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Item {
            width: parent.width
            height: monthSummaryLabel.implicitHeight

            Text {
              id: monthSummaryLabel
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: root.monthSummary.monthLabel + ": "
                + Model.formatAmount({ amount: -root.monthSummary.spent, currency: root.monthSummary.currency })
                + " spent"
              color: root.debitColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: Model.formatAmount({ amount: root.monthSummary.income, currency: root.monthSummary.currency }) + " in"
              color: root.creditColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // One chip per bank: the bank's logo (click it to reload that
          // bank) then its balance, rounded to whole rupees — the exact
          // paise are in the account list above, and at four banks the
          // decimals were what pushed the row onto a second line. A Row,
          // not a Flow: wrapping made the reload buttons stop reading as
          // one set, and a Flow would quietly do it again the moment a
          // figure grew.
          Row {
            width: parent.width
            spacing: Style.spacing.md

            BankBalance {
              bank: "hdfc"
              tooltip: "Fetch HDFC data (opens browser, scan QR)"
              balanceText: root.chipBalanceFor("HDFC")
            }

            BankBalance {
              bank: "axis"
              tooltip: "Fetch Axis data (asks for the OTP here)"
              balanceText: root.chipBalanceFor("AXIS")
            }

            BankBalance {
              bank: "sbi"
              tooltip: "Fetch SBI data (asks for the OTP here)"
              balanceText: root.chipBalanceFor("SBI")
            }

            BankBalance {
              bank: "icici"
              tooltip: "Fetch ICICI card (opens browser, scan QR)"
              // No bank account on this profile, so the chip carries the
              // card's own line instead of a balance it will never have.
              balanceText: root.cardTextFor("ICICI")
            }
          }

          Text {
            // Only while a fetch is running. The last message stays in
            // output/fetch-status.json, but it isn't shown once its run is over.
            visible: root.activeStatusText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.activeStatusText
            color: root.activeStatusColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Axis or SBI OTP (whichever fetch is asking): one box per digit, like the bank's own screen. Typing
          // moves on to the next box, Backspace on an empty box goes back, and
          // a pasted code fills the row. The code goes down the fetcher's
          // stdin once every box is filled (or on Enter, for an empty or short
          // try, which the fetcher answers by asking again). Never stored.
          Item {
            id: otpRow
            // Hidden from the moment a code is sent until the fetcher writes a
            // new status: it asks again (new "updated") only if the code was
            // wrong, expired or the wrong length — so a code can't be typed twice.
            property string sentAt: ""
            readonly property var otpStatus: root.sbiOtpNeeded ? root.sbiFetchStatus : root.axisFetchStatus
            visible: (root.axisOtpNeeded || root.sbiOtpNeeded) && otpStatus.updated !== sentAt
            width: parent.width
            height: Style.space(34)
            // Only one fetch runs at a time, so at most one of these asks.
            readonly property var otpProc: root.sbiOtpNeeded ? sbiFetchProc : axisFetchProc
            readonly property int digitCount: (root.sbiOtpNeeded ? root.sbiFetchStatus.digits : root.axisFetchStatus.digits) || 6

            onVisibleChanged: if (visible) Qt.callLater(function () { otpRow.boxAt(0).forceActiveFocus() })

            function boxAt(i) { return otpRepeater.itemAt(i).input }

            function digitsTyped(index, value) {
              var digits = value.replace(/\D/g, "")
              for (var k = 0; k < digits.length && index + k < digitCount; k++) {
                boxAt(index + k).text = digits.charAt(k)
              }
              var next = Math.min(index + digits.length, digitCount - 1)
              boxAt(next).forceActiveFocus()
              if (allFilled()) sendOtp()
            }

            function allFilled() {
              for (var i = 0; i < digitCount; i++) {
                if (boxAt(i).text === "") return false
              }
              return true
            }

            function sendOtp() {
              if (!otpProc.running) return
              var code = ""
              for (var i = 0; i < digitCount; i++) code += boxAt(i).text
              otpProc.write(code + "\n")
              for (var j = 0; j < digitCount; j++) boxAt(j).text = ""
              sentAt = otpStatus.updated || ""
            }

            Row {
              id: otpBoxes
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.xs

              Repeater {
                id: otpRepeater
                model: otpRow.digitCount

                Rectangle {
                  id: cell
                  required property int index
                  readonly property alias input: box
                  width: Style.space(34)
                  height: Style.space(34)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: box.activeFocus ? Color.accent : Qt.darker(root.foreground, 2)

                  TextInput {
                    id: box
                    anchors.fill: parent
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    inputMethodHints: Qt.ImhDigitsOnly
                    // Plain TextInput (unlike QtQuick.Controls TextField)
                    // defaults activeFocusOnTab to false — without this,
                    // Tab/Shift+Tab would skip every box but the first and
                    // jump straight out of the OTP row. Gated on the row's
                    // own visibility so Tab can't land here while the OTP
                    // row is hidden (not needed) — same idiom as
                    // FetchControl.qml's cancelBox gating activeFocusOnTab
                    // on root.running instead of leaving it unconditional.
                    activeFocusOnTab: otpRow.visible
                    // BeforeItem: TextInput's own key handling always
                    // accepts Backspace — even with nothing to delete —
                    // which otherwise swallows it before this handler ever
                    // runs, silently breaking "Backspace on an empty box
                    // goes back a box".
                    Keys.priority: Keys.BeforeItem
                    onActiveFocusChanged: if (activeFocus) selectAll()
                    onTextEdited: otpRow.digitsTyped(cell.index, text)
                    Keys.onPressed: function (event) {
                      if (event.key === Qt.Key_Backspace && text === "" && cell.index > 0) {
                        otpRow.boxAt(cell.index - 1).forceActiveFocus()
                        event.accepted = true
                      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        otpRow.sendOtp()
                        event.accepted = true
                      }
                    }
                  }
                }
              }
            }
          }

          // The QR popup: shown while the fetcher waits for your scan, and
          // removed on its own once the stage moves past "qr-ready".
          QrCard {
            id: qrBox
            visible: root.showQr
            width: parent.width
            bank: root.activeBank
            // Both banks redraw the code on their own timer and republish
            // it; the ?updated suffix is what makes Qt fetch the new image
            // instead of the one it has cached under this path.
            // encodeURI because the ICICI fetcher resolves its own path
            // before writing it, which lands on the external drive — and
            // "MY Drive" has a space in it.
            imageSource: root.showQr
              ? ("file://" + encodeURI(root.activeStatus.qr) + "?" + root.activeStatus.updated) : ""
            title: root.showQr ? (root.activeStatus.message || "") : ""
          }
        }

        // BILLS shares its row with the section totals, the way RECENT
        // shares its row with the filter controls — they answer "what do I
        // owe in all" without costing a row of their own.
        Item {
          visible: root.cardOverviewList.length > 0
          width: parent.width
          height: Math.max(billsHeader.implicitHeight, billsTotals.implicitHeight)

          PanelSectionHeader {
            id: billsHeader
            anchors.left: parent.left
            // Section headers sit flush at x=0 while row content is inset;
            // matching the inset puts BILLS, the status discs and the card
            // names on one left edge.
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "BILLS"
            foreground: root.foreground
          }

          Row {
            id: billsTotals
            anchors.right: parent.right
            // Same inset as a row's own amount, so the two line up.
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: root.billsDueTotal > 0
                ? "to pay " + Model.currencySymbol("INR") + Model.formatGrouped(root.billsDueTotal)
                : "all paid"
              color: root.billsDueTotal > 0 ? root.debitColor : root.creditColor
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.billsNextTotal > 0
              textFormat: Text.PlainText
              text: "·  next " + Model.currencySymbol("INR") + Model.formatGrouped(Math.round(root.billsNextTotal))
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // One bar for every card, opening into the per-bank ones. Two
        // headline numbers (HDFC's pool and ICICI's) answered a question
        // nobody asks first; "how much credit am I using in all" does.
        BorderSurface {
          id: limitHeader
          readonly property var total: root.creditTotal
          readonly property bool _hot: limitHover.hovered || limitHeader.activeFocus

          visible: root.creditLimits.length > 0
          width: parent.width
          implicitHeight: limitTotalLabel.implicitHeight + Style.space(5) + limitTotalTrack.height
            + Style.space(4)
          radius: Style.cornerRadius
          color: limitHeader._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent"
          borderSpec: limitHeader.activeFocus
            ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

          HoverHandler { id: limitHover }

          activeFocusOnTab: true
          Keys.onReturnPressed: root.limitsExpanded = !root.limitsExpanded
          Keys.onEnterPressed: root.limitsExpanded = !root.limitsExpanded
          Keys.onSpacePressed: root.limitsExpanded = !root.limitsExpanded
          Keys.onLeftPressed: root.limitsExpanded = false
          Keys.onRightPressed: root.limitsExpanded = true
          Keys.onUpPressed: root.focusNext(limitHeader, false)
          Keys.onDownPressed: root.focusNext(limitHeader, true)

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.limitsExpanded = !root.limitsExpanded
          }

          Text {
            id: limitTotalLabel
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.top: parent.top
            anchors.topMargin: Style.space(2)
            textFormat: Text.PlainText
            text: limitHeader.total.limit > 0
              ? "limit " + Model.currencySymbol("INR") + Model.formatGrouped(Math.round(limitHeader.total.used))
                + " of " + Model.currencySymbol("INR") + Model.formatGrouped(limitHeader.total.limit) + " used"
              : "limit not read yet"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            visible: limitHeader.total.limit > 0
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX + root.limitChevronSlot
            anchors.baseline: limitTotalLabel.baseline
            textFormat: Text.PlainText
            text: Math.round(limitHeader.total.percent) + "%"
            color: root.limitColor(limitHeader.total.percent)
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption
          }

          // Says there is more behind the bar, and which way it goes. In
          // its own slot, outside the percentage column.
          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.baseline: limitTotalLabel.baseline
            textFormat: Text.PlainText
            text: root.limitsExpanded ? "▴" : "▾"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // One segment per pool, so the combined bar still shows which
          // bank the usage belongs to.
          Item {
            id: limitTotalTrack
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.top: limitTotalLabel.bottom
            anchors.topMargin: Style.space(5)
            height: Style.space(3)
            clip: true

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.darker(root.foreground, 3.0)
            }

            Row {
              anchors.left: parent.left
              height: parent.height

              Repeater {
                model: limitHeader.total.pools || []
                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  height: limitTotalTrack.height
                  width: limitHeader.total.limit > 0
                    ? Math.max(modelData.used > 0 ? 1 : 0,
                               limitTotalTrack.width * (modelData.used / limitHeader.total.limit))
                    : 0
                  radius: height / 2
                  color: root.limitSegmentColor(index)
                  Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
              }
            }
          }
        }

        // The per-bank strips, revealed by the bar above. Height animates
        // the same way a bill row's detail panel does, so the section
        // grows rather than jumping.
        Item {
          visible: root.creditLimits.length > 0 && height > 0
          width: parent.width
          height: root.limitsExpanded ? poolStrips.implicitHeight : 0
          clip: true

          Behavior on height { NumberAnimation { duration: 140 } }

          Column {
            id: poolStrips
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.md
            anchors.right: parent.right
            spacing: Style.spacing.xs

          // A strip per credit-limit pool. HDFC prints the same limit on both
          // its cards and total-minus-available equals their combined
          // outstanding — one shared pool — while ICICI's card carries its
          // own. Each strip keeps its height before a fetch has read a limit,
          // so the block does not jump when the figures arrive.
          Repeater {
            model: root.creditLimits

            delegate: Item {
              id: limitStrip
              required property var modelData
              readonly property bool known: limitStrip.modelData.limit > 0

              width: parent.width
              height: limitLabel.implicitHeight + Style.space(5) + limitTrack.height
                + (limitKey.visible ? Style.space(5) + limitKey.implicitHeight : 0)

              Text {
                id: limitLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.top: parent.top
                textFormat: Text.PlainText
                text: limitStrip.modelData.label + "  "
                  + (limitStrip.modelData.credit > 0
                      ? Model.currencySymbol("INR") + Model.formatGrouped(limitStrip.modelData.credit)
                        + " in credit of " + Model.currencySymbol("INR")
                        + Model.formatGrouped(limitStrip.modelData.limit) + " limit"
                      : "limit " + Model.currencySymbol("INR")
                        + Model.formatGrouped(Math.round(limitStrip.modelData.used))
                        + " of " + Model.currencySymbol("INR")
                        + Model.formatGrouped(limitStrip.modelData.limit) + " used")
                color: Qt.darker(root.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                id: limitPercent
                anchors.right: parent.right
                // The bar above reserves a chevron slot; matching it here
                // puts every percentage in one column.
                anchors.rightMargin: Style.spacing.rowPaddingX + root.limitChevronSlot
                anchors.baseline: limitLabel.baseline
                textFormat: Text.PlainText
                text: Math.round(limitStrip.modelData.percent) + "%"
                color: root.limitColor(limitStrip.modelData.percent)
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }

              // One thin track, one segment per card. At this utilisation a
              // small card is barely two pixels wide, so the key below
              // carries the detail — but a non-zero share never vanishes.
              Item {
                id: limitTrack
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.right: parent.right
                // Matches the indent this strip carries on its left, so
                // its track is the same width as the bar it hangs from.
                anchors.rightMargin: Style.spacing.rowPaddingX + Style.spacing.md
                anchors.top: limitLabel.bottom
                anchors.topMargin: Style.space(5)
                height: Style.space(3)
                clip: true

                Rectangle {
                  anchors.fill: parent
                  radius: height / 2
                  color: Qt.darker(root.foreground, 3.0)
                }

                Row {
                  anchors.left: parent.left
                  height: parent.height

                  Repeater {
                    model: limitStrip.modelData.segments || []
                    delegate: Rectangle {
                      required property var modelData
                      required property int index
                      height: limitTrack.height
                      width: Math.max(1, limitTrack.width * Math.min(1, Math.max(0, modelData.fraction)))
                      radius: height / 2
                      color: root.limitSegmentColor(index)
                      Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    }
                  }
                }
              }

              // Which card is using what. Only worth a line when the pool is
              // shared; a single-card pool says it on the row above.
              Flow {
                id: limitKey
                visible: (limitStrip.modelData.segments || []).length > 1
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.rowPaddingX
                anchors.top: limitTrack.bottom
                anchors.topMargin: Style.space(5)
                spacing: Style.spacing.md

                Repeater {
                  model: limitStrip.modelData.segments || []
                  delegate: Row {
                    required property var modelData
                    required property int index
                    spacing: Style.space(4)

                    Rectangle {
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.limitSegmentColor(index)
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "••" + modelData.last4 + " " + Model.currencySymbol("INR")
                        + Model.formatGrouped(Math.round(modelData.amount))
                      color: Qt.darker(root.foreground, 1.5)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          }
        }

        Column {
          visible: root.cardOverviewList.length > 0
          width: parent.width
          spacing: Style.spacing.xxs

          Repeater {
            model: root.cardOverviewList
            delegate: BillRow {
              id: billRow
              required property var modelData
              width: parent.width
              overview: modelData
              Keys.onUpPressed: root.focusNext(billRow, false)
              Keys.onDownPressed: root.focusNext(billRow, true)
            }
          }
        }

        PanelSeparator { visible: root.cardOverviewList.length > 0; foreground: root.foreground }

        // RECENT's own header shares its row with the Filter popover +
        // search-toggle button (right-aligned) instead of sitting on a
        // separate row above it — saves a full row of vertical space,
        // and a separator between them would've been redundant with the
        // one above this Item anyway.
        Item {
          width: parent.width
          height: Math.max(recentHeader.implicitHeight, filterRow.implicitHeight)

          PanelSectionHeader {
            id: recentHeader
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.untrackedCount > 0 ? ("RECENT  ·  " + root.untrackedCount + " TO TRACK") : "RECENT"
            foreground: root.foreground
          }

          Row {
            id: filterRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            FilterMenuButton { id: filterMenuButton }

            PanelActionButton {
              id: searchToggleBtn
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              iconText: "⌕"
              tooltipText: root.searchVisible ? "Hide search" : "Search (/)"
              foreground: root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              Keys.onDownPressed: root.focusNext(searchToggleBtn, true)
              Keys.onUpPressed: root.focusNext(searchToggleBtn, false)
              onClicked: {
                root.searchVisible = !root.searchVisible
                if (root.searchVisible) Qt.callLater(function () { searchField.forceActiveFocus() })
                else { root.searchQuery = ""; searchField.focus = false }
              }
            }

            PanelActionButton {
              id: selectToggleBtn
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              iconText: "󰄹"
              tooltipText: root.selectionMode ? "Done selecting" : "Select transactions"
              foreground: root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              Keys.onDownPressed: root.focusNext(selectToggleBtn, true)
              Keys.onUpPressed: root.focusNext(selectToggleBtn, false)
              // Moves focus into the list on turning selection on, so Space
              // lands on a row instead of staying on this button (where it
              // would just turn selection back off).
              onClicked: {
                var turningOn = !root.selectionMode
                root.setSelectionMode(turningOn)
                if (turningOn) root.focusNext(selectToggleBtn, true)
              }
            }
          }
        }

        // Selection controls get their own line under RECENT's header, so a
        // long label wraps instead of running into the section title.
        Flow {
          id: selectionRow
          width: parent.width
          spacing: Style.spacing.xs
          visible: root.selectionMode

          TextAction {
            // selectionMode is also covered by selectionRow's own
            // `visible` above, but TextAction's activeFocusOnTab mirrors
            // its own `visible` (see component below) — without
            // selectionMode here too, this stays a live tab stop with
            // selectedCount still > 0 even after selection mode is turned
            // back off, as long as something stays selected.
            visible: root.selectionMode && root.selectedCount > 0
            label: "Track (" + root.selectedCount + ")"
            onTriggered: root.trackSelected(true)
          }

          TextAction {
            visible: root.selectionMode && root.selectedCount > 0
            label: "Untrack (" + root.selectedCount + ")"
            onTriggered: root.trackSelected(false)
          }

          TextAction {
            // filteredTransactions.length > 0 stays true regardless of
            // selectionMode, so this one needs the explicit guard too —
            // otherwise it's a live tab stop even while selectionRow (and
            // this button with it) is hidden.
            visible: root.selectionMode && root.filteredTransactions.length > 0
            label: root.allVisibleSelected ? "Clear" : "Select all"
            onTriggered: root.toggleSelectAll()
          }
        }

        TextField {
          id: searchField
          visible: root.searchVisible
          width: parent.width
          placeholderText: "Search transactions…"
          text: root.searchQuery
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          onTextChanged: root.searchQuery = text
          Keys.onEscapePressed: function (event) {
            event.accepted = true
            root.searchQuery = ""
            root.searchVisible = false
            searchField.focus = false
            Qt.callLater(function () { column.forceActiveFocus() })
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.lg

          Repeater {
            model: root.groupedTransactions
            delegate: Column {
              required property var modelData
              width: parent.width
              spacing: Style.spacing.sm

              // Date-group header: label on the left, that day's net
              // total on the right (e.g. "Friday, October 2" / "-₹47.36").
              Item {
                width: parent.width
                height: dateLabel.implicitHeight

                Text {
                  id: dateLabel
                  anchors.left: parent.left
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: Model.formatAmount({ amount: modelData.total, currency: modelData.currency })
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  model: modelData.rows
                  delegate: TransactionCard {
                    required property var modelData
                    width: parent.width
                    txn: modelData
                    selectable: true
                  }
                }
              }
            }
          }

          Text {
            visible: root.filteredTransactions.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: root.accountFilters.length === 0 ? "Nothing pending." : "No transactions for the selected accounts."
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }
        }

      }
    }
  }

  // Compact BILLS row: a status gutter (the disc, and under it the one word
  // for where this bill stands), the card with its deadline, and the two
  // figures that matter — what the card wants now, and what this cycle has
  // already spent into next month's bill. Click anywhere to expand; click
  // the disc to flip the manual "mark as paid" override.
  component BillRow: BorderSurface {
    id: billRow
    required property var overview
    property bool expanded: false
    readonly property bool paid: store.isPaid(billRow.overview.last4)
    // Label and network kept apart: a rename shows as typed, while the
    // network mark still follows the bank's own card name.
    readonly property var brand: Model.cardLabelParts(billRow.overview.name,
      store.accountNameOverrides[billRow.overview.last4])
    readonly property string bank: Model.accountBank(billRow.overview.accountId)
    // The limit pool this card belongs to — its bank's, shared or not.
    readonly property var pool: {
      for (var i = 0; i < root.creditLimits.length; i++) {
        var candidate = root.creditLimits[i]
        for (var s = 0; s < candidate.segments.length; s++) {
          if (candidate.segments[s].last4 === billRow.overview.last4) return candidate
        }
        if (candidate.bank === billRow.bank && candidate.cards === 1) return candidate
      }
      return null
    }
    // The bill already generated, what has been paid into the card, what is
    // left to pay now and this cycle's spend — see Model.billParts.
    readonly property var parts: Model.billParts(billRow.overview)
    // Three states, purely numeric — deliberately NOT keyed off the scrape's
    // own "FULLY PAID"/"PARTIALLY PAID" wording, which says paid while ₹595
    // is still owed and says partly paid while nothing is.
    //   "settled" — nothing left to pay (or the bank owes the cardholder)
    //     and no unbilled spend — green ✓.
    //   "pending" — nothing due yet, just this cycle's spend building up
    //     into next month's bill — amber ●.
    //   "due" — a bill is generated and not cleared — red !.
    // The manual "mark as paid" override still drives the bill-due
    // reminder/badge (store.isPaid/anyBillDue); it does not recolour the row.
    readonly property string billState: billRow.parts.payNow > 0
      ? "due"
      : (billRow.parts.nextBill > 0 && !billRow.parts.inCredit ? "pending" : "settled")
    readonly property bool displayPaid: billRow.billState === "settled"
    readonly property color statusColor: billRow.billState === "settled"
      ? root.creditColor
      : (billRow.billState === "due" ? root.debitColor : root.pendingColor)
    readonly property string statusGlyph: billRow.billState === "settled"
      ? "✓"
      : (billRow.billState === "due" ? "!" : "●")
    readonly property bool _hot: rowHover.hovered || billRow.activeFocus
    // The status column (disc + label) is the tallest thing in the row, so
    // it sets this; the two text lines need less.
    readonly property int collapsedHeight: Style.space(44)
    // Where the row's text starts — the status column plus its gap. Shared
    // with the detail panel, so the panel's text lines up under the card
    // name instead of an inset worked out from a disc size long since gone.
    readonly property int contentLeft: Style.spacing.rowPaddingX + root.billStatusWidth + Style.spacing.md

    implicitHeight: billRow.collapsedHeight + (billRow.expanded ? detailsPanel.implicitHeight + Style.space(10) : 0)
    radius: Style.cornerRadius
    opacity: rowMouse.pressed ? 0.75 : 1.0
    color: billRow._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent"
    borderSpec: billRow.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 80 } }

    HoverHandler {
      id: rowHover
    }

    activeFocusOnTab: true
    // Matches the row's own click behavior (expand) — "mark as paid" is
    // mouse-only on the avatar, same precedent as TransactionCard's rename
    // pencil not being in the main Tab/Enter flow either.
    Keys.onReturnPressed: billRow.expanded = !billRow.expanded
    Keys.onEnterPressed: billRow.expanded = !billRow.expanded
    Keys.onSpacePressed: billRow.expanded = !billRow.expanded
    Keys.onUpPressed: root.focusNext(billRow, false)
    Keys.onDownPressed: root.focusNext(billRow, true)
    // Left/Right collapse/expand full card details — same convention as
    // TransactionCard, which also keeps these off Up/Down (row nav).
    Keys.onLeftPressed: billRow.expanded = false
    Keys.onRightPressed: billRow.expanded = true

    // Fixed-height collapsed row, pinned to the top — same reasoning as
    // TransactionCard's collapsedRow: the card's own height grows below
    // this when expanded, so nothing in here has to account for that.
    Item {
      id: collapsedRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: billRow.collapsedHeight

      // Covers the collapsed row — clicking anywhere on it expands the full
      // detail panel below. The disc's own MouseArea (below) sits on top of
      // this one (declared later = higher z) and claims just that icon for
      // "mark as paid", same precedent as TransactionCard's editBtn.
      MouseArea {
        id: rowMouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: billRow.expanded = !billRow.expanded
      }

      // Status gutter: the disc, and under it the one word for where this
      // bill stands. Fixed width, so every row's name starts at the same x
      // whatever its label says, and the labels read as their own column.
      Item {
        id: statusGutter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: root.billStatusWidth
        height: avatar.height + (statePill.visible ? Style.space(4) + statePill.height : 0)

        Rectangle {
          id: avatar
          width: Style.space(20)
          height: width
          radius: width / 2
          color: Util.alpha(billRow.statusColor, 0.16)
          anchors.top: parent.top
          // Left-aligned, not centred: the disc, the label under it and the
          // BILLS header all share one left edge this way.
          anchors.left: parent.left

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: billRow.statusGlyph
            color: billRow.statusColor
            font.bold: true
            // A smaller disc needs a proportionally larger glyph to stay
            // legible, so this drops one step where the disc dropped two.
            font.pixelSize: Style.font.caption
          }

          // The one place "mark as paid" lives: click just the status icon
          // to flip the manual override (it still drives the bill-due
          // reminder/badge) without expanding the row.
          MouseArea {
            anchors.fill: parent
            // The disc lost a third of its width; the target keeps the size
            // it had. The gutter around it is empty, so nothing else can be
            // hit by mistake.
            anchors.margins: -Style.space(10)
            cursorShape: Qt.PointingHandCursor
            onClicked: store.setBillPaid(billRow.overview.last4, !billRow.paid)
          }
        }

        // One word, never a sentence: how long is left belongs on the due
        // line beside the card's name, where there is room for it.
        Rectangle {
          id: statePill
          readonly property string label: billRow.parts.inCredit
            ? "IN CREDIT"
            : (billRow.parts.payNow <= 0
                ? (billRow.paid ? "PAID" : "")
                : (billRow.paid ? "PAID"
                    : (Model.billUrgency(billRow.overview, false) === "overdue" ? "OVERDUE" : "NOT PAID")))
          readonly property color tone: billRow.parts.inCredit
            ? root.creditColor
            : (billRow.parts.payNow <= 0 || billRow.paid
                ? Qt.darker(root.foreground, 1.4)
                : root.debitColor)

          visible: statePill.label !== ""
          anchors.top: avatar.bottom
          anchors.topMargin: Style.space(4)
          anchors.left: parent.left
          implicitWidth: Math.min(parent.width, pillText.implicitWidth + Style.space(8))
          implicitHeight: pillText.implicitHeight + Style.space(2)
          width: implicitWidth
          height: implicitHeight
          radius: Style.space(4)
          color: Util.alpha(statePill.tone, 0.18)

          Text {
            id: pillText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: statePill.label
            color: statePill.tone
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption
          }
        }
      }

      // The card and its deadline. Same two-line shape and spacing as the
      // figures on the right, so the name sits on the amount's baseline and
      // the due date on the next bill's. Only the name can shrink: it is the
      // one item whose width comes from a pair of anchors.
      Column {
        id: textCol
        anchors.left: statusGutter.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: amountStack.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Item {
          width: parent.width
          height: nameText.implicitHeight

          BrandMark {
            id: billBrandMark
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            network: billRow.brand.network
            markHeight: Style.spaceReal(9)
          }

          Text {
            id: nameText
            anchors.left: billBrandMark.visible ? billBrandMark.right : parent.left
            anchors.leftMargin: billBrandMark.visible ? Style.space(6) : 0
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: billRow.brand.label + " ••" + billRow.overview.last4
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            // One step down from subtitle: 16 characters plus the network
            // mark fit the name column with room to spare, so the last4 is
            // never the thing that elides.
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        // The last day to pay, while there is something to pay — red once
        // three days or less are left, or it is past. A cleared card shows
        // its last payment here instead.
        Text {
          id: dueText
          readonly property string urgency: Model.billUrgency(billRow.overview, billRow.paid)
          width: parent.width
          textFormat: Text.PlainText
          text: billRow.parts.payNow > 0 && billRow.overview.dueDate
            ? "Due " + Model.formatShortDate(billRow.overview.dueDate)
              + " · " + Model.dueCountdown(billRow.overview.dueDate)
            : Model.billPaidLine(billRow.overview)
          color: dueText.urgency !== "" ? root.debitColor : Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Two figures, stacked so they are never mistaken for one: what the
      // card wants now, and what this cycle has already spent into next
      // month's bill. The second line is always drawn — an empty next bill
      // is said in words rather than left to a dash — so rows stay level.
      Column {
        id: amountStack
        // Fixed width, so both rows' figures share a column and neither row
        // can borrow width from the other's card name.
        width: root.billFigureWidth
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          id: payNowText
          anchors.right: parent.right
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: billRow.parts.payNow > 0
            ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.payNow)
            : (billRow.parts.inCredit
                ? Model.currencySymbol("INR") + Model.formatGrouped(Math.abs(billRow.parts.payNow))
                : "Nothing to pay")
          color: billRow.parts.payNow > 0 || billRow.parts.inCredit
            ? billRow.statusColor
            : Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.bold: billRow.parts.payNow > 0 || billRow.parts.inCredit
          font.pixelSize: billRow.parts.payNow > 0 || billRow.parts.inCredit
            ? Style.font.subtitle : Style.font.caption
        }

        Text {
          id: nextBillText
          anchors.right: parent.right
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: billRow.parts.nextBill > 0
            ? "next " + Model.currencySymbol("INR") + Model.formatGrouped(Math.round(billRow.parts.nextBill))
            : "no spend yet"
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Expanded detail panel: every field the billing-overview scrape gives
    // us for this card, neatly laid out — not just the two numbers the
    // collapsed row has room for.
    Column {
      id: detailsPanel
      visible: billRow.expanded
      anchors.top: collapsedRow.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: billRow.contentLeft
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(4)

      Rectangle {
        width: parent.width
        height: Style.spacing.hairline
        color: Qt.darker(root.foreground, 1.8)
      }

      // Which bank the card is from, as its own mark: the collapsed row has
      // no space for it, and the card's name no longer carries the bank.
      Item {
        width: parent.width
        height: Math.max(bankLabel.implicitHeight, bankMark.implicitHeight)

        Text {
          id: bankLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Bank"
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // A bank with no mark of its own falls back to its name. Never
        // defaults to HDFC, which would mislabel the first Axis or SBI card.
        Loader {
          id: bankMark
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          sourceComponent: billRow.bank === "HDFC" ? hdfcMark
            : (billRow.bank === "AXIS" ? axisMark
                : (billRow.bank === "SBI" ? sbiMark
                : (billRow.bank === "ICICI" ? iciciMark : bankNameOnly)))
        }

        Component { id: hdfcMark; HdfcLogo { variant: "icon"; markSize: Style.spaceReal(12) } }
        Component { id: axisMark; AxisLogo { markSize: Style.spaceReal(12) } }
        Component { id: sbiMark; SbiLogo { markSize: Style.spaceReal(12) } }
        Component { id: iciciMark; IciciLogo { markSize: Style.spaceReal(12) } }
        Component {
          id: bankNameOnly
          Text {
            textFormat: Text.PlainText
            text: billRow.bank
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption
          }
        }
      }

      Repeater {
        model: [
          { label: "Bill this month", value: billRow.parts.hasBreakdown ? billRow.overview.last_statement_amount : "" },
          // paidIn is only known once the Outstanding Summary has been
          // scraped; until then the same money shows as this cycle's credits.
          { label: "Paid into card", value: billRow.parts.paidIn > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.paidIn)
              : (Model.parseCurrencyString(billRow.overview.credited_this_cycle) !== 0
                  ? billRow.overview.credited_this_cycle : "") },
          { label: "Left to pay", value: billRow.parts.payNow > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.payNow) : "" },
          { label: "In credit", value: billRow.parts.inCredit
              ? Model.currencySymbol("INR") + Model.formatGrouped(Math.abs(billRow.parts.payNow)) : "" },
          { label: "Bill generated", value: Model.formatShortDate(billRow.overview.statementDate, true) },
          { label: "Pay by", value: billRow.overview.dueDate
              ? Model.formatShortDate(billRow.overview.dueDate, true) + "  ·  " + Model.dueCountdown(billRow.overview.dueDate) : "" },
          { label: "Next bill on", value: Model.formatShortDate(billRow.overview.nextStatementDate, true) },
          { label: "Next bill so far", value: billRow.parts.nextBill > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.nextBill) : "" },
          { label: "Total outstanding", value: billRow.overview.total_outstanding },
          { label: "Unsettled / loans", value: billRow.overview.unsettled_amount || "" },
          // One shared pool: every card on this account reports the same
          // limit, so the row says so instead of implying this card has it
          // to itself.
          { label: "Limit", value: (billRow.overview.credit_limit_total || "")
              + (billRow.overview.credit_limit_total && billRow.pool && billRow.pool.cards > 1
                  ? "  ·  shared with " + (billRow.pool.cards - 1)
                    + (billRow.pool.cards > 2 ? " other cards" : " other card") : "") },
          { label: "Available", value: billRow.overview.available_limit || "" },
          { label: "Used", value: billRow.pool && billRow.pool.limit > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.pool.used) : "" },
          { label: "Last payment", value: (billRow.overview.last_payment_amount || "") + (billRow.overview.last_payment_date ? "  ·  " + billRow.overview.last_payment_date : "") },
          { label: "Status", value: billRow.overview.payment_status }
        ].filter(function (row) { return row.value })
        delegate: Item {
          required property var modelData
          width: parent.width
          height: Math.max(labelText.implicitHeight, valueText.implicitHeight)

          Text {
            id: labelText
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: modelData.label
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            id: valueText
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: modelData.value
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }

  // Compact trigger + popover replacing the old always-expanded account
  // FilterChip Flow — both just narrow what RECENT shows, so they're folded into one popover that
  // costs a single small row while closed AND while open (a popover floats
  // over the content below instead of pushing it down, unlike an inline
  // disclosure). The accent dot shows at a glance whether any non-default
  // filter is active without opening it.
  component FilterMenuButton: BorderSurface {
    id: filterButton
    readonly property bool filterActive: root.accountFilters.length > 0 || root.trackFilter !== "all"
    readonly property bool _hot: mouse.containsMouse || filterButton.activeFocus

    function currentLabel() {
      var n = root.accountFilters.length
      if (n === 0) return "Filter"
      if (n > 1) return n + " accounts"
      for (var i = 0; i < root.accountOptions.length; i++) {
        if (root.accountOptions[i].key === root.accountFilters[0]) return root.accountOptions[i].label.split(" ••")[0]
      }
      return "Filter"
    }

    implicitHeight: Style.space(28)
    implicitWidth: triggerRow.implicitWidth + Style.space(20)
    radius: Style.cornerRadius
    color: Style.controlFill(filterButton.activeFocus, filterButton._hot, root.foreground, Color.accent)
    borderSpec: Border.controlSpec(filterButton.activeFocus ? "focus" : (filterButton._hot ? "hover-cursor" : "normal"), root.foreground, Color.accent)

    activeFocusOnTab: true
    Keys.onReturnPressed: filterPopup.opened ? filterPopup.close() : filterPopup.open()
    Keys.onEnterPressed: filterPopup.opened ? filterPopup.close() : filterPopup.open()
    Keys.onSpacePressed: filterPopup.opened ? filterPopup.close() : filterPopup.open()
    Keys.onDownPressed: root.focusNext(filterButton, true)
    Keys.onUpPressed: root.focusNext(filterButton, false)

    Behavior on color { ColorAnimation { duration: 100 } }

    Row {
      id: triggerRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        textFormat: Text.PlainText
        text: "󰈳"
        color: root.foreground
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: filterButton.currentLabel()
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: filterButton.filterActive
        anchors.verticalCenter: parent.verticalCenter
      }

      Rectangle {
        visible: filterButton.filterActive
        width: Style.space(6)
        height: width
        radius: width / 2
        color: Color.accent
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: filterPopup.opened ? filterPopup.close() : filterPopup.open()
    }

    Popup {
      id: filterPopup
      // Clicks on the trigger are handled by its own onClicked (which toggles).
      // Without this, the press closes the popup and the click reopens it.
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
      y: filterButton.height + Style.space(4)
      x: filterButton.width - width
      width: Style.space(200)
      padding: Style.spacing.hairline
      focus: true

      background: BorderSurface {
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        radius: Style.cornerRadius
      }

      onOpened: filterMenuColumn.forceActiveFocus()

      // `Popup` itself isn't a QML Item, so `Keys` can't attach to it
      // directly (confirmed: attaching it there logs "Could not attach
      // Keys property ... is not an Item" and silently no-ops) — it has
      // to go on the contentItem, same as Dropdown.qml's own Escape
      // handling living on its ListView contentItem, not its Popup.
      contentItem: Column {
        id: filterMenuColumn
        width: filterPopup.width - Style.space(2)
        spacing: Style.space(2)
        focus: true

        // Escape closes the popover, but a now-hidden row/column keeps
        // activeFocus until something else explicitly takes it (same
        // class of bug as searchField's and editField's own Escape
        // handlers) — without restoring it to filterButton, Tab/arrow
        // keys go nowhere until the user clicks something.
        Keys.onEscapePressed: function (event) {
          filterPopup.close()
          Qt.callLater(function () { filterButton.forceActiveFocus() })
          event.accepted = true
        }

        // Confined stand-in for root.focusNext, for the rows in this
        // popover. root.focusNext also calls root.scrollIntoView, which
        // maps the item into `column` — meaningless for a row floating in
        // this popup, since it's never actually inside column/flick — and
        // its whole-scene walk could step straight out of the still-open
        // popover into the list behind it. This aborts instead of
        // following `next` once it leaves filterMenuColumn.
        function focusNext(item, forward) {
          var next = item
          for (var i = 0; i < 64 && next; i++) {
            next = next.nextItemInFocusChain(forward)
            if (!next || next === item) return
            var scan = next
            var inMenu = false
            while (scan) {
              if (scan === filterMenuColumn) { inMenu = true; break }
              scan = scan.parent
            }
            if (!inMenu) return
            if (next.activeFocusOnTab) { next.forceActiveFocus(); return }
          }
        }

        FilterMenuRow {
          width: parent.width
          label: "All accounts"
          selected: root.accountFilters.length === 0
          onClicked: root.accountFilters = []
        }

        Repeater {
          model: root.accountOptions
          delegate: FilterMenuRow {
            required property var modelData
            width: parent.width
            // Axis and SBI savings: the logo stands in for the name, so just the number.
            label: (modelData.bank === "AXIS" || modelData.bank === "SBI") && modelData.accountType === "checking"
              ? "••" + modelData.last4 : modelData.label
            network: modelData.network || ""
            bank: modelData.accountType === "checking" ? modelData.bank : ""
            selected: root.accountFilters.indexOf(modelData.key) !== -1
            onClicked: root.toggleAccountFilter(modelData.key)
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: Qt.darker(root.foreground, 1.8)
        }

        // Tracking view: which rows RECENT shows. The chosen one is highlighted
        // like the account pick above, and the popover stays open while you pick.
        FilterMenuRow {
          width: parent.width
          label: "All transactions"
          selected: root.trackFilter === "all"
          onClicked: root.trackFilter = "all"
        }

        FilterMenuRow {
          width: parent.width
          label: "Tracked only"
          selected: root.trackFilter === "tracked"
          onClicked: root.trackFilter = "tracked"
        }

        FilterMenuRow {
          width: parent.width
          label: "Not tracked only"
          selected: root.trackFilter === "untracked"
          onClicked: root.trackFilter = "untracked"
        }

      }
    }
  }

  // One row inside FilterMenuButton's popover — a selectable account (or
  // "All accounts"). Multi-select: each click toggles membership in
  // accountFilters, and the popover stays open while you pick more.
  component FilterMenuRow: BorderSurface {
    id: menuRow
    property string label: ""
    property string network: ""
    property string bank: ""
    property bool selected: false
    signal clicked()

    readonly property bool _hot: mouse.containsMouse || menuRow.activeFocus

    implicitHeight: Style.space(28)
    radius: Style.cornerRadius
    color: menuRow.selected
      ? Style.controlFill(true, false, root.foreground, Color.accent)
      : Style.controlFill(false, menuRow._hot, root.foreground, Color.accent)
    borderSpec: Border.none()

    activeFocusOnTab: true
    Keys.onReturnPressed: menuRow.clicked()
    Keys.onEnterPressed: menuRow.clicked()
    Keys.onSpacePressed: menuRow.clicked()
    // Every other focusable control in this widget wires Up/Down to a
    // focusNext — this one didn't, so arrow keys silently did nothing
    // while a filter-popover row was focused (Tab/Shift+Tab still
    // worked). filterMenuColumn's own confined focusNext, not
    // root.focusNext (see its definition for why).
    Keys.onDownPressed: filterMenuColumn.focusNext(menuRow, true)
    Keys.onUpPressed: filterMenuColumn.focusNext(menuRow, false)

    HdfcLogo {
      id: rowBankMark
      variant: "icon"
      visible: menuRow.bank === "HDFC"
      markSize: Style.spaceReal(9)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    AxisLogo {
      id: rowAxisMark
      visible: menuRow.bank === "AXIS"
      markSize: Style.spaceReal(9)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    SbiLogo {
      id: rowSbiMark
      visible: menuRow.bank === "SBI"
      markSize: Style.spaceReal(9)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    // Whichever bank mark this row shows (none for cards and "All accounts").
    readonly property bool hasBankMark: menuRow.bank === "HDFC" || menuRow.bank === "AXIS" || menuRow.bank === "SBI"
    readonly property Item bankMark: menuRow.bank === "AXIS" ? rowAxisMark
      : (menuRow.bank === "SBI" ? rowSbiMark : rowBankMark)

    BrandMark {
      id: rowMark
      network: menuRow.network
      markHeight: Style.spaceReal(9)
      anchors.left: menuRow.hasBankMark ? menuRow.bankMark.right : parent.left
      anchors.leftMargin: menuRow.hasBankMark ? Style.space(4) : Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      anchors.left: rowMark.visible ? rowMark.right : (menuRow.hasBankMark ? menuRow.bankMark.right : parent.left)
      // Axis and SBI rows show only "••NNNN" after the logo, so give it more room.
      anchors.leftMargin: menuRow.bank === "AXIS" || menuRow.bank === "SBI" ? Style.space(12) : Style.space(6)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Style.space(8)
      textFormat: Text.PlainText
      text: menuRow.label
      color: menuRow.selected ? Color.accent : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: menuRow.selected
      elide: Text.ElideRight
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: menuRow.clicked()
    }
  }

  // One bank in the balance row: its logo (the reload button) then its balance.
  component BankBalance: Item {
    id: chip
    property string bank: "hdfc"
    property string tooltip: ""
    property string balanceText: ""
    readonly property bool running: chip.bank === "axis" ? axisFetchProc.running
      : (chip.bank === "sbi" ? sbiFetchProc.running
        : (chip.bank === "icici" ? iciciFetchProc.running : fetchProc.running))
    // Only one fetch at a time: allowed while no other bank's fetch runs.
    readonly property bool allowed: chip.running || !root.anyFetchRunning

    implicitWidth: control.width + Style.spacing.xs + balanceLabel.implicitWidth
    implicitHeight: Style.space(28)
    width: implicitWidth
    height: implicitHeight

    FetchControl {
      id: control
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      bank: chip.bank
      running: chip.running
      allowed: chip.allowed
      idleTooltip: chip.tooltip
      foreground: root.foreground
      scrollIntoView: root.scrollIntoView
      onFetch: root.startFetch(chip.bank)
      onCancel: root.cancelFetch(chip.bank)
    }

    Text {
      id: balanceLabel
      anchors.left: control.right
      anchors.leftMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      // Elides rather than pushing the row over: the logos are the
      // buttons, so they are the last thing that should give way.
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: chip.balanceText !== "" ? chip.balanceText : "no balance yet"
      color: chip.balanceText !== "" ? Qt.darker(root.foreground, 1.3) : Qt.darker(root.foreground, 1.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.italic: chip.balanceText === ""
    }
  }

  // Text button for the RECENT selection controls, drawn with the same
  // surface and border as the other controls in this widget.
  component TextAction: BorderSurface {
    id: action
    property string label: ""
    signal triggered()

    readonly property bool _hot: actionMouse.containsMouse || action.activeFocus

    width: actionText.implicitWidth + Style.space(18)
    height: Style.space(26)
    radius: Style.cornerRadius
    color: Style.controlFill(action.activeFocus, action._hot, Color.accent, Color.accent)
    borderSpec: Border.controlSpec(action.activeFocus ? "focus" : (action._hot ? "hover-cursor" : "normal"), Color.accent, Color.accent)

    // Tab-stop only while actually shown — every call site's `visible`
    // already means "selectionMode on AND relevant" (see selectionRow),
    // so this can't stay a live tab stop once the row it's in is hidden.
    activeFocusOnTab: action.visible
    Keys.onReturnPressed: action.triggered()
    Keys.onEnterPressed: action.triggered()
    Keys.onSpacePressed: action.triggered()
    Keys.onDownPressed: root.focusNext(action, true)
    Keys.onUpPressed: root.focusNext(action, false)

    Text {
      id: actionText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: action.label
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.triggered()
    }
  }

  // One RECENT row, card-style: a circular direction icon, merchant name +
  // account pill, amount on the right — clicking the row toggles "tracked"
  // (shown as a tinted background instead of a switch), and hovering
  // reveals an edit pencil that swaps the row for an inline TextField to
  // rename this UPI counterparty's displayed merchant (the raw scraped
  // text is often an ugly UPI string). The rename is keyed by
  // Model.transactionGroupKey — not the transaction's own id — so it
  // applies to every past AND future transaction from the same
  // counterparty, not just this one row. Shown wherever a matching
  // transaction appears (RECENT, the bills) — it never changes the
  // underlying data, only the display.
  component TransactionCard: BorderSurface {
    id: card
    required property var txn

    property bool editing: false
    // RECENT rows get a checkbox in selection mode.
    property bool selectable: false
    readonly property bool selected: !!root.selectedIds[card.txn.id]
    // Expanded detail panel (raw merchant text, full date, full account,
    // explicit tracked state) below the collapsed row — separate from the
    // row-click/Enter/Space "toggle tracked" action so neither takes over
    // the other: click/Enter/Space still toggles tracked same as always,
    // the chevron (or Left/Right) is the only way to expand.
    property bool expanded: false
    readonly property bool showDetails: card.expanded && !card.editing
    readonly property string groupKey: Model.transactionGroupKey(txn)
    readonly property string displayMerchant: Model.transactionDisplayName(txn, store.transactionNameOverrides)
    readonly property bool isAxisSavings: card.txn.accountType === "checking" && card.txn.bank === "AXIS"
    readonly property bool isSbiSavings: card.txn.accountType === "checking" && card.txn.bank === "SBI"
    // Same rule as a BILLS row: a rename shows as typed, and the network
    // word is only stripped from the bank's own card name.
    readonly property string accountName: Model.cardLabelParts(
      Model.cardFallbackName(txn.accountType, txn.last4, store.cardOverviews, txn.bank),
      store.accountNameOverrides[txn.last4]).label + " ••" + txn.last4
    readonly property string note: Model.transactionNote(txn)
    readonly property bool isDebit: txn.amount < 0
    readonly property color directionColor: root.directionColor(txn)
    readonly property bool _hot: rowHover.hovered || card.activeFocus
    readonly property int collapsedHeight: Style.space(52)

    implicitHeight: card.collapsedHeight + (card.showDetails ? detailsPanel.implicitHeight + Style.space(10) : 0)
    radius: Style.cornerRadius
    opacity: cardMouse.pressed ? 0.75 : 1.0
    color: card.selected ? Util.alpha(Color.accent, 0.16)
      : card.txn.tracked ? root.rowBg(card.txn)
      : (card._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent")
    borderSpec: card.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 80 } }

    // Tracks hover over the whole card so the edit pencil and the hover
    // tint above only activate when the pointer is actually over it (or,
    // for keyboard users, when the card itself has focus — see `_hot`).
    HoverHandler {
      id: rowHover
    }

    activeFocusOnTab: !card.editing
    Keys.onReturnPressed: if (!card.editing) store.setTracked(card.txn.id, !card.txn.tracked)
    Keys.onEnterPressed: if (!card.editing) store.setTracked(card.txn.id, !card.txn.tracked)
    Keys.onSpacePressed: {
      if (card.editing) return
      if (root.selectionMode && card.selectable) root.toggleSelected(card.txn.id)
      else store.setTracked(card.txn.id, !card.txn.tracked)
    }
    // F2 for rename — Enter/Space already toggles tracked, so rename
    // needs its own key (F2 is the standard rename shortcut elsewhere;
    // confirmed no Hyprland keybind collision on this system).
    // X toggles the row's selection (for keyboard users; the checkbox does the same).
    Keys.onPressed: function (event) {
      if (card.editing) return
      if (event.key === Qt.Key_F2) { card.editing = true; event.accepted = true }
      else if (event.key === Qt.Key_X && card.selectable && root.selectionMode) { root.toggleSelected(card.txn.id); event.accepted = true }
    }
    Keys.onUpPressed: if (!card.editing) root.focusNext(card, false)
    Keys.onDownPressed: if (!card.editing) root.focusNext(card, true)
    // Left/Right collapse/expand the detail panel — unused by this
    // component otherwise (Up/Down already own row navigation).
    Keys.onLeftPressed: if (!card.editing) card.expanded = false
    Keys.onRightPressed: if (!card.editing) card.expanded = true

    // Fixed-height collapsed row, pinned to the top — the card's own
    // height grows downward below this when expanded, so this row's
    // layout (every anchor below is relative to it, not to `card`) never
    // has to account for the card's total height changing.
    Item {
      id: collapsedRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: card.collapsedHeight

      MouseArea {
        id: cardMouse
        anchors.fill: parent
        enabled: !card.editing
        cursorShape: Qt.PointingHandCursor
        onClicked: store.setTracked(card.txn.id, !card.txn.tracked)
      }

      Rectangle {
        id: checkBox
        visible: card.selectable && root.selectionMode && !card.editing
        width: Style.space(16)
        height: width
        radius: Style.space(3)
        color: card.selected ? Style.controlFill(false, true, Color.accent, Color.accent) : "transparent"
        border.width: 1
        border.color: card.selected ? Color.accent : Qt.darker(root.foreground, 1.8)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

        Behavior on color { ColorAnimation { duration: 120 } }

        Text {
          id: checkMark
          anchors.centerIn: parent
          text: ""
          color: Color.accent
          font.bold: true
          font.pixelSize: Style.font.caption
          scale: card.selected ? 1.0 : 0.0
          opacity: card.selected ? 1.0 : 0.0
          Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
          Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          cursorShape: Qt.PointingHandCursor
          onClicked: { card.forceActiveFocus(); root.toggleSelected(card.txn.id) }
        }
      }

      Rectangle {
        id: avatar
        visible: !card.editing
        width: Style.space(36)
        height: width
        radius: width / 2
        color: Util.alpha(card.directionColor, 0.22)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX + (card.selectable && root.selectionMode ? Style.space(24) : 0)
        anchors.verticalCenter: parent.verticalCenter

        // Clicking the circle expands or collapses the details below.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          enabled: !card.editing
          cursorShape: Qt.PointingHandCursor
          onClicked: card.expanded = !card.expanded
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: card.isDebit ? "↓" : "↑"
          color: card.directionColor
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
      }

      Column {
        id: titleCol
        visible: !card.editing
        anchors.left: avatar.right
        anchors.leftMargin: Style.space(10)
        // The stack, not the amount inside it: a grandchild is not a valid
        // anchor target, and anchoring to one leaves this column with no
        // right edge at all, so its text stops eliding.
        anchors.right: amountStack.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: card.displayMerchant
          color: root.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          BrandMark {
            network: Model.cardNetwork(card.txn, store.cardOverviews)
            markHeight: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          HdfcLogo {
            variant: "icon"
            visible: card.txn.accountType === "checking" && card.txn.bank === "HDFC"
            markSize: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          AxisLogo {
            visible: card.txn.accountType === "checking" && card.txn.bank === "AXIS"
            markSize: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          SbiLogo {
            visible: card.isSbiSavings
            markSize: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          Rectangle {
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.12)
            implicitWidth: pillText.implicitWidth + Style.space(10)
            implicitHeight: pillText.implicitHeight + Style.space(4)

            Text {
              id: pillText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              // Axis and SBI savings show the bank's logo beside the number, not the name.
              text: card.isAxisSavings || card.isSbiSavings ? "••" + card.txn.last4 : card.accountName
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // The raw UPI remark used to sit here, beside the account pill.
          // It was noise next to the balance the row now carries — often a
          // bank code or "Pay" — so it lives in the expanded card only.
        }
      }

      // The amount, and under it the balance the statement showed after
      // this transaction — the same stacked shape the bill rows use, and
      // dim, because it is context rather than the number you came for. A
      // credit card has no running balance, and rows saved before the
      // balance was scraped have none either: the line then disappears and
      // the amount centres on its own.
      Column {
        id: amountStack
        visible: !card.editing
        anchors.right: editBtn.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          id: amountText
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: Model.formatAmount(card.txn)
          color: card.directionColor
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }

        Text {
          id: balanceText
          visible: card.txn.balance !== null && card.txn.balance !== undefined
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: "bal " + Model.currencySymbol(card.txn.currency) + Model.formatGrouped(card.txn.balance)
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Reveals on hover OR keyboard focus (so Tab-only users can still
      // reach rename — hover alone would leave them unreachable).
      Text {
        id: editBtn
        visible: !card.editing && card._hot
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "✎"
        color: root.foreground
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: card.editing = true
        }
      }

      TextField {
        id: editField
        visible: card.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        text: card.displayMerchant
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onVisibleChanged: if (visible) { selectAll(); forceActiveFocus() }
        // card.editing = false hides this field, but a hidden item keeps
        // activeFocus until something else explicitly takes it (QtQuick
        // doesn't reassign focus just because the focused item went
        // invisible) — without restoring it to the card, the row's own
        // Up/Down/Enter/F2/X/Left/Right stop responding after a rename
        // until the user clicks or Tabs away and back. Deferred via
        // callLater for the same reason searchField's own Escape handler
        // defers it below — handing focus to a different item from inside
        // the currently-focused item's own key/edit event doesn't reliably
        // stick otherwise.
        onEditingFinished: {
          store.setTransactionName(card.groupKey, text)
          card.editing = false
          Qt.callLater(function () { card.forceActiveFocus() })
        }
        Keys.onEscapePressed: {
          card.editing = false
          Qt.callLater(function () { card.forceActiveFocus() })
        }
      }
    }

    // Expanded detail panel: raw (pre-rename) merchant text, full date +
    // full account name, and an explicit tracked checkbox — separate from
    // the row-click/Enter/Space toggle above, so expanding never changes
    // tracked state by itself.
    Column {
      id: detailsPanel
      visible: card.showDetails
      anchors.top: collapsedRow.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(46)
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(4)

      Rectangle {
        width: parent.width
        height: Style.spacing.hairline
        color: Qt.darker(root.foreground, 1.8)
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Raw: " + card.txn.merchant
        color: Qt.darker(root.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: Model.formatFullDate(card.txn.date) + "  ·  " + Model.formatAccount(card.txn, store.accountNameOverrides, store.cardOverviews)
        color: Qt.darker(root.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: card.note !== ""
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Remark: " + card.note
        color: Qt.darker(root.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: card.txn.balance !== null && card.txn.balance !== undefined
        width: parent.width
        textFormat: Text.PlainText
        // A derived balance was worked back from the account's current
        // balance for a row scraped before the statement's own figure was
        // kept; the next fetch reads the real one and replaces it.
        text: "Balance after this transaction: " + Model.currencySymbol(card.txn.currency)
          + Model.formatGrouped(card.txn.balance)
          + (card.txn.balanceDerived ? "  ·  worked out, not read from the statement" : "")
        color: Qt.darker(root.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // Item, not Row — a Row forbids left/right/fill/centerIn anchors on
      // its children entirely (confirmed: using one silently breaks the
      // whole Row's layout, not just that child), and this needs
      // anchors.fill on the MouseArea.
      Item {
        width: parent.width
        height: Style.space(20)

        Rectangle {
          id: trackedBox
          width: Style.space(14)
          height: width
          radius: Style.space(3)
          color: card.txn.tracked ? Color.accent : "transparent"
          border.width: Style.spacing.hairline
          border.color: card.txn.tracked ? Color.accent : Qt.darker(root.foreground, 1.4)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            visible: card.txn.tracked
            textFormat: Text.PlainText
            text: "✓"
            color: Color.popups.background
            font.bold: true
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          text: card.txn.tracked ? "Tracked (already recorded elsewhere)" : "Not tracked yet"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.left: trackedBox.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: store.setTracked(card.txn.id, !card.txn.tracked)
        }
      }
    }
  }
}
