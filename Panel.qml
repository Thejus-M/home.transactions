import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
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
  manageIpc: true

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
  // One run reads two accounts behind two logins: the savings account on
  // YONO and the credit card on sbicard.com, which is a separate site. So
  // it asks for an OTP twice, through the same box, and its done message
  // names both halves.
  // Fourth source: the ICICI fetcher. A credit card only — that profile
  // has no linked bank account — so it writes a card_cycles row and no
  // transactions, and its chip shows the card rather than a balance.
  readonly property string iciciDir: "/home/pc/Work/icici-statement-fetcher"
  readonly property string iciciOutputDir: iciciDir + "/output"
  property var iciciFetchStatus: ({})

  // Sixth source, and the first that is not a bank statement: photographed
  // shop bills. The reader is a separate project (its own venv needs OCR
  // and, optionally, a local LLM — dependencies the stdlib-only txdb must
  // never take on), reached the same way the fetchers are.
  readonly property string receiptStitcherDir: "/home/pc/Work/receipt-ledger-stitcher"
  readonly property string receiptsDir: "/run/media/pc/MY Drive/KDE Share"
  readonly property string sbiDir: "/home/pc/Work/sbi-statement-fetcher"
  readonly property string sbiOutputDir: sbiDir + "/output"
  property var sbiFetchStatus: ({})
  readonly property bool sbiOtpNeeded: sbiFetchProc.running && sbiFetchStatus.stage === "otp-needed"
  // Fifth source, and the first that is not a bank: the INDmoney
  // portfolio, read over that service's official read-only MCP server.
  // It writes the same status file shape as the four scrapers, so the
  // chip, the progress line and the cancel path need no special case —
  // but it needs no QR and no OTP, since it signs in once with OAuth
  // and renews itself after that.
  readonly property string indmoneyDir: "/home/pc/Work/indmoney-portfolio-fetcher"
  readonly property string indmoneyOutputDir: indmoneyDir + "/output"
  property var indmoneyFetchStatus: ({})
  readonly property bool anyFetchRunning: fetchProc.running || axisFetchProc.running
    || sbiFetchProc.running || iciciFetchProc.running || indmoneyFetchProc.running

  // Only one fetch runs at a time (see BankBalance.allowed), so "the fetch
  // that is running" is a single thing: its bank, and its status file's
  // contents. Every progress line, the error colour and the QR popup read
  // this rather than one bank's properties — each bank keeps its own, which
  // the chips and the reload buttons still read.
  readonly property string activeBank: fetchProc.running ? "HDFC"
    : axisFetchProc.running ? "Axis"
      : sbiFetchProc.running ? "SBI"
        : iciciFetchProc.running ? "ICICI"
          : indmoneyFetchProc.running ? "INDmoney" : ""
  readonly property var activeStatus: fetchProc.running ? fetchStatus
    : axisFetchProc.running ? axisFetchStatus
      : sbiFetchProc.running ? sbiFetchStatus
        : iciciFetchProc.running ? iciciFetchStatus
          : indmoneyFetchProc.running ? indmoneyFetchStatus : ({})
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
  // "bank" or "portfolio". One string with every section gated on it,
  // the way home.library drives its seven views — see the tab strip at
  // the top of the popup and the TabChip component below.
  property string tab: "bank"
  // The two tabs scroll independently; carrying one's offset into the
  // other lands the reader halfway down a list they have not seen.
  onTabChanged: if (flick) flick.contentY = 0
  // The strip's PORTFOLIO badge: figures a day or more old, or a fetch
  // that ended asking for a fresh sign-in. Both are states the number on
  // screen cannot show by itself.
  readonly property bool portfolioStale: !!store.portfolio.stale
    && (store.holdings.length > 0 || (store.portfolio.lastOutcome || "") === "error")
  readonly property var transactions: store.transactions
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked }).length
  readonly property int pendingTrackedCount: transactions.filter(function (t) { return t.tracked }).length

  // Photographed bills, unmatched ones first. receiptsToLink drives the
  // section header's count, the same way untrackedCount drives RECENT's.
  readonly property var receiptList: Model.receiptsSorted(store.receipts)
  // The RECEIPTS list folded away (its header and count stay).
  property bool receiptsCollapsed: false
  readonly property int receiptsToLink: receiptList.filter(function (r) { return r.state === "unmatched" }).length
  readonly property var linkedTransactionIds: {
    var ids = {}
    for (var i = 0; i < store.receipts.length; i++) {
      var r = store.receipts[i]
      if (r.state === "linked" && r.transactionId) ids[r.transactionId] = true
    }
    return ids
  }
  // All unmatched, plus a handful of the most recent filed/parked ones, so
  // a year of already-filed receipts never buries RECENT below them.
  // Bills still needing a decision always show; the ones already filed
  // (linked / cash / not a bill) stay out of the way until asked for - and
  // when nothing is waiting there is no RECEIPTS section at all (they are
  // still one click away from the note button in the RECENT header, and from
  // each transaction's own note icon).
  property bool showFiled: false
  readonly property int receiptsFiledCount: receiptList.filter(function (r) { return r.state !== "unmatched" }).length
  readonly property bool receiptsSectionShown: receiptList.length > 0 && (receiptsToLink > 0 || showFiled)
  readonly property var visibleReceipts: {
    var pending = receiptList.filter(function (r) { return r.state === "unmatched" })
    var filed = showFiled ? receiptList.filter(function (r) { return r.state !== "unmatched" }) : []
    return pending.concat(filed)
  }
  // The receipt the review window is open on, or null when it's closed.
  // One shared window rather than one Popup per row: 16+ receipts would
  // otherwise mean 16+ live Popup instances for a dialog only one of which
  // is ever open at a time.
  // Holds the id, not the receipt object itself: an object captured at
  // open time goes stale the moment refreshData() rebuilds receiptList
  // (e.g. after a reparse finishes), which is exactly how the full-screen
  // window used to keep showing the pre-reparse figures even once the new
  // ones had landed in the database. The id is looked up fresh in
  // receiptFullScreen's "r" below, every time receiptList changes.
  property var receiptDetailTarget: null
  function openReceiptDetail(r) { root.receiptDetailTarget = r.id }
  function closeReceiptDetail() { root.receiptDetailTarget = null }
  // The actual photo, full resolution, in the system's own viewer — never
  // inside this plugin's card, which is far too narrow to read a bill's
  // fine print at any size QML can draw it.
  function openReceiptPhoto(r) {
    if (!r || !r.storedPath) return
    Quickshell.execDetached(["xdg-open", root.widgetDir + "/data/" + r.storedPath])
  }
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

  onOpenedChanged: if (opened) {
    root.refreshData()
    // Reopening deep inside a list hides the summary the panel exists to
    // show, so every open starts at the top. The popup's content may not
    // be built yet on the first open, hence the guard.
    if (flick) flick.contentY = 0
  }

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

  // Photos are never deleted. Once a bill is linked its photo is compressed
  // and kept inside the database (and replaces the big file in place) by
  // receipt-ledger-stitcher. This catches up on start and every half hour,
  // and a link kicks it off a few seconds later (after the link has been
  // written) - the bar widget keeps running whether or not the popup is open.
  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.queueCompress()
  }

  Timer {
    id: compressDelay
    interval: 4000
    onTriggered: if (!receiptCompressProc.running) receiptCompressProc.running = true
  }
  function queueCompress() { compressDelay.restart() }

  Process {
    id: receiptCompressProc
    command: ["bash", "-c", "cd '" + root.receiptStitcherDir + "' && .venv/bin/python -m src.main compress-linked 2>&1"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { if (line.length > 0) console.log("receipt photo: " + line) }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) console.warn("Receipt photo compress exited " + exitCode)
      root.refreshData()
    }
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
    // The investments half (txdb/portfolio.py). Additive keys, so a
    // snapshot written before they existed simply leaves these empty and
    // the PORTFOLIO tab shows its "nothing fetched yet" line.
    property var portfolio: ({})     // totals + how old they are
    property var holdings: []        // what is held now, biggest first
    property var allocation: []      // [{bucket, value, pct}]
    property var portfolioActivity: []   // buys/sells worked out from snapshots
    property var portfolioHistory: []    // [{asOf, value, invested}], oldest first
    // Photographed bills (txdb/receipts.py). Additive, same reasoning as the
    // portfolio keys above: a snapshot from before receipts existed just
    // leaves this empty and the RECEIPTS section stays hidden.
    property var rawReceipts: []
    property var receiptOverrides: ({})   // optimistic: id -> {state, transactionId, ...}
    property var receipts: []

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
      portfolio = snap.portfolio || ({})
      holdings = snap.holdings || []
      allocation = snap.allocation || []
      portfolioActivity = snap.portfolioActivity || []
      portfolioHistory = snap.portfolioHistory || []
      trackedOverrides = {}
      rawTransactions = snap.transactions || []
      rawReceipts = snap.receipts || []
      receiptOverrides = {}
      recompute()
      recomputeReceipts()
      checkBillReminders()
    }

    function recomputeReceipts() {
      receipts = Model.receiptsWithOverrides(rawReceipts, receiptOverrides)
    }

    function linkReceipt(id, txnId) {
      // The full-screen window's "-> <date> · <amount> · <merchant>" line
      // (and the RECENT-style summary) reads straight off these txn*
      // fields - without them here, clicking a candidate looked like it
      // did nothing until the next full snapshot replaced this override.
      var txn = store.transactions.find(function (t) { return t.id === txnId })
      var o = Object.assign({}, receiptOverrides)
      o[id] = {
        state: "linked", transactionId: txnId, linkMissing: false,
        txnDate: txn ? txn.date : null, txnMerchant: txn ? txn.merchant : null,
        txnAmount: txn ? txn.amount : null, txnTracked: txn ? !!txn.tracked : false,
      }
      receiptOverrides = o
      recomputeReceipts()
      root.txdb(["receipt-link", id, txnId])
      root.queueCompress()
    }

    function unlinkReceipt(id) {
      var o = Object.assign({}, receiptOverrides)
      o[id] = { state: "unmatched", transactionId: null, linkMissing: false,
                txnDate: null, txnMerchant: null, txnAmount: null, txnTracked: false }
      receiptOverrides = o
      recomputeReceipts()
      root.txdb(["receipt-unlink", id])
    }

    function parkReceipt(id, state) {
      var o = Object.assign({}, receiptOverrides)
      o[id] = { state: state, transactionId: null }
      receiptOverrides = o
      recomputeReceipts()
      root.txdb(["receipt-" + (state === "cash" ? "cash" : "ignore"), id])
    }

    // Remove a bill altogether (row, photo, kept copy). Gone from the list at
    // once; the importer remembers the photo and never brings it back.
    function removeReceipt(id) {
      // The window moves on to the next bill (same order as the Prev/Next
      // arrows, wrapping at the end) instead of closing; it only closes when
      // that was the last bill.
      var list = root.visibleReceipts
      var at = list.findIndex(function (r) { return r.id === id })
      var next = null
      if (at >= 0 && list.length > 1) next = list[(at + 1) % list.length].id
      else if (at < 0 && list.length > 0) next = list[0].id
      rawReceipts = rawReceipts.filter(function (r) { return r.id !== id })
      recomputeReceipts()
      if (next !== null) root.receiptDetailTarget = next
      else root.closeReceiptDetail()
      root.txdb(["receipt-remove", id])
    }

    function setReceiptReviewed(id) {
      var o = Object.assign({}, receiptOverrides)
      o[id] = Object.assign({}, o[id], { needsReview: false })
      receiptOverrides = o
      recomputeReceipts()
      root.txdb(["receipt-review", id, "0"])
    }

    // A hand correction to one field, kept apart from the parsed figures
    // the same way linking is: fixing the total doesn't mean the GST
    // breakdown is suddenly trustworthy too, so needsReview/confidence are
    // left exactly as the parser set them - "Looks right" is the
    // person's separate, explicit sign-off on the whole reading.
    readonly property var _receiptFieldToJs: ({
      merchant: "merchant", date: "date", time: "time", invoice_no: "invoiceNo",
      gstin: "gstin", payment_hint: "paymentHint", total: "total", subtotal: "subtotal",
      discount: "discount", round_off: "roundOff",
    })
    readonly property var _receiptMoneyFields: ({ total: true, subtotal: true, discount: true, roundOff: true })
    function editReceiptField(id, field, value) {
      var jsKey = _receiptFieldToJs[field]
      var before = receipts.find(function (r) { return r.id === id })
      var mode = before ? Model.receiptTaxMode(before) : "inside"
      var patch = {}
      var trimmed = String(value || "").trim()
      patch[jsKey] = trimmed === "" ? null : (_receiptMoneyFields[jsKey] ? Number(trimmed) : trimmed)
      _patchReceipt(id, patch)
      root.txdb(["receipt-edit", id, field, trimmed])
      // The total follows the figures that make it up, on the spot:
      // subtotal - discount + round off.
      if (field === "subtotal" || field === "discount" || field === "round_off") _followTotal(id, mode)
    }

    // total = subtotal - |discount| + round off, from whatever subtotal the
    // receipt holds now (the sum of its items when it has none printed).
    function _followTotal(id, mode) {
      var cur = receipts.find(function (r) { return r.id === id })
      if (!cur) return
      var sub = cur.subtotal != null ? cur.subtotal : ((cur.items || []).length ? Model.receiptItemsSum(cur) : null)
      if (sub == null) return
      var total = Model.receiptExpectedTotal(cur, sub, mode !== "inside")
      _patchReceipt(id, { total: total })
      root.txdb(["receipt-edit", id, "total", total.toFixed(2)])
    }

    // One item's description/amount, by hand. Rebuilds this receipt's
    // items array with just that line changed and puts the whole array
    // in the override - receiptWarnings/receiptItemsSum already compute
    // the "items add up to X, the bill says Y" check live from r.items
    // and r.total/subtotal, so correcting an item here re-runs that check
    // immediately, the same instant the override takes effect, with no
    // separate recomputation step needed.
    function editReceiptItemField(id, lineNo, field, value) {
      var current = receipts.find(function (r) { return r.id === id })
      var items = ((current && current.items) || []).map(function (it) { return Object.assign({}, it) })
      var idx = items.findIndex(function (it) { return it.line === lineNo })
      if (idx < 0) return
      var mode = Model.receiptTaxMode(current)
      var trimmed = String(value || "").trim()
      var numeric = field === "amount" || field === "rate" || field === "qty" || field === "gst_rate"
      items[idx][field === "gst_rate" ? "gstRate" : field] = trimmed === "" ? null : (numeric ? Number(trimmed) : trimmed)
      // 3 x 50 is 150 without typing it: qty or rate changing re-works the
      // line's amount.
      var worked = null
      if ((field === "qty" || field === "rate") && items[idx].qty != null && items[idx].rate != null) {
        // keeps the line's GST factor (a rate before GST), see Model.receiptLineFactor
        worked = Model.receiptLineAmount(current.items[idx], items[idx].qty, items[idx].rate)
        items[idx].amount = worked
      }
      _patchReceipt(id, { items: items })
      root.txdb(["receipt-edit-item", id, String(lineNo), field, trimmed])
      if (worked !== null) root.txdb(["receipt-edit-item", id, String(lineNo), "amount", worked.toFixed(2)])
      // And the bill's subtotal and total follow the items.
      // (a line's own GST % does not change the bill's figures)
      if (numeric && field !== "gst_rate") recalcReceipt(id, mode)
    }

    function _patchReceipt(id, patch) {
      var o = Object.assign({}, receiptOverrides)
      o[id] = Object.assign({}, o[id], patch)
      receiptOverrides = o
      recomputeReceipts()
    }

    // A product added by hand. A blank amount is qty x rate, same rule as
    // receipts.add_item, so the optimistic line matches what the database
    // will hold once the write lands.
    function addReceiptItem(id, description, qty, unit, rate, amount, gst) {
      // "2 pc" typed into the quantity box: the number is the quantity, the
      // letters the unit (unless a unit was typed in its own box).
      var qm = /^\s*(\d*\.?\d+)\s*([^\d\s].*)?$/.exec(String(qty || ""))
      if (qm) { qty = qm[1]; if (!String(unit || "").trim() && qm[2]) unit = qm[2].trim() }
      var current = receipts.find(function (r) { return r.id === id })
      var items = ((current && current.items) || []).slice()
      var q = String(qty || "").trim() === "" ? null : Number(qty)
      var rt = String(rate || "").trim() === "" ? null : Number(rate)
      var amt = String(amount || "").trim() === "" ? (q !== null && rt !== null ? Math.round(q * rt * 100) / 100 : null) : Number(amount)
      if (amt === null || isNaN(amt) || (q !== null && isNaN(q)) || (rt !== null && isNaN(rt))) return false
      var g = String(gst || "").trim() === "" ? null : Number(gst)
      if (g !== null && isNaN(g)) return false
      var mode = current ? Model.receiptTaxMode(current) : "inside"
      var line = items.reduce(function (m, it) { return Math.max(m, it.line) }, 0) + 1
      items.push({ line: line, description: String(description || "").trim() || "(unnamed)", hsn: null,
                   qty: q, unit: String(unit || "").trim() || null, rate: rt, amount: amt, gstRate: g })
      _patchReceipt(id, { items: items })
      root.txdb(["receipt-add-item", id, String(description || ""), String(qty || ""),
                 String(unit || ""), String(rate || ""), String(amount || ""), String(gst || "")])
      recalcReceipt(id, mode)
      return true
    }

    function deleteReceiptItem(id, lineNo) {
      var current = receipts.find(function (r) { return r.id === id })
      var items = ((current && current.items) || []).filter(function (it) { return it.line !== lineNo })
      var mode = current ? Model.receiptTaxMode(current) : "inside"
      _patchReceipt(id, { items: items })
      root.txdb(["receipt-delete-item", id, String(lineNo)])
      recalcReceipt(id, mode)
    }

    function editReceiptTaxField(id, rate, field, value) {
      var current = receipts.find(function (r) { return r.id === id })
      var taxes = ((current && current.taxes) || []).map(function (t) { return Object.assign({}, t) })
      var trimmed = String(value || "").trim()
      taxes.forEach(function (t) { if (t.rate === rate) t[field] = trimmed === "" ? null : Number(trimmed) })
      _patchReceipt(id, { taxes: taxes })
      root.txdb(["receipt-edit-tax", id, String(rate), field, trimmed])
    }

    // Platform / delivery / service fees: extra charges on top of the
    // subtotal. The total follows them on the spot.
    function addReceiptFee(id, label, amount) {
      var current = receipts.find(function (r) { return r.id === id })
      var amt = Math.abs(Number(amount))
      if (!current || !(amt > 0)) return false
      var mode = Model.receiptTaxMode(current)
      var fees = (current.fees || []).slice()
      var line = fees.reduce(function (m, f) { return Math.max(m, f.line) }, 0) + 1
      var name = String(label || "").trim() || "Fee"
      fees.push({ line: line, label: name, amount: amt })
      _patchReceipt(id, { fees: fees })
      root.txdb(["receipt-add-fee", id, name, String(amt)])
      _followTotal(id, mode)
      return true
    }

    function editReceiptFee(id, line, field, value) {
      var current = receipts.find(function (r) { return r.id === id })
      if (!current) return
      var mode = Model.receiptTaxMode(current)
      var fees = (current.fees || []).map(function (f) { return Object.assign({}, f) })
      var f = fees.find(function (x) { return x.line === line })
      if (!f) return
      var trimmed = String(value || "").trim()
      if (field === "amount") {
        var n = Math.abs(Number(trimmed))
        if (!(n > 0)) return
        f.amount = n
      } else {
        f.label = trimmed || "Fee"
      }
      _patchReceipt(id, { fees: fees })
      root.txdb(["receipt-edit-fee", id, String(line), field, field === "amount" ? String(f.amount) : f.label])
      if (field === "amount") _followTotal(id, mode)
    }

    function deleteReceiptFee(id, line) {
      var current = receipts.find(function (r) { return r.id === id })
      if (!current) return
      var mode = Model.receiptTaxMode(current)
      _patchReceipt(id, { fees: (current.fees || []).filter(function (f) { return f.line !== line }) })
      root.txdb(["receipt-delete-fee", id, String(line)])
      _followTotal(id, mode)
    }

    // A tax figure the bill has but the parser missed (or got none of):
    // creates the slab when needed. `slab` is the slab rate (CGST 2.5% +
    // SGST 2.5% is the 5 slab).
    function addReceiptTax(id, slab, field, amount) {
      var current = receipts.find(function (r) { return r.id === id })
      var taxes = ((current && current.taxes) || []).map(function (t) { return Object.assign({}, t) })
      var at = taxes.findIndex(function (t) { return t.rate === slab })
      if (at < 0) {
        taxes.push({ rate: slab, taxable: null, cgst: null, sgst: null, igst: null, cess: null })
        at = taxes.length - 1
      }
      taxes[at][field] = amount
      _patchReceipt(id, { taxes: taxes })
      root.txdb(["receipt-add-tax", id, String(slab), field, String(amount)])
    }

    // Subtotal (before GST) and total follow the items, under the bill's own
    // tax mode (receipts.recalc_totals does the same on disk).
    function recalcReceipt(id, mode) {
      var current = receipts.find(function (r) { return r.id === id })
      if (!current || !(current.items || []).length) return
      var rc = Model.receiptRecompute(current, mode)
      _patchReceipt(id, { subtotal: rc.subtotal, total: rc.total })
      root.txdb(["receipt-recalc", id])
    }

    // The Recalculate button: rework the whole bill from its items, then
    // verify. A line with a qty and a rate but no amount gets qty x rate (a
    // line that has an amount is left alone - a weighed item's printed amount
    // is the bill's own rounding), the subtotal and total follow, and since
    // the figures have just been reconciled the parser's stale warnings and
    // "check this parse" flag are cleared. Whatever still does not add up
    // (the live checks) stays on screen.
    function verifyReceipt(id) {
      var current = receipts.find(function (r) { return r.id === id })
      if (!current || !(current.items || []).length) return
      var mode = Model.receiptTaxMode(current)
      var items = current.items.map(function (it) {
        var o = Object.assign({}, it)
        if (o.amount == null && o.qty != null && o.rate != null) o.amount = Math.round(o.qty * o.rate * 100) / 100
        return o
      })
      var rc = Model.receiptRecompute(Object.assign({}, current, { items: items }), mode)
      _patchReceipt(id, { items: items, subtotal: rc.subtotal, total: rc.total, warnings: [], needsReview: false })
      root.txdb(["receipt-recalc", id, "verify"])
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

    // The same toggle for an investment. `tracked` has no foreign key
    // (see txdb/db.py), so an activity row's id goes in the same table
    // and the same command writes it — but the optimistic patch belongs
    // on portfolioActivity, which recompute() does not touch.
    function setPortfolioTracked(id, value) {
      portfolioActivity = portfolioActivity.map(function (row) {
        return row.id === id ? Object.assign({}, row, { tracked: !!value }) : row
      })
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
    // Every source that can finish a fetch, so a new one cannot show up
    // in a notification as its own raw code again (ICICI did).
    var name = ({ HDFC: "HDFC", AXIS: "Axis", SBI: "SBI", ICICI: "ICICI",
                  INDMONEY: "INDmoney" })[notifyBank] || notifyBank
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

  // "Fetch all": HDFC, then Axis, then SBI, then ICICI, one after another.
  // They can't really run at once — each one needs you for a QR scan or an
  // OTP — so this queues the rest and starts the next the moment one exits
  // cleanly (see the four onExited handlers below). Cancelling whichever
  // one is running empties the queue too, so the chain stops rather than
  // quietly resuming on its own later.
  property var fetchQueue: []
  // True for the whole chain, including while the last bank in it is
  // still running (fetchQueue is already empty by then) — fetchQueue alone
  // can't tell "the chain's last step" apart from "a single manual fetch".
  property bool fetchAllActive: false

  function startFetchAll() {
    if (root.anyFetchRunning) return
    root.fetchAllActive = true
    root.fetchQueue = ["axis", "sbi", "icici", "indmoney"]
    root.startFetch("hdfc")
  }

  function advanceFetchQueue() {
    if (root.fetchQueue.length === 0) { root.fetchAllActive = false; return }
    var next = root.fetchQueue[0]
    root.fetchQueue = root.fetchQueue.slice(1)
    root.startFetch(next)
  }

  function startFetch(bank) {
    fetchStartedMs = Date.now()
    if (bank === "axis") axisFetchProc.running = true
    else if (bank === "sbi") sbiFetchProc.running = true
    else if (bank === "icici") iciciFetchProc.running = true
    else if (bank === "indmoney") indmoneyFetchProc.running = true
    else fetchProc.running = true
  }

  function cancelFetch(bank) {
    root.fetchQueue = []
    root.fetchAllActive = false
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
    } else if (bank === "indmoney") {
      indmoneyFetchCancelled = true
      indmoneyCancelProc.running = true
      indmoneyFetchProc.running = false
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
      root.advanceFetchQueue()
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
      root.advanceFetchQueue()
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
      // (There used to be a store.reload() here. store has no such
      // function, so every ICICI fetch ended in a silent TypeError; the
      // data/.changed watcher was doing the reload all along.)
      root.advanceFetchQueue()
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
      root.advanceFetchQueue()
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

  // Imports new bill photos and parses them. Deliberately its own Process,
  // never routed through root.txdb(...): OCR over a handful of photos is
  // minutes of work, and that queue runs one write at a time, so a scan
  // would stall every other widget write (a tracked toggle, a rename)
  // behind it for the whole run. Its own re-fetch of the snapshot on exit
  // is what picks up whatever it filed.
  Process {
    id: receiptImportProc
    // No file redirection: stdout feeds receiptImportOutput below so the
    // scan's own progress (which photo it's on, the model's reply as it
    // streams) shows up live instead of behind a silent "…" icon for
    // however many minutes several photos take. The leading printf (not
    // echo) ends with the same \0 boundary main.py's own _emit() uses, so
    // this first line arrives as its own SplitParser "read" exactly like
    // every line after it, instead of sitting unflushed until python's
    // first \0 happens to come along.
    command: ["bash", "-c",
      "printf 'Scanning " + root.receiptsDir + " ...\\n\\0' && cd '" + root.receiptStitcherDir
      + "' && .venv/bin/python -m src.main scan --method H-vision-llm-gemma --folder '"
      + root.receiptsDir + "' 2>&1"]
    // SplitParser, not StdioCollector: StdioCollector's `text` is
    // read-only, so a second scan had no way to clear the first one's
    // output - the box just kept whatever the previous run left in it,
    // caught live when a stale truncated reply from a past run was still
    // sitting there after a brand new click. `text` here is a plain
    // property this file owns outright, reset in the click handler below
    // before the Process even starts.
    stdout: SplitParser {
      id: receiptImportOutput
      property string text: ""
      splitMarker: "\x00"
      onRead: function (data) { text += data }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        console.warn("Receipt import exited " + exitCode + ": " + receiptImportOutput.text)
      } else {
        // A clean run clears its log the moment it is done; a failed one
        // stays until closed, since that is the one worth reading.
        receiptImportOutput.text = ""
      }
      root.refreshData()
    }
  }

  // Re-reads one already-imported receipt with the LLM, for the "Reparse
  // with AI" action. Its own Process for the same reason as the import one
  // above: one bill's LLM call is tens of seconds, and the txdb write queue
  // must never stall behind it.
  Process {
    id: receiptReparseProc
    property string receiptId: ""
    // No file redirection here: stdout is piped straight to
    // receiptReparseOutput below so the UI can show the model's reply as
    // it streams in, not just a static "Reparsing…" label for however
    // long the call takes. stderr is folded in with it so a crash shows
    // up in the same place rather than vanishing silently.
    command: ["bash", "-c",
      "printf 'Launching reparse ...\\n\\0' && cd '" + root.receiptStitcherDir
      + "' && .venv/bin/python -m src.main reparse-one '" + receiptId
      + "' --method H-vision-llm-gemma 2>&1"]
    // See receiptImportOutput above for why this is SplitParser and not
    // StdioCollector: a resettable `text` is the whole point.
    stdout: SplitParser {
      id: receiptReparseOutput
      property string text: ""
      splitMarker: "\x00"
      onRead: function (data) { text += data }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        console.warn("Receipt reparse exited " + exitCode + ": " + receiptReparseOutput.text)
      }
      root.refreshData()
      root.announceReparse(receiptId, exitCode === 0)
    }
  }

  // A sound and a desktop notification when a re-read ends - it takes tens
  // of seconds, long enough that nobody is watching the window.
  function announceReparse(receiptId, ok) {
    var r = store.receipts.find(function (x) { return x.id === receiptId })
    var name = (r && r.merchant) ? r.merchant : "the bill"
    var sound = "/usr/share/sounds/freedesktop/stereo/" + (ok ? "complete.oga" : "dialog-error.oga")
    Quickshell.execDetached(["bash", "-c", "pw-play '" + sound + "' >/dev/null 2>&1 || true"])
    Quickshell.execDetached([
      Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
      "--app-name", "home.transactions",
      ok ? "Receipt re-read" : "Receipt re-read failed",
      ok ? ("Finished reading " + name + " - check the figures.") : ("Could not re-read " + name + ".")
    ])
  }

  property bool indmoneyFetchCancelled: false

  Process {
    id: indmoneyCancelProc
    command: ["bash", "-c", "cd '" + root.indmoneyDir + "' && mkdir -p output && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && grep -qa src.main /proc/$PID/cmdline 2>/dev/null && kill -TERM -- -$PID 2>/dev/null; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/.indmoney-fetch-status.json.tmp && mv output/.indmoney-fetch-status.json.tmp output/indmoney-fetch-status.json"]
  }

  // Runs the INDmoney portfolio fetch. No stdinEnabled and no QR: the
  // OAuth sign-in happened once, in a browser, through
  // `bin/indmoney-login`, and every run since renews its own token. When
  // that stops working the fetcher exits 2 with "sign in again" in its
  // message, which the portfolio tab shows in red.
  Process {
    id: indmoneyFetchProc
    command: ["setsid", "bash", "-c", "cd '" + root.indmoneyDir + "' && mkdir -p output && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.indmoneyFetchCancelled) { root.indmoneyFetchCancelled = false; return }
      root.notifyFetchResult("INDMONEY")
      root.advanceFetchQueue()
    }
  }

  FileView {
    id: indmoneyFetchStatusFile
    path: root.indmoneyOutputDir + "/indmoney-fetch-status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.indmoneyFetchStatus = JSON.parse(text() || "{}") } catch (e) { root.indmoneyFetchStatus = {} }
    }
    onLoadFailed: root.indmoneyFetchStatus = ({})
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

        // BANK | PORTFOLIO. One string and two buttons, with each
        // section gated on it — the same arrangement home.library uses
        // for its seven tabs. No StackLayout: the sections are already
        // siblings in one Flickable, and keeping them so means the
        // keyboard chain, the scroll position and the search box carry
        // across without special cases.
        Row {
          width: parent.width
          spacing: Style.spacing.xs

          TabChip {
            label: "BANK"
            tab: "bank"
            // The untracked count lives on the bar icon; on the strip it
            // says which tab the badge is about.
            badge: root.untrackedCount > 0 ? String(root.untrackedCount) : ""
          }

          TabChip {
            label: "PORTFOLIO"
            tab: "portfolio"
            badge: root.portfolioStale ? "!" : ""
          }
        }

        // Compact month summary + top-3-spenders, two lines, no header or
        // separator of their own — replaces the old PanelHero block
        // (which just re-displayed "Transactions"/"N to track", redundant
        // with the icon the user already clicked) and a 5-row spender
        // list (now one elided line).
        Column {
          visible: root.tab === "bank"
          width: parent.width
          spacing: Style.spacing.sm

          Item {
            width: parent.width
            height: Math.max(monthSummaryLabel.implicitHeight, fetchAllIcon.height)

            Text {
              id: monthSummaryLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
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
              anchors.right: fetchAllIcon.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.formatAmount({ amount: root.monthSummary.income, currency: root.monthSummary.currency }) + " in"
              color: root.creditColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            // Fetch all: HDFC first (its QR needs a scan before anything
            // else can start), then Axis, SBI and ICICI in turn, each one
            // starting the moment the last exits cleanly. A cancel on
            // whichever bank is running stops the chain too (see
            // startFetchAll/advanceFetchQueue/cancelFetch above). Icon
            // only, in the topmost row — the four bank chips below already
            // carry the "reload one bank" affordance as their own logos.
            BorderSurface {
              id: fetchAllIcon
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              height: width
              radius: width / 2
              readonly property bool _hot: fetchAllHover.hovered || fetchAllIcon.activeFocus
              color: Style.controlFill(fetchAllIcon.activeFocus, _hot, root.foreground, Color.accent)
              borderSpec: Border.controlSpec(
                fetchAllIcon.activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"),
                root.foreground, Color.accent)
              opacity: root.anyFetchRunning && !root.fetchAllActive ? 0.4 : 1.0

              activeFocusOnTab: true
              Keys.onReturnPressed: if (!root.anyFetchRunning) root.startFetchAll()
              Keys.onEnterPressed: if (!root.anyFetchRunning) root.startFetchAll()
              Keys.onSpacePressed: if (!root.anyFetchRunning) root.startFetchAll()
              Keys.onDownPressed: root.focusNext(fetchAllIcon, true)
              Keys.onUpPressed: root.focusNext(fetchAllIcon, false)

              Icon {
                id: fetchAllGlyph
                anchors.centerIn: parent
                iconSize: Style.space(14)
                color: root.foreground

                // Keeps turning for the whole chain, not just one bank's
                // own fetch — fetchAllActive covers HDFC through ICICI.
                NumberAnimation on rotation {
                  running: root.fetchAllActive
                  from: 0; to: 360
                  duration: 900
                  loops: Animation.Infinite
                }

                // Stop level when the chain ends, wherever the spin had
                // reached — same as FetchControl's own logo button.
                Connections {
                  target: root
                  function onFetchAllActiveChanged() {
                    if (!root.fetchAllActive) fetchAllGlyph.rotation = 0
                  }
                }
              }

              HoverHandler { id: fetchAllHover }
              ToolTip.visible: fetchAllHover.hovered
              ToolTip.text: root.fetchAllActive ? "Fetching all…" : "Fetch all (HDFC, Axis, SBI, ICICI, INDmoney)"
              ToolTip.delay: 400

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  fetchAllIcon.forceActiveFocus()
                  if (!root.anyFetchRunning) root.startFetchAll()
                }
              }
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
          visible: root.tab === "bank" && root.cardOverviewList.length > 0
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

          visible: root.tab === "bank" && root.creditLimits.length > 0
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
          visible: root.tab === "bank" && root.creditLimits.length > 0 && height > 0
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
          visible: root.tab === "bank" && root.cardOverviewList.length > 0
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

        PanelSeparator { visible: root.tab === "bank" && root.cardOverviewList.length > 0; foreground: root.foreground }

        // RECEIPTS: photographed bills, stitched to the transaction that
        // paid for them. Unmatched ones are the action queue (BILLS is what
        // I owe, RECEIPTS is what I bought and haven't filed), so it sits
        // between BILLS and RECENT's raw ledger. Shares its row with the
        // import button, the way BILLS shares with its totals.
        Item {
          visible: root.tab === "bank" && root.receiptsSectionShown
          width: parent.width
          height: Math.max(receiptsHeader.implicitHeight, receiptsTools.implicitHeight)

          // Fold / unfold the whole list: the chevron, or the header text.
          PanelActionButton {
            id: receiptsFold
            size: Style.space(22)
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.receiptsCollapsed ? "▸" : "▾"
            tooltipText: root.receiptsCollapsed ? "Show the receipts" : "Fold the receipts away"
            foreground: root.foreground
            focusable: true
            bordered: true
            Keys.onDownPressed: root.focusNext(receiptsFold, true)
            Keys.onUpPressed: root.focusNext(receiptsFold, false)
            onClicked: root.receiptsCollapsed = !root.receiptsCollapsed
          }

          PanelSectionHeader {
            id: receiptsHeader
            anchors.left: receiptsFold.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.receiptsToLink > 0
              ? ("RECEIPTS  ·  " + root.receiptsToLink + " TO LINK" + (root.showFiled ? "  ·  " + root.receiptsFiledCount + " LINKED" : ""))
              : ("LINKED RECEIPTS  ·  " + root.receiptsFiledCount)
            foreground: root.foreground

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.receiptsCollapsed = !root.receiptsCollapsed
            }
          }

          Row {
            id: receiptsTools
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              id: filedToggleBtn
              size: Style.space(22)
              visible: root.receiptsFiledCount > 0
              iconText: "󰎞"
              tooltipText: root.showFiled ? "Hide the linked bills" : "Show the linked bills (" + root.receiptsFiledCount + ")"
              foreground: root.showFiled ? Color.accent : root.foreground
              focusable: true
              bordered: true
              Keys.onDownPressed: root.focusNext(filedToggleBtn, true)
              Keys.onUpPressed: root.focusNext(filedToggleBtn, false)
              onClicked: root.showFiled = !root.showFiled
            }

            PanelActionButton {
              id: importReceiptsBtn
              size: Style.space(22)
              iconText: receiptImportProc.running ? "…" : "+"
              tooltipText: "Import new photos from " + root.receiptsDir
              foreground: root.foreground
              focusable: true
              bordered: true
              enabled: !receiptImportProc.running
              Keys.onDownPressed: root.focusNext(importReceiptsBtn, true)
              Keys.onUpPressed: root.focusNext(importReceiptsBtn, false)
              onClicked: { receiptImportOutput.text = ""; receiptImportProc.running = true }
            }
          }
        }

        // The scan's own progress, live: which photo it's on and the
        // model's reply as it streams - selectable/copyable, same
        // reasoning as the per-receipt reparse output below.
        StreamBox {
          visible: root.tab === "bank" && (receiptImportProc.running || receiptImportOutput.text.length > 0)
          width: parent.width - 2 * Style.spacing.rowPaddingX
          x: Style.spacing.rowPaddingX
          boxHeight: Style.space(150)
          text: receiptImportOutput.text
          closable: !receiptImportProc.running
          onClosed: receiptImportOutput.text = ""
        }

        Column {
          id: receiptsList
          visible: root.tab === "bank" && root.receiptsSectionShown && (!root.receiptsCollapsed || height > 0)
          width: parent.width
          spacing: Style.spacing.xxs
          clip: true
          height: root.receiptsCollapsed ? 0 : implicitHeight
          opacity: root.receiptsCollapsed ? 0 : 1
          Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 150 } }

          Repeater {
            model: root.visibleReceipts
            delegate: ReceiptRow {
              id: receiptRowDelegate
              required property var modelData
              width: parent.width
              receipt: receiptRowDelegate.modelData
              Keys.onUpPressed: root.focusNext(receiptRowDelegate, false)
              Keys.onDownPressed: root.focusNext(receiptRowDelegate, true)
            }
          }
        }

        PanelSeparator { visible: root.tab === "bank" && root.receiptsSectionShown; foreground: root.foreground }

        // RECENT's own header shares its row with the Filter popover +
        // search-toggle button (right-aligned) instead of sitting on a
        // separate row above it — saves a full row of vertical space,
        // and a separator between them would've been redundant with the
        // one above this Item anyway.
        Item {
          visible: root.tab === "bank"
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

            // The linked bills live out of sight; this brings them up (the
            // RECEIPTS section appears with just those, or alongside the
            // ones still to link).
            PanelActionButton {
              id: filedToggleRecentBtn
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              visible: root.receiptsFiledCount > 0
              iconText: "󰎞"
              tooltipText: root.showFiled ? "Hide the linked bills" : "Linked bills (" + root.receiptsFiledCount + ")"
              foreground: root.showFiled ? Color.accent : root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              Keys.onDownPressed: root.focusNext(filedToggleRecentBtn, true)
              Keys.onUpPressed: root.focusNext(filedToggleRecentBtn, false)
              onClicked: root.showFiled = !root.showFiled
            }

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
          visible: root.tab === "bank" && root.selectionMode

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
          // One box for both tabs: on BANK it narrows RECENT, on
          // PORTFOLIO it narrows HOLDINGS (PortfolioSection reads the
          // same root.searchQuery).
          placeholderText: root.tab === "bank" ? "Search transactions…" : "Search holdings…"
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
          visible: root.tab === "bank"
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

        // The investments half. A file of its own because this one is
        // long enough; the cost is the plumbing below, since a separate
        // file cannot see root or store (the same trade FetchControl.qml
        // already makes).
        PortfolioSection {
          id: portfolioSection
          visible: root.tab === "portfolio"
          width: parent.width

          portfolio: store.portfolio
          holdings: store.holdings
          allocation: store.allocation
          activity: store.portfolioActivity
          history: store.portfolioHistory

          foreground: root.foreground
          creditColor: root.creditColor
          debitColor: root.debitColor
          pendingColor: root.pendingColor

          searchQuery: root.searchQuery
          focusNext: root.focusNext
          scrollIntoView: root.scrollIntoView

          fetchRunning: indmoneyFetchProc.running
          // Same rule as the bank chips: one fetch at a time.
          fetchAllowed: indmoneyFetchProc.running || !root.anyFetchRunning
          fetchStatusText: root.activeBank === "INDmoney" ? root.activeStatusText : ""

          onFetch: root.startFetch("indmoney")
          onCancel: root.cancelFetch("indmoney")
          onToggleTracked: function (id, value) { store.setPortfolioTracked(id, value) }
        }
      }
    }

    ScrollWheelArea { anchors.fill: flick; target: flick }

    // The receipt review window: a true full-screen overlay — its own
    // layer-shell surface, not this popup's small ~340px card — with the
    // photo large on the left and everything the parser found plus the
    // verify actions on the right. The card this widget normally draws is
    // nowhere near wide enough to show a bill's fine print at any size QML
    // can fit into it; this is the same widget's own styling, just given
    // the whole screen to work with instead of a corner of it.
  }
  PanelWindow {
    id: receiptFullScreen
    visible: root.receiptDetailTarget !== null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-transactions-receipt"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    property bool pickingLink: false
    // One switch for every editable field at once, not a pencil per
    // field: turning it on highlights every place a value can be typed,
    // off reverts them all to plain text.
    // Only the add/remove-products controls hang off this; every value on the
    // bill edits on its own when clicked.
    property bool editingFields: false
    // What the "add tax" row adds: "split" (CGST + SGST) or "igst".
    property string taxKind: "split"
    // The photo's info panel (taken, camera, size, where it came from).
    property bool showInfo: false
    // The bill card folded down to its title and total.
    property bool billCollapsed: false
    // The whole right side (toolbar + bill) folded to a thin strip, so the
    // photo or the transaction list can use the full width.
    property bool detailsCollapsed: false
    // The remove-bill button asks twice: the first click arms it for a few
    // seconds, the second one removes.
    property bool confirmRemove: false
    Timer { id: confirmRemoveTimer; interval: 3500; onTriggered: receiptFullScreen.confirmRemove = false }
    // Set the moment a transaction is picked, so the bill flashes once it is linked.
    property bool justLinked: false
    // The GST % column shows when any line prints one, and while editing
    // products (so one can be added to a line that has none).
    readonly property bool showGst: receiptFullScreen.editingFields
      || (receiptFullScreen.r.items || []).some(function (it) { return it.gstRate != null })
    // Zoom and an extra rotation on top of whatever the parser already
    // detected — both purely for viewing, reset whenever a different
    // receipt opens, below. Zoom is a scale factor: at 1.0 the photo just
    // fits the pane, same as before this existed.
    property real photoZoom: 1.0
    property int extraRotation: 0
    // Looked up by id from the live receiptList every time either
    // changes, rather than a snapshot captured at open time — so a
    // reparse (or any other write) that lands while this window is open
    // shows up here as soon as refreshData() rebuilds receiptList,
    // instead of the figures from whenever the window was opened.
    readonly property var r: {
      var id = root.receiptDetailTarget
      if (id === null) return ({})
      var list = root.receiptList
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === id) return list[i]
      }
      return ({})
    }
    onVisibleChanged: if (!receiptFullScreen.visible) {
      receiptFullScreen.pickingLink = false
      receiptFullScreen.editingFields = false
      receiptFullScreen.showInfo = false
      receiptFullScreen.billCollapsed = false
      receiptFullScreen.detailsCollapsed = false
      receiptFullScreen.confirmRemove = false
    }
    // A different receipt opened (including via Prev/Next below) — its
    // photo starts fresh, not zoomed or rotated the way the last one
    // ended up.
    readonly property var linkedTxn: {
      var id = receiptFullScreen.r.transactionId
      if (!id) return null
      var list = store.transactions
      for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
      return null
    }
    // The zoom and the extra turn are reset only when a DIFFERENT bill is
    // shown. `r` itself is rebuilt on every refresh of the data (an edit, a
    // link, a re-read finishing), which used to throw the zoom away mid-read.
    // Is the open bill one the list is showing (not a linked one hidden from it)?
    readonly property bool inVisibleList: root.visibleReceipts.some(function (x) { return x.id === receiptFullScreen.r.id })
    readonly property string billId: receiptFullScreen.r.id || ""
    onBillIdChanged: { receiptFullScreen.photoZoom = 1.0; receiptFullScreen.extraRotation = 0 }

    // Steps to the previous/next receipt in the same order the RECEIPTS
    // section lists them, so you can work through every bill needing a
    // look without closing this window in between. Wraps around at
    // either end rather than stopping, since "next" from the last one
    // round-tripping to the first is more useful than a dead click.
    //
    // Only through the bills the list is showing: the ones still to link,
    // and the linked ones only while "show linked" is on. A bill that was
    // just linked (and so is hidden) is left behind by the first step, which
    // lands on the first (or last) of the visible ones.
    function stepReceipt(delta) {
      var list = root.visibleReceipts
      if (!list || list.length === 0) return
      var id = receiptFullScreen.r.id
      var at = -1
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === id) { at = i; break }
      }
      if (at < 0) root.receiptDetailTarget = (delta >= 0 ? list[0] : list[list.length - 1]).id
      else root.receiptDetailTarget = list[(at + delta + list.length) % list.length].id
    }

    // Scrim: click it to close, same convention as every other
    // full-screen overlay in this shell (SpeedTestOverlay's own).
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)
      MouseArea { anchors.fill: parent; onClicked: root.closeReceiptDetail() }
    }

    Item {
      id: fsCard
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(960))
      height: Math.min(parent.height - Style.space(80), Style.space(680))
      focus: true
      Keys.onEscapePressed: function (event) { root.closeReceiptDetail(); event.accepted = true }
      Keys.onLeftPressed: receiptFullScreen.stepReceipt(-1)
      Keys.onRightPressed: receiptFullScreen.stepReceipt(1)

      // Swallows clicks on the card itself so they don't fall through to
      // the scrim's close-on-click behind it.
      MouseArea { anchors.fill: parent; onClicked: {} }

      BorderSurface {
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        radius: Style.cornerRadius
      }

      // Prev / position / Next, left of Close — paging through every
      // receipt in the list without leaving this window.
      Row {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: Style.space(10)
        spacing: Style.space(6)

        PanelActionButton {
          size: Style.space(28)
          iconText: "<"
          tooltipText: "Previous bill (Left arrow)"
          foreground: root.foreground
          focusable: true
          enabled: root.visibleReceipts.length > 1 || (root.visibleReceipts.length === 1 && !receiptFullScreen.inVisibleList)
          onClicked: receiptFullScreen.stepReceipt(-1)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: {
            var list = root.visibleReceipts
            var at = -1
            for (var i = 0; i < list.length; i++) { if (list[i].id === receiptFullScreen.r.id) { at = i; break } }
            return at < 0 ? "" : (at + 1) + " / " + list.length
          }
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        PanelActionButton {
          size: Style.space(28)
          iconText: ">"
          tooltipText: "Next bill (Right arrow)"
          foreground: root.foreground
          focusable: true
          enabled: root.visibleReceipts.length > 1 || (root.visibleReceipts.length === 1 && !receiptFullScreen.inVisibleList)
          onClicked: receiptFullScreen.stepReceipt(1)
        }
      }

      PanelActionButton {
        id: fsCloseBtn
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.space(10)
        size: Style.space(28)
        iconText: "x"
        tooltipText: "Close (Esc)"
        foreground: root.foreground
        focusable: true
        onClicked: root.closeReceiptDetail()
      }

      Row {
        anchors.fill: parent
        anchors.margins: Style.space(20)
        anchors.topMargin: Style.space(48)
        spacing: Style.space(20)

        // LEFT: the photo, as large as the window allows — zoomable
        // (wheel, or the +/- buttons) and rotatable on top of whatever
        // the parser already detected, for the shots its own guess got
        // wrong or that are just easier to read turned a little further.
        Rectangle {
          id: fsPhotoPane
          width: receiptFullScreen.detailsCollapsed ? parent.width - Style.space(44) - parent.spacing : parent.width * 0.56
          height: parent.height
          radius: Style.cornerRadius
          color: Qt.darker(root.foreground, 2.4)
          clip: true
          visible: !receiptFullScreen.pickingLink
            && !!(receiptFullScreen.r.storedPath || receiptFullScreen.r.thumbPath)

          Flickable {
            id: photoFlick
            anchors.fill: parent
            anchors.margins: Style.space(6)
            anchors.bottomMargin: Style.space(40)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: photoImg.width
            contentHeight: photoImg.height

            Image {
              id: photoImg
              // Grows the Flickable's real content size with zoom (rather
              // than a visual-only `scale`, which panning math would then
              // have to second-guess) — PreserveAspectFit still fits the
              // photo's own aspect ratio within whatever box this is.
              width: photoFlick.width * receiptFullScreen.photoZoom
              height: photoFlick.height * receiptFullScreen.photoZoom
              source: receiptFullScreen.r.storedPath
                ? ("file://" + root.widgetDir + "/data/" + receiptFullScreen.r.storedPath)
                : (receiptFullScreen.r.thumbPath
                    ? ("file://" + root.widgetDir + "/data/" + receiptFullScreen.r.thumbPath) : "")
              rotation: ((receiptFullScreen.r.rotation || 0) + receiptFullScreen.extraRotation + 360) % 360
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: false
              sourceSize.height: Style.spaceReal(1400)
            }
          }

          // A transparent MouseArea stacked on top of the Flickable (it is
          // declared after it, so it is the topmost item here and is hit
          // first) just to claim the wheel: a WheelHandler placed either
          // inside or as an ancestor of the Flickable never actually saw
          // the event, since Flickable's own built-in wheel-scroll claims
          // it first either way — this is the one placement that wins.
          // acceptedButtons: NoButton means it never intercepts the press
          // itself, so dragging to pan once zoomed in still reaches the
          // Flickable underneath untouched.
          MouseArea {
            anchors.fill: photoFlick
            acceptedButtons: Qt.NoButton
            onWheel: function (event) {
              // A touchpad reports smooth scrolling via pixelDelta, often
              // with angleDelta left at zero — reading angleDelta alone is
              // why this did nothing at all on a trackpad.
              var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
              if (delta !== 0) {
                var factor = delta > 0 ? 1.2 : (1 / 1.2)
                receiptFullScreen.photoZoom = Math.max(1.0, Math.min(5.0, receiptFullScreen.photoZoom * factor))
              }
              event.accepted = true
            }
          }

          // Zoom / rotate strip, bottom of the photo pane.
          Row {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: Style.space(4)
            spacing: Style.space(4)

            PanelActionButton {
              size: Style.space(24)
              iconText: "−"
              tooltipText: "Zoom out"
              foreground: "#ffffff"
              focusable: false
              enabled: receiptFullScreen.photoZoom > 1.0
              onClicked: receiptFullScreen.photoZoom = Math.max(1.0, receiptFullScreen.photoZoom / 1.3)
            }
            Rectangle {
              width: zoomLabel.implicitWidth + Style.space(10)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: Qt.rgba(0, 0, 0, 0.4)
              Text {
                id: zoomLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: Math.round(receiptFullScreen.photoZoom * 100) + "%"
                color: "#ffffff"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            PanelActionButton {
              size: Style.space(24)
              iconText: "+"
              tooltipText: "Zoom in"
              foreground: "#ffffff"
              focusable: false
              enabled: receiptFullScreen.photoZoom < 5.0
              onClicked: receiptFullScreen.photoZoom = Math.min(5.0, receiptFullScreen.photoZoom * 1.3)
            }
            PanelActionButton {
              size: Style.space(24)
              iconText: "⟳"
              tooltipText: "Rotate 90°"
              foreground: "#ffffff"
              focusable: false
              onClicked: receiptFullScreen.extraRotation = (receiptFullScreen.extraRotation + 90) % 360
            }
            PanelActionButton {
              visible: receiptFullScreen.photoZoom > 1.0
              size: Style.space(24)
              iconText: "⊙"
              tooltipText: "Reset zoom"
              foreground: "#ffffff"
              focusable: false
              onClicked: receiptFullScreen.photoZoom = 1.0
            }
          }
        }

        // LEFT, while linking: the transactions to choose from replace the
        // photo - every one on the bill's date first, then the nearby days,
        // each drawn like a card in the main list. Click one to file the
        // bill against it.
        Rectangle {
          id: fsLinkPane
          width: receiptFullScreen.detailsCollapsed ? parent.width - Style.space(44) - parent.spacing : parent.width * 0.56
          height: parent.height
          radius: Style.cornerRadius
          color: Util.alpha(root.foreground, 0.06)
          clip: true
          visible: receiptFullScreen.pickingLink

          // Every transaction on the bill's date, none left out: one already
          // filed against another bill is shown too (dimmed, not clickable)
          // rather than silently missing. The neighbouring days only appear
          // when asked for.
          property bool showNearby: false
          onVisibleChanged: if (!visible) showNearby = false
          readonly property var cands: Model.receiptCandidates(receiptFullScreen.r, store.transactions,
            { untrackedOnly: false, limit: 12, nearDays: fsLinkPane.showNearby ? 3 : 0 })
          readonly property var sameDay: cands.filter(function (c) { return c.sameDay })
          readonly property var nearby: cands.filter(function (c) { return !c.sameDay })

          Flickable {
            id: linkFlick
            anchors.fill: parent
            anchors.margins: Style.space(10)
            clip: true
            contentWidth: width
            contentHeight: linkCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: linkCol
              width: parent.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Pick the transaction this bill paid for"
                color: root.foreground
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.subtitle
                wrapMode: Text.WordWrap
              }

              Text {
                topPadding: Style.space(8)
                width: parent.width
                textFormat: Text.PlainText
                text: receiptFullScreen.r.date
                  ? "ON " + Model.formatReceiptDate(receiptFullScreen.r.date) : "BILL HAS NO DATE"
                color: Qt.darker(root.foreground, 1.4)
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: fsLinkPane.sameDay
                delegate: TxnPickRow {
                  required property var modelData
                  width: linkCol.width
                  txn: modelData.txn
                  readonly property bool taken: !!root.linkedTransactionIds[modelData.txn.id]
                  highlight: modelData.match && !taken
                  clickable: !taken
                  dimmed: taken
                  reasons: taken ? "already linked to another bill"
                    : (modelData.match ? "✓ same amount & date"
                      : (modelData.score > 0 ? modelData.score + "% match" : ""))
                  onPicked: {
                    receiptFullScreen.justLinked = true
                    store.linkReceipt(receiptFullScreen.r.id, modelData.txn.id)
                    receiptFullScreen.pickingLink = false
                  }
                }
              }

              Text {
                visible: fsLinkPane.sameDay.length === 0
                width: parent.width
                textFormat: Text.PlainText
                text: "No transactions on this date."
                color: Qt.darker(root.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: fsLinkPane.nearby.length > 0
                topPadding: Style.space(10)
                width: parent.width
                textFormat: Text.PlainText
                text: "NEARBY DAYS"
                color: Qt.darker(root.foreground, 1.4)
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: fsLinkPane.nearby
                delegate: TxnPickRow {
                  required property var modelData
                  width: linkCol.width
                  txn: modelData.txn
                  readonly property bool taken: !!root.linkedTransactionIds[modelData.txn.id]
                  clickable: !taken
                  dimmed: taken
                  reasons: taken ? "already linked to another bill"
                    : ((modelData.exact ? "same amount · " : "")
                      + modelData.reasons.filter(function (x) { return /apart/.test(x) }).join(""))
                  onPicked: {
                    receiptFullScreen.justLinked = true
                    store.linkReceipt(receiptFullScreen.r.id, modelData.txn.id)
                    receiptFullScreen.pickingLink = false
                  }
                }
              }

              Item {
                width: parent.width
                height: Style.space(40)
                TextAction {
                  anchors.verticalCenter: parent.verticalCenter
                  label: fsLinkPane.showNearby ? "Hide nearby days" : "Show nearby days (±3)"
                  onTriggered: fsLinkPane.showNearby = !fsLinkPane.showNearby
                }
              }
            }
          }

          ScrollWheelArea { anchors.fill: linkFlick; target: linkFlick; speed: 2.5 }
        }

        // RIGHT: everything the parser found, and the verify actions —
        // scrollable, since a long item list can outgrow even this.
        // A plain Item wrapper, not anchors directly on the Flickable:
        // Row forbids anchored children outright, the same reason
        // fsPhotoPane above is a plain-sized Rectangle rather than
        // something anchored - the ScrollWheelArea sibling below needs
        // this same common parent to anchor.fill against.
        Item {
          width: (fsPhotoPane.visible || fsLinkPane.visible) ? parent.width - fsPhotoPane.width - parent.spacing : parent.width
          readonly property bool folded: receiptFullScreen.detailsCollapsed && (fsPhotoPane.visible || fsLinkPane.visible)
          height: parent.height

          // Fixed-position icon toolbar - only what is worth a button, each
          // always in the same slot, the name on hover. (Editing a value
          // needs no button: click it. Clearing the check flag is part of
          // Recalculate.)
          // The fold handle: pushes the whole bill side away to the right
          // (">") and brings it back ("<").
          PanelActionButton {
            id: fsFoldHandle
            anchors.top: parent.top
            anchors.left: parent.left
            visible: fsPhotoPane.visible || fsLinkPane.visible
            iconText: receiptFullScreen.detailsCollapsed ? "‹" : "›"
            tooltipText: receiptFullScreen.detailsCollapsed ? "Show the bill" : "Hide the bill — more room"
            foreground: receiptFullScreen.detailsCollapsed ? Color.accent : root.foreground
            bordered: true
            focusable: true
            onClicked: receiptFullScreen.detailsCollapsed = !receiptFullScreen.detailsCollapsed
          }

          Row {
            id: fsToolbar
            visible: !parent.folded
            anchors.top: parent.top
            anchors.left: fsFoldHandle.visible ? fsFoldHandle.right : parent.left
            anchors.leftMargin: fsFoldHandle.visible ? Style.space(6) : 0
            spacing: Style.space(6)

            PanelActionButton {
              iconText: receiptFullScreen.editingFields ? "󰄬" : "󰏫"
              tooltipText: receiptFullScreen.editingFields ? "Done adding / removing products" : "Add or remove products"
              foreground: receiptFullScreen.editingFields ? Color.accent : root.foreground
              bordered: true
              focusable: true
              onClicked: receiptFullScreen.editingFields = !receiptFullScreen.editingFields
            }
            PanelActionButton {
              iconText: "󰃬"
              tooltipText: "Recalculate and verify"
              foreground: root.foreground
              bordered: true
              focusable: true
              enabled: Model.receiptItemCount(receiptFullScreen.r) > 0
              onClicked: store.verifyReceipt(receiptFullScreen.r.id)
            }
            // One slot for both directions: link when nothing is filed,
            // unlink when it is (or parked).
            PanelActionButton {
              readonly property bool filed: receiptFullScreen.r.state === "linked"
                || receiptFullScreen.r.state === "cash" || receiptFullScreen.r.state === "ignored"
              iconText: filed ? "󰌸" : "󰌷"
              tooltipText: filed ? "Unlink" : (receiptFullScreen.pickingLink ? "Cancel linking" : "Link to a transaction")
              foreground: receiptFullScreen.pickingLink ? Color.accent : root.foreground
              bordered: true
              focusable: true
              onClicked: {
                if (filed) store.unlinkReceipt(receiptFullScreen.r.id)
                else receiptFullScreen.pickingLink = !receiptFullScreen.pickingLink
              }
            }
            PanelActionButton {
              iconText: "󰄔"
              tooltipText: "Paid in cash"
              foreground: root.foreground
              bordered: true
              focusable: true
              enabled: receiptFullScreen.r.state === "unmatched"
              onClicked: { store.parkReceipt(receiptFullScreen.r.id, "cash"); receiptFullScreen.pickingLink = false }
            }
            PanelActionButton {
              iconText: "󰜺"
              tooltipText: "Not a bill"
              foreground: root.foreground
              bordered: true
              focusable: true
              enabled: receiptFullScreen.r.state === "unmatched"
              onClicked: { store.parkReceipt(receiptFullScreen.r.id, "ignored"); receiptFullScreen.pickingLink = false }
            }
            PanelActionButton {
              iconText: "󰙴"
              tooltipText: (receiptReparseProc.running && receiptReparseProc.receiptId === receiptFullScreen.r.id)
                ? "Re-reading…" : "Re-read with AI (replaces all items)"
              foreground: root.foreground
              bordered: true
              focusable: true
              enabled: !receiptReparseProc.running
              onClicked: {
                receiptReparseOutput.text = ""
                receiptReparseProc.receiptId = receiptFullScreen.r.id
                receiptReparseProc.running = true
              }
            }
            PanelActionButton {
              iconText: "󰋽"
              tooltipText: receiptFullScreen.showInfo ? "Hide photo info" : "Photo info — taken, camera, size"
              foreground: receiptFullScreen.showInfo ? Color.accent : root.foreground
              bordered: true
              focusable: true
              onClicked: receiptFullScreen.showInfo = !receiptFullScreen.showInfo
            }
            // Removes the whole bill - values, photo, filing. Asks twice.
            PanelActionButton {
              iconText: "󰆴"
              tooltipText: receiptFullScreen.confirmRemove
                ? "Click again to remove this bill for good"
                : "Remove this bill (values and photo)"
              foreground: receiptFullScreen.confirmRemove ? root.debitColor : root.foreground
              hoverColor: root.debitColor
              bordered: true
              focusable: true
              onClicked: {
                if (!receiptFullScreen.confirmRemove) {
                  receiptFullScreen.confirmRemove = true
                  confirmRemoveTimer.restart()
                } else {
                  confirmRemoveTimer.stop()
                  receiptFullScreen.confirmRemove = false
                  store.removeReceipt(receiptFullScreen.r.id)
                }
              }
            }
          }

          Flickable {
            id: fsDetailsFlick
            visible: !parent.folded
            anchors.top: fsToolbar.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: fsOutputBox.visible ? fsOutputBox.top : parent.bottom
            anchors.bottomMargin: fsOutputBox.visible ? Style.space(8) : 0
            clip: true
            contentWidth: width
            contentHeight: fsColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

          Column {
            id: fsColumn
            width: parent.width
            spacing: Style.space(8)

            // Linked: the transaction this bill paid for sits on top (drawn like
            // its card in the main list), and a line runs down from it to the
            // bill below, drawn in when the bill is linked, with a LINKED badge
            // on it.
            Item {
              id: linkBridge
              readonly property bool linked: receiptFullScreen.r.state === "linked"
                && !receiptFullScreen.pickingLink && !!receiptFullScreen.linkedTxn
              property real prog: 0
              visible: linked
              width: parent.width
              height: linked ? bridgeCol.implicitHeight : 0
              onLinkedChanged: if (linked) { prog = 0; bridgeAnim.restart() }
              Component.onCompleted: if (linked) prog = 1

              NumberAnimation { id: bridgeAnim; target: linkBridge; property: "prog"; from: 0; to: 1
                duration: 700; easing.type: Easing.OutCubic }

              Column {
                id: bridgeCol
                width: parent.width

                Repeater {
                  model: linkBridge.linked ? [receiptFullScreen.linkedTxn] : []
                  delegate: TxnPickRow {
                    required property var modelData
                    width: bridgeCol.width
                    txn: modelData
                    highlight: true
                    clickable: false
                    reasons: "linked to this bill"
                    opacity: Math.max(0, linkBridge.prog / 0.6)
                    transform: Translate { y: (Math.min(1, linkBridge.prog) - 1) * Style.space(14) }
                  }
                }

                // What became of the photo: compressed and kept, never deleted.
                Text {
                  width: parent.width
                  topPadding: Style.space(4)
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  text: Model.receiptPhotoNote(receiptFullScreen.r)
                  visible: text !== ""
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  width: parent.width
                  height: Style.space(40)

                  Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 3
                    radius: 1
                    color: root.creditColor
                    height: parent.height * Math.min(1, Math.max(0, (linkBridge.prog - 0.3) * 1.5))
                  }
                  Rectangle {
                    anchors.centerIn: parent
                    width: bridgeBadge.implicitWidth + Style.space(18)
                    height: Style.space(24)
                    radius: height / 2
                    color: Qt.darker(root.creditColor, 3.2)
                    border.width: 1
                    border.color: root.creditColor
                    scale: linkBridge.prog > 0.55 ? 1.0 : 0.0
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                    Text {
                      id: bridgeBadge
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "󰌷  LINKED"
                      color: root.creditColor
                      font.family: Style.font.family
                      font.bold: true
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            // The bill, laid out as the bill itself reads: wrapped merchant,
            // ==== / ---- rules, Date/Time, an ITEM QTY RATE AMOUNT table,
            // signed Bill Discount / Round Off, the tax split, item count,
            // GRAND TOTAL last. Monospace throughout so the money columns
            // line up, the one thing a printed bill always gets right.
            // Click any value to correct just that one.
            Rectangle {
              id: paper
              width: parent.width
              implicitHeight: paperCol.implicitHeight + Style.space(24)
              height: implicitHeight
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)
              border.width: 1
              border.color: Util.alpha(root.foreground, 0.12)

              // A one-off green flash round the bill when it is linked.
              readonly property bool filed: receiptFullScreen.r.state === "linked"
              onFiledChanged: if (filed && receiptFullScreen.justLinked) {
                receiptFullScreen.justLinked = false
                flashAnim.restart()
              }
              Rectangle {
                id: foldButton
                z: 3
                x: parent.width - width - Style.space(8)
                y: Style.space(8)
                width: Style.space(24)
                height: width
                radius: width / 2
                color: foldMouse.containsMouse ? Util.alpha(root.foreground, 0.16) : Util.alpha(root.foreground, 0.08)
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "▾"
                  color: root.foreground
                  font.pixelSize: Style.font.body
                  rotation: receiptFullScreen.billCollapsed ? -90 : 0
                  Behavior on rotation { NumberAnimation { duration: 200 } }
                }
                MouseArea {
                  id: foldMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: receiptFullScreen.billCollapsed = !receiptFullScreen.billCollapsed
                }
                ToolTip.visible: foldMouse.containsMouse
                ToolTip.text: receiptFullScreen.billCollapsed ? "Show the whole bill" : "Fold the bill"
                ToolTip.delay: 400
              }

              Rectangle {
                id: linkFlash
                anchors.fill: parent
                radius: parent.radius
                color: "transparent"
                border.width: 3
                border.color: root.creditColor
                opacity: 0
                z: 2
              }
              NumberAnimation { id: flashAnim; target: linkFlash; property: "opacity"
                from: 1; to: 0; duration: 1200; easing.type: Easing.OutQuad }

              Column {
                id: paperCol
                x: Style.space(12)
                y: Style.space(12)
                width: parent.width - Style.space(24)
                spacing: Style.space(3)

                // Click the name, date or time to correct just that one - it
                // becomes a box right where it stands (these are fixed
                // fields, not rows that a refresh of the bill can rebuild
                // under your cursor).
                InlineEdit {
                  width: parent.width
                  fieldName: "merchant"
                  display: Model.receiptTitle(receiptFullScreen.r).toUpperCase()
                  initial: receiptFullScreen.r.merchant || ""
                  hAlign: Text.AlignHCenter
                  bold: true
                  pixelSize: Style.font.body
                  textColor: root.foreground
                  placeholder: "Shop name"
                }

                // Folded: one line - date, item count, total - instead of the
                // whole bill. Click it, or the chevron, to open again.
                Text {
                  visible: receiptFullScreen.billCollapsed
                  width: parent.width
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  text: [
                    receiptFullScreen.r.date ? Model.formatReceiptDate(receiptFullScreen.r.date) : "",
                    Model.receiptItemCount(receiptFullScreen.r) + (Model.receiptItemCount(receiptFullScreen.r) === 1 ? " item" : " items"),
                    receiptFullScreen.r.total != null
                      ? Model.currencySymbol(receiptFullScreen.r.currency) + receiptFullScreen.r.total.toFixed(2) : "amount unknown",
                  ].filter(function (x) { return x !== "" }).join("   ·   ")
                  color: Model.receiptIsBalanced(receiptFullScreen.r) ? root.creditColor : root.debitColor
                  font.family: "monospace"
                  font.bold: true
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: receiptFullScreen.billCollapsed = false
                  }
                }

                Item {
                  id: paperBody
                  width: parent.width
                  height: receiptFullScreen.billCollapsed ? 0 : paperRest.implicitHeight
                  clip: true
                  opacity: receiptFullScreen.billCollapsed ? 0 : 1
                  Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                  Behavior on opacity { NumberAnimation { duration: 160 } }

                  Column {
                    id: paperRest
                    width: parent.width
                    spacing: Style.space(3)

                FsRule { doubled: true }

                Item {
                  width: parent.width
                  height: dateTimeRow.implicitHeight
                  Row {
                    id: dateTimeRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(24)
                    Row {
                      spacing: Style.space(4)
                      Text {
                        textFormat: Text.PlainText
                        text: "Date:"
                        color: Qt.darker(root.foreground, 1.4)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption
                      }
                      InlineEdit {
                        fieldName: "date"
                        display: receiptFullScreen.r.date ? Model.formatReceiptDate(receiptFullScreen.r.date) : "—"
                        initial: Model.formatReceiptDate(receiptFullScreen.r.date)
                        textColor: Qt.darker(root.foreground, 1.1)
                        placeholder: "DD-MM-YYYY"
                      }
                    }
                    Row {
                      spacing: Style.space(4)
                      Text {
                        textFormat: Text.PlainText
                        text: "Time:"
                        color: Qt.darker(root.foreground, 1.4)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption
                      }
                      InlineEdit {
                        fieldName: "time"
                        display: receiptFullScreen.r.time || "—"
                        initial: receiptFullScreen.r.time || ""
                        textColor: Qt.darker(root.foreground, 1.1)
                        placeholder: "HH:MM"
                      }
                    }
                  }
                }

                FsRule {}

                Item {
                  width: parent.width
                  height: fiHeadItem.implicitHeight

                  Text {
                    id: fiHeadItem
                    anchors.left: parent.left
                    anchors.right: fiHeadNums.left
                    anchors.rightMargin: Style.space(8)
                    textFormat: Text.PlainText
                    text: "ITEM"
                    color: Qt.darker(root.foreground, 1.3)
                    font.family: "monospace"
                    font.bold: true
                    font.pixelSize: Style.font.caption
                  }
                  Row {
                    id: fiHeadNums
                    anchors.right: parent.right
                    spacing: Style.space(8)
                    Text {
                      width: Style.space(60); horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText; text: "QTY"
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: "monospace"; font.bold: true; font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: Style.space(56); horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText; text: "RATE"
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: "monospace"; font.bold: true; font.pixelSize: Style.font.caption
                    }
                    Text {
                      visible: receiptFullScreen.showGst
                      width: Style.space(44); horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText; text: "GST%"
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: "monospace"; font.bold: true; font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: Style.space(64); horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText; text: "AMOUNT"
                      color: Qt.darker(root.foreground, 1.3)
                      font.family: "monospace"; font.bold: true; font.pixelSize: Style.font.caption
                    }
                    Item { width: Style.space(22); height: 1; visible: receiptFullScreen.editingFields }
                  }
                }

                FsRule {}

                // Each description and figure is plain text until clicked;
                // then only that one becomes a box. Changing qty or rate
                // re-works the line's amount (3 x 50 = 150), and the
                // subtotal and total follow the items.
                Repeater {
                  model: receiptFullScreen.r.items || []
                  delegate: Item {
                    id: fiRow
                    required property var modelData
                    property bool editingDesc: false
                    width: parent.width
                    height: Math.max(fiRow.editingDesc ? fiDescInput.implicitHeight : fiDesc.implicitHeight,
                                     fiNums.implicitHeight) + Style.space(4)

                    Text {
                      id: fiDesc
                      visible: !fiRow.editingDesc
                      anchors.top: parent.top
                      anchors.left: parent.left
                      anchors.right: fiNums.left
                      anchors.rightMargin: Style.space(8)
                      textFormat: Text.PlainText
                      text: fiRow.modelData.description || ""
                      color: Qt.darker(root.foreground, 1.1)
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.IBeamCursor
                        onClicked: { fiRow.editingDesc = true; fiDescInput.forceActiveFocus(); fiDescInput.selectAll() }
                      }
                    }

                    TextField {
                      id: fiDescInput
                      visible: fiRow.editingDesc
                      anchors.top: parent.top
                      anchors.left: parent.left
                      anchors.right: fiNums.left
                      anchors.rightMargin: Style.space(8)
                      text: fiRow.modelData.description || ""
                      color: root.foreground
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                      background: Rectangle {
                        radius: Style.cornerRadius
                        color: Util.alpha(Color.accent, 0.12)
                        border.width: 1
                        border.color: Util.alpha(Color.accent, 0.6)
                      }
                      Keys.onEscapePressed: { fiDescInput.text = fiRow.modelData.description || ""; fiRow.editingDesc = false }
                      onEditingFinished: {
                        if (!fiRow.editingDesc) return
                        if (text !== (fiRow.modelData.description || ""))
                          store.editReceiptItemField(receiptFullScreen.r.id, fiRow.modelData.line, "description", text)
                        fiRow.editingDesc = false
                      }
                    }

                    Row {
                      id: fiNums
                      anchors.top: parent.top
                      anchors.right: parent.right
                      spacing: Style.space(8)

                      ItemCell {
                        width: Style.space(60); line: fiRow.modelData.line; fieldName: "qty"
                        display: Model.formatQty(fiRow.modelData)
                        initial: Model.formatQty(fiRow.modelData)
                        textColor: Qt.darker(root.foreground, 1.2)
                      }
                      ItemCell {
                        width: Style.space(56); line: fiRow.modelData.line; fieldName: "rate"
                        display: fiRow.modelData.rate != null ? Number(fiRow.modelData.rate).toFixed(2) : ""
                        initial: fiRow.modelData.rate != null ? Number(fiRow.modelData.rate).toFixed(2) : ""
                        textColor: Qt.darker(root.foreground, 1.2)
                      }
                      ItemCell {
                        visible: receiptFullScreen.showGst
                        width: Style.space(44); line: fiRow.modelData.line; fieldName: "gst_rate"
                        display: fiRow.modelData.gstRate != null ? String(fiRow.modelData.gstRate)
                          : (receiptFullScreen.editingFields ? "—" : "")
                        initial: fiRow.modelData.gstRate != null ? String(fiRow.modelData.gstRate) : ""
                        textColor: Qt.darker(root.foreground, 1.2)
                      }
                      ItemCell {
                        width: Style.space(64); line: fiRow.modelData.line; fieldName: "amount"
                        display: fiRow.modelData.amount != null ? Number(fiRow.modelData.amount).toFixed(2) : ""
                        initial: fiRow.modelData.amount != null ? Number(fiRow.modelData.amount).toFixed(2) : ""
                        textColor: Model.receiptIsBalanced(receiptFullScreen.r) ? root.creditColor : root.foreground
                      }
                      Text {
                        visible: receiptFullScreen.editingFields
                        width: Style.space(22)
                        horizontalAlignment: Text.AlignHCenter
                        textFormat: Text.PlainText
                        text: "✕"
                        color: root.debitColor
                        font.pixelSize: Style.font.body
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          preventStealing: true
                          onClicked: store.deleteReceiptItem(receiptFullScreen.r.id, fiRow.modelData.line)
                        }
                      }
                    }
                  }
                }

                // A product the parser missed: shown after "Add / remove
                // products". Enter in Amount or "+ Add"; a blank amount is
                // qty x rate.
                Flow {
                  visible: receiptFullScreen.editingFields
                  width: parent.width
                  spacing: Style.space(4)

                  NewItemBox { id: addDesc; width: Style.space(150); placeholderText: "New product" }
                  NewItemBox { id: addQty; width: Style.space(52); placeholderText: "qty" }
                  NewItemBox { id: addUnit; width: Style.space(40); placeholderText: "unit" }
                  NewItemBox { id: addRate; width: Style.space(56); placeholderText: "rate" }
                  NewItemBox { id: addGst; width: Style.space(48); placeholderText: "GST%" }
                  NewItemBox {
                    id: addAmt; width: Style.space(64); placeholderText: "amount"
                    onAccepted: addProduct.triggered()
                  }
                  TextAction {
                    id: addProduct
                    label: "+ Add"
                    onTriggered: {
                      if (store.addReceiptItem(receiptFullScreen.r.id, addDesc.text, addQty.text,
                                               addUnit.text, addRate.text, addAmt.text, addGst.text)) {
                        addDesc.text = ""; addQty.text = ""; addUnit.text = ""
                        addRate.text = ""; addAmt.text = ""; addGst.text = ""
                        addDesc.forceActiveFocus()
                      }
                    }
                  }
                }

                FsRule {}

                // Subtotal / Bill Discount / Round Off. The discount is kept
                // as a positive amount but printed with its minus sign, as
                // on the bill.
                Repeater {
                  model: [
                    { label: "Subtotal", field: "subtotal",
                      value: receiptFullScreen.r.subtotal != null ? receiptFullScreen.r.subtotal.toFixed(2) : "" },
                    { label: "Bill Discount", field: "discount",
                      value: receiptFullScreen.r.discount != null
                        ? (receiptFullScreen.r.discount ? "-" : "") + Math.abs(receiptFullScreen.r.discount).toFixed(2) : "" },
                    { label: "Round Off", field: "round_off",
                      value: receiptFullScreen.r.roundOff != null ? receiptFullScreen.r.roundOff.toFixed(2) : "" },
                  ]
                  delegate: ReceiptEditField {
                    required property var modelData
                    ledger: true
                    numeric: true
                    label: modelData.label
                    fieldName: modelData.field
                    value: modelData.value
                  }
                }

                // Platform / delivery / service fees, as printed - extra charges
                // on top of the subtotal. Click an amount to change it; the
                // total follows. (Edit mode: remove one, or add one.)
                Repeater {
                  model: receiptFullScreen.r.fees || []
                  delegate: Item {
                    id: feeRow
                    required property var modelData
                    width: parent.width
                    height: feeField.height
                    ReceiptEditField {
                      id: feeField
                      width: parent.width - (receiptFullScreen.editingFields ? Style.space(24) : 0)
                      ledger: true
                      numeric: true
                      label: feeRow.modelData.label
                      fieldName: "amount"
                      feeLine: feeRow.modelData.line
                      value: Number(feeRow.modelData.amount).toFixed(2)
                    }
                    Text {
                      visible: receiptFullScreen.editingFields
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "✕"
                      color: root.debitColor
                      font.pixelSize: Style.font.body
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onClicked: store.deleteReceiptFee(receiptFullScreen.r.id, feeRow.modelData.line)
                      }
                    }
                  }
                }

                Flow {
                  visible: receiptFullScreen.editingFields
                  width: parent.width
                  spacing: Style.space(4)

                  NewItemBox { id: addFeeLabel; width: Style.space(150); placeholderText: "Fee (Platform Fee, Delivery…)" }
                  NewItemBox {
                    id: addFeeAmt; width: Style.space(80); placeholderText: "amount"
                    onAccepted: addFeeBtn.triggered()
                  }
                  TextAction {
                    id: addFeeBtn
                    label: "+ Add fee"
                    onTriggered: {
                      if (store.addReceiptFee(receiptFullScreen.r.id, addFeeLabel.text, addFeeAmt.text)) {
                        addFeeLabel.text = ""; addFeeAmt.text = ""
                        addFeeLabel.forceActiveFocus()
                      }
                    }
                  }
                }

                FsRule { visible: Model.receiptTaxRows(receiptFullScreen.r).length > 0 || receiptFullScreen.editingFields }

                Repeater {
                  model: Model.receiptTaxRows(receiptFullScreen.r)
                  delegate: ReceiptEditField {
                    required property var modelData
                    ledger: true
                    numeric: true
                    label: modelData.label
                    fieldName: modelData.field
                    taxRate: modelData.rate
                    value: modelData.value.toFixed(2)
                  }
                }

                // Add a tax the bill has but the parser missed: pick the kind,
                // type the rate (CGST/SGST as printed, e.g. 2.5) and, if it
                // differs from rate x (subtotal - discount), the amount.
                Flow {
                  visible: receiptFullScreen.editingFields
                  width: parent.width
                  spacing: Style.space(4)

                  TextAction {
                    label: receiptFullScreen.taxKind === "split" ? "CGST + SGST" : "IGST"
                    onTriggered: receiptFullScreen.taxKind = receiptFullScreen.taxKind === "split" ? "igst" : "split"
                  }
                  NewItemBox { id: addTaxRate; width: Style.space(70); placeholderText: "rate %" }
                  NewItemBox { id: addTaxAmt; width: Style.space(110); placeholderText: "amount (each)" }
                  TextAction {
                    label: "+ Add tax"
                    onTriggered: {
                      var pct = Number(addTaxRate.text)
                      var r = receiptFullScreen.r
                      var base = (r.subtotal != null ? r.subtotal : Model.receiptItemsSum(r)) - Math.abs(r.discount || 0)
                      var amt = addTaxAmt.text.trim() === "" ? Math.round(base * pct) / 100 : Number(addTaxAmt.text)
                      if (!(pct > 0) || isNaN(amt) || !(amt > 0)) return
                      if (receiptFullScreen.taxKind === "split") {
                        store.addReceiptTax(r.id, pct * 2, "cgst", amt)
                        store.addReceiptTax(r.id, pct * 2, "sgst", amt)
                      } else {
                        store.addReceiptTax(r.id, pct, "igst", amt)
                      }
                      addTaxRate.text = ""; addTaxAmt.text = ""
                    }
                  }
                }

                FsRule { visible: Model.receiptTaxRows(receiptFullScreen.r).length > 0 || receiptFullScreen.editingFields }

                Item {
                  width: parent.width
                  height: itemCountLabel.implicitHeight
                  Text {
                    id: itemCountLabel
                    anchors.left: parent.left
                    textFormat: Text.PlainText
                    text: "Number of Items"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.right: parent.right
                    textFormat: Text.PlainText
                    text: String(Model.receiptItemCount(receiptFullScreen.r))
                    color: Qt.darker(root.foreground, 1.2)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption
                  }
                }

                FsRule { doubled: true }

                ReceiptEditField {
                  ledger: true
                  big: true
                  numeric: true
                  label: "GRAND TOTAL"
                  fieldName: "total"
                  prefix: Model.currencySymbol(receiptFullScreen.r.currency)
                  value: receiptFullScreen.r.total != null ? receiptFullScreen.r.total.toFixed(2) : ""
                  valueColor: Model.receiptIsBalanced(receiptFullScreen.r) ? root.creditColor : root.debitColor
                }

                FsRule { doubled: true }
                  }
                }
              }
            }

            // The verdict on the bill above: a clear positive pill when its
            // own figures hold together, the itemised reasons when they
            // don't - never silence either way.
            Rectangle {
              visible: Model.receiptIsBalanced(receiptFullScreen.r)
              implicitWidth: balancedPillText.implicitWidth + Style.space(12)
              implicitHeight: balancedPillText.implicitHeight + Style.space(4)
              width: implicitWidth
              height: implicitHeight
              radius: Style.space(4)
              color: Util.alpha(root.creditColor, 0.18)

              Text {
                id: balancedPillText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "✓ BALANCED — figures add up"
                color: root.creditColor
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: Model.receiptWarnings(receiptFullScreen.r)
              delegate: Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: "!  " + modelData
                color: root.debitColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // What the photo file knew, and where the bill came from - shown
            // from the info button in the toolbar.
            Rectangle {
              visible: receiptFullScreen.showInfo
              width: parent.width
              implicitHeight: infoCol.implicitHeight + Style.space(20)
              height: implicitHeight
              radius: Style.cornerRadius
              color: Util.alpha(root.foreground, 0.05)
              border.width: 1
              border.color: Util.alpha(root.foreground, 0.12)

              Column {
                id: infoCol
                x: Style.space(10)
                y: Style.space(10)
                width: parent.width - Style.space(20)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "PHOTO INFO"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: Model.receiptInfoRows(receiptFullScreen.r)
                  delegate: Item {
                    id: infoRow
                    required property var modelData
                    width: infoCol.width
                    height: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)
                    Text {
                      id: infoLabel
                      width: Style.space(110)
                      textFormat: Text.PlainText
                      text: infoRow.modelData.label
                      color: Qt.darker(root.foreground, 1.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      id: infoValue
                      anchors.left: infoLabel.right
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: infoRow.modelData.value
                      color: root.foreground
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WrapAnywhere
                    }
                  }
                }

                Text {
                  visible: Model.receiptInfoRows(receiptFullScreen.r).length === 0
                  textFormat: Text.PlainText
                  text: "No photo information was kept for this bill."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: receiptFullScreen.editingFields
              width: parent.width
              textFormat: Text.PlainText
              text: "Reparse with AI replaces all items, hand-added ones included."
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }


            Text {
              visible: receiptFullScreen.r.state === "linked" && !receiptFullScreen.pickingLink
                && !receiptFullScreen.linkedTxn
              width: parent.width
              textFormat: Text.PlainText
              text: "Filed against a transaction that is no longer in the list."
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: receiptFullScreen.r.state === "cash" || receiptFullScreen.r.state === "ignored"
              width: parent.width
              textFormat: Text.PlainText
              text: receiptFullScreen.r.state === "cash" ? "Marked as a cash purchase." : "Marked as not a bill."
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

          }
          }

          ScrollWheelArea { visible: !parent.folded; anchors.fill: fsDetailsFlick; target: fsDetailsFlick; speed: 2.5 }

          // The model's own reply, live, while it is generating - only for
          // the receipt that was sent for reparsing (the Process and its
          // output are shared). Its own box under the scrolling details, not
          // inside them, so the mouse wheel over it scrolls the reply and
          // not the page. It follows the newest text, until you scroll up to
          // read back - then it stays where you put it; scroll to the bottom
          // to follow again.
          Item {
            id: fsOutputBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(150)
            visible: !parent.folded && receiptReparseProc.receiptId === receiptFullScreen.r.id
              && (receiptReparseProc.running || receiptReparseOutput.text.length > 0)
            clip: true

            Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: Util.alpha(root.foreground, 0.05) }

            Flickable {
              id: fsOutputFlick
              anchors.fill: parent
              anchors.margins: Style.space(6)
              clip: true
              contentWidth: width
              contentHeight: fsOutputText.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              property bool follow: true
              property bool jumping: false
              onContentYChanged: if (!jumping) follow = contentY + height >= contentHeight - 12
              function toBottom() {
                jumping = true
                contentY = Math.max(0, contentHeight - height)
                jumping = false
                follow = true
              }

              TextEdit {
                id: fsOutputText
                width: parent.width
                readOnly: true
                selectByMouse: true
                persistentSelection: true
                textFormat: TextEdit.PlainText
                text: receiptReparseOutput.text
                wrapMode: TextEdit.WrapAnywhere
                color: Qt.darker(root.foreground, 1.4)
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                // Qt.callLater: contentHeight only reflects the new text
                // once layout has run.
                onTextChanged: Qt.callLater(function () { if (fsOutputFlick.follow) fsOutputFlick.toBottom() })
              }
            }

            ScrollWheelArea { anchors.fill: fsOutputFlick; target: fsOutputFlick; speed: 2.5 }
          }

        }
      }
    }
  }

  // One tab on the strip at the top of the popup. A BorderSurface, not a
  // Controls TabButton: every other control in this popup is one, and
  // mixing the two would mean two focus rings and two hover treatments.
  component TabChip: BorderSurface {
    id: tabChip
    required property string label
    required property string tab
    property string badge: ""
    readonly property bool selected: root.tab === tabChip.tab
    readonly property bool _hot: tabHover.hovered || tabChip.activeFocus

    implicitWidth: tabLabel.implicitWidth + badgeDot.width + Style.spacing.md * 2
    implicitHeight: Style.space(22)
    radius: Style.cornerRadius
    color: Style.controlFill(tabChip.activeFocus, tabChip._hot || tabChip.selected,
                             root.foreground, Color.accent)
    borderSpec: Border.controlSpec(
      tabChip.activeFocus ? "focus" : (tabChip.selected ? "selected"
        : (tabChip._hot ? "hover-cursor" : "normal")),
      root.foreground, Color.accent)

    Behavior on color { ColorAnimation { duration: 100 } }

    activeFocusOnTab: true
    Keys.onReturnPressed: root.tab = tabChip.tab
    Keys.onEnterPressed: root.tab = tabChip.tab
    Keys.onSpacePressed: root.tab = tabChip.tab
    // Left/Right switch tabs from the strip. Safe beside the rows'
    // own Left/Right (expand/collapse): those only fire on a focused
    // row, and a row is never focused while the strip is.
    Keys.onLeftPressed: root.tab = "bank"
    Keys.onRightPressed: root.tab = "portfolio"
    Keys.onUpPressed: root.focusNext(tabChip, false)
    Keys.onDownPressed: root.focusNext(tabChip, true)

    HoverHandler { id: tabHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { tabChip.forceActiveFocus(); root.tab = tabChip.tab }
    }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: -badgeDot.width / 2
      textFormat: Text.PlainText
      text: tabChip.label
      color: tabChip.selected ? root.foreground : Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: tabChip.selected
    }

    Text {
      id: badgeDot
      anchors.left: tabLabel.right
      anchors.leftMargin: tabChip.badge === "" ? 0 : Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      width: tabChip.badge === "" ? 0 : implicitWidth
      visible: tabChip.badge !== ""
      textFormat: Text.PlainText
      text: tabChip.badge
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
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
      store.accountNameOverrides[billRow.overview.last4], billRow.overview.network)
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
            text: Model.accountLabel(billRow.brand.label, billRow.overview.last4)
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

  // A bill laid out neatly in a small space: date and payment line, one row
  // per item (name and amount, "qty x rate" dim underneath), the money lines
  // and the total - or the raw OCR text for a bill with no items. Used in the
  // RECEIPTS rows and under a transaction that has the bill filed against it.
  component MiniBill: Column {
    id: mb
    required property var receipt
    width: parent.width
    spacing: Style.space(3)

    Column {
      visible: (mb.receipt.items || []).length > 0
      width: parent.width
      spacing: Style.space(3)

        Text {
          visible: text !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: [
            mb.receipt.date ? Model.formatReceiptDate(mb.receipt.date) : "",
            mb.receipt.time || "",
            mb.receipt.paymentHint ? "Paid by " + mb.receipt.paymentHint : "",
          ].filter(function (x) { return x !== "" }).join("   ·   ")
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: mb.receipt.items || []
          delegate: Item {
            id: miniItem
            required property var modelData
            width: parent.width
            height: miniName.implicitHeight + (miniDetail.visible ? miniDetail.implicitHeight : 0) + Style.space(2)

            Text {
              id: miniName
              anchors.left: parent.left
              anchors.right: miniAmt.left
              anchors.rightMargin: Style.space(8)
              textFormat: Text.PlainText
              text: miniItem.modelData.description || ""
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              id: miniAmt
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: miniItem.modelData.amount != null ? Number(miniItem.modelData.amount).toFixed(2) : ""
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.caption
            }
            Text {
              id: miniDetail
              visible: (miniItem.modelData.qty != null && miniItem.modelData.rate != null)
                || miniItem.modelData.gstRate != null
              anchors.top: miniName.bottom
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: [
                miniItem.modelData.qty != null && miniItem.modelData.rate != null
                  ? Model.formatQty(miniItem.modelData) + " × " + Number(miniItem.modelData.rate).toFixed(2) : "",
                miniItem.modelData.gstRate != null ? "GST " + miniItem.modelData.gstRate + "%" : "",
              ].filter(function (x) { return x !== "" }).join("  ·  ")
              color: Qt.darker(root.foreground, 1.6)
              font.family: "monospace"
              font.pixelSize: Style.font.caption
            }
          }
        }

        FsRule {}

        Repeater {
          model: Model.receiptSummaryLines(mb.receipt)
          delegate: MiniRow {
            required property var modelData
            label: modelData.label
            value: modelData.value
          }
        }

        MiniRow {
          label: "TOTAL"
          bold: true
          value: mb.receipt.total != null
            ? Model.currencySymbol(mb.receipt.currency) + mb.receipt.total.toFixed(2) : "?"
          valueColor: Model.receiptIsBalanced(mb.receipt) ? root.creditColor : root.debitColor
        }

    }

    TextEdit {
        width: parent.width
        visible: (mb.receipt.items || []).length === 0 && !!mb.receipt.rawText
        readOnly: true
        selectByMouse: true
        persistentSelection: true
        textFormat: TextEdit.PlainText
        text: mb.receipt.rawText || ""
        wrapMode: TextEdit.Wrap
        color: Qt.darker(root.foreground, 1.3)
        font.family: "monospace"
        font.pixelSize: Style.font.caption
      }
  }

  // One label / right-aligned value line of the small bill view.
  component MiniRow: Item {
    id: mr
    property string label: ""
    property string value: ""
    property bool bold: false
    property var valueColor: null
    width: parent.width
    height: Math.max(mrLabel.implicitHeight, mrValue.implicitHeight)
    Text {
      id: mrLabel
      anchors.left: parent.left
      textFormat: Text.PlainText
      text: mr.label
      color: mr.bold ? root.foreground : Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.bold: mr.bold
      font.pixelSize: Style.font.caption
    }
    Text {
      id: mrValue
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: mr.value
      color: mr.valueColor ? mr.valueColor : (mr.bold ? root.foreground : Qt.darker(root.foreground, 1.2))
      font.family: "monospace"
      font.bold: mr.bold
      font.pixelSize: Style.font.caption
    }
  }

  // A transaction drawn exactly like a card in the main RECENT list: the
  // round up/down arrow, bold merchant, bank mark + account pill and date,
  // the amount on the right - and, for the link picker, why it was offered
  // (the match reasons) under the amount. Click to choose it.
  component TxnPickRow: BorderSurface {
    id: pick
    required property var txn
    property string reasons: ""
    property int score: 0
    property bool clickable: true
    // Same amount on the bill's own date: drawn green, with a tick.
    property bool highlight: false
    property bool dimmed: false
    signal picked()
    opacity: pick.dimmed ? 0.5 : 1.0

    readonly property string displayMerchant: Model.transactionDisplayName(txn, store.transactionNameOverrides)
    readonly property string accountName: Model.accountLabel(Model.cardLabelParts(
      Model.cardFallbackName(txn.accountType, txn.last4, store.cardOverviews, txn.bank),
      store.accountNameOverrides[txn.last4],
      (store.cardOverviews[txn.last4] || {}).network).label, txn.last4)
    readonly property bool isDebit: txn.amount < 0
    readonly property color directionColor: root.directionColor(txn)
    readonly property bool isSavings: txn.accountType === "checking" && (txn.bank === "AXIS" || txn.bank === "SBI")

    implicitHeight: Style.space(52)
    radius: Style.cornerRadius
    color: pick.highlight ? Util.alpha(root.creditColor, pickHover.hovered ? 0.24 : 0.14)
      : (pickHover.hovered && pick.clickable ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent")
    borderSpec: pick.highlight ? Border.flat(root.creditColor, 1) : Border.none()
    Behavior on color { ColorAnimation { duration: 100 } }

    HoverHandler { id: pickHover }
    MouseArea {
      anchors.fill: parent
      enabled: pick.clickable
      cursorShape: Qt.PointingHandCursor
      preventStealing: true
      onClicked: pick.picked()
    }

    Rectangle {
      id: pickAvatar
      width: Style.space(36)
      height: width
      radius: width / 2
      color: Util.alpha(pick.directionColor, 0.22)
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: pick.isDebit ? "↓" : "↑"
        color: pick.directionColor
        font.bold: true
        font.pixelSize: Style.font.subtitle
      }
    }

    Column {
      anchors.left: pickAvatar.right
      anchors.leftMargin: Style.space(10)
      anchors.right: pickAmount.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: pick.displayMerchant
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
          network: Model.cardNetwork(pick.txn, store.cardOverviews)
          markHeight: Style.spaceReal(9)
          anchors.verticalCenter: parent.verticalCenter
        }
        HdfcLogo {
          variant: "icon"
          visible: pick.txn.accountType === "checking" && pick.txn.bank === "HDFC"
          markSize: Style.spaceReal(9)
          anchors.verticalCenter: parent.verticalCenter
        }
        AxisLogo {
          visible: pick.txn.accountType === "checking" && pick.txn.bank === "AXIS"
          markSize: Style.spaceReal(9)
          anchors.verticalCenter: parent.verticalCenter
        }
        SbiLogo {
          visible: pick.txn.accountType === "checking" && pick.txn.bank === "SBI"
          markSize: Style.spaceReal(9)
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          radius: Style.space(4)
          color: Util.alpha(root.foreground, 0.12)
          implicitWidth: pickPill.implicitWidth + Style.space(10)
          implicitHeight: pickPill.implicitHeight + Style.space(4)
          Text {
            id: pickPill
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: pick.isSavings ? "••" + pick.txn.last4 : pick.accountName
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: Model.formatFullDate(pick.txn.date)
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      id: pickAmount
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: Model.formatAmount(pick.txn)
        color: pick.directionColor
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle
      }
      Text {
        visible: pick.reasons !== ""
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: pick.reasons
        color: pick.highlight ? root.creditColor : Qt.darker(root.foreground, 1.5)
        font.family: Style.font.family
        font.bold: pick.highlight
        font.pixelSize: Style.font.caption
      }
    }
  }

  // A photographed bill. Collapsed: a status disc (unmatched / needs
  // review / filed / parked), the merchant, a one-line subtitle, the total.
  // Expanded: the photo thumbnail, the item table, the GST breakdown, and
  // either the linked transaction's one-liner or the candidate picker.
  // Built on BillRow's skeleton — same collapsed/expanded split, same
  // fixed-height pinned collapsed row, same detail-panel anchoring.
  component ReceiptRow: BorderSurface {
    id: receiptRow
    required property var receipt
    property bool expanded: false
    readonly property var mark: Model.receiptStateMark(receiptRow.receipt)
    readonly property color statusColor: receiptRow.mark.tone === "credit" ? root.creditColor
      : (receiptRow.mark.tone === "debit" ? root.debitColor
        : (receiptRow.mark.tone === "pending" ? root.pendingColor : Qt.darker(root.foreground, 1.4)))
    readonly property bool _hot: rowHoverR.hovered || receiptRow.activeFocus
    readonly property int collapsedHeight: Style.space(44)
    readonly property int contentLeft: Style.spacing.rowPaddingX + root.billStatusWidth + Style.spacing.md

    implicitHeight: receiptRow.collapsedHeight
      + (receiptRow.expanded ? detailsPanelR.implicitHeight + Style.space(10) : 0)
    radius: Style.cornerRadius
    opacity: rowMouseR.pressed ? 0.75 : 1.0
    color: receiptRow._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent"
    borderSpec: receiptRow.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 80 } }

    HoverHandler { id: rowHoverR }

    activeFocusOnTab: true
    Keys.onReturnPressed: receiptRow.expanded = !receiptRow.expanded
    Keys.onEnterPressed: receiptRow.expanded = !receiptRow.expanded
    Keys.onSpacePressed: receiptRow.expanded = !receiptRow.expanded
    Keys.onUpPressed: root.focusNext(receiptRow, false)
    Keys.onDownPressed: root.focusNext(receiptRow, true)
    Keys.onLeftPressed: receiptRow.expanded = false
    Keys.onRightPressed: receiptRow.expanded = true

    Item {
      id: collapsedRowR
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: receiptRow.collapsedHeight

      MouseArea {
        id: rowMouseR
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: receiptRow.expanded = !receiptRow.expanded
      }

      Item {
        id: statusGutterR
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: root.billStatusWidth
        height: avatarR.height + Style.space(4) + statePillR.height

        Rectangle {
          id: avatarR
          width: Style.space(20)
          height: width
          radius: width / 2
          color: Util.alpha(receiptRow.statusColor, 0.16)
          anchors.top: parent.top
          anchors.left: parent.left

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: receiptRow.mark.glyph
            color: receiptRow.statusColor
            font.bold: true
            font.pixelSize: Style.font.caption
          }

          // The one place a quick decision lives without opening the whole
          // row — same precedent as BillRow's "mark as paid" disc.
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(10)
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              // An unmatched bill's quick decision now lives in the
              // full-screen window (the small panel no longer carries its
              // own link picker), so this disc opens straight there;
              // anything else just expands the quick-glance thumbnail+text.
              if (receiptRow.receipt.state === "unmatched") {
                root.openReceiptDetail(receiptRow.receipt)
              } else {
                receiptRow.expanded = true
              }
            }
          }
        }

        Rectangle {
          id: statePillR
          anchors.top: avatarR.bottom
          anchors.topMargin: Style.space(4)
          anchors.left: parent.left
          implicitWidth: Math.min(parent.width, pillTextR.implicitWidth + Style.space(8))
          implicitHeight: pillTextR.implicitHeight + Style.space(2)
          width: implicitWidth
          height: implicitHeight
          radius: Style.space(4)
          color: Util.alpha(receiptRow.statusColor, 0.18)

          Text {
            id: pillTextR
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: receiptRow.mark.pill
            color: receiptRow.statusColor
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption
          }
        }
      }

      Column {
        anchors.left: statusGutterR.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: amountStackR.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: Model.receiptTitle(receiptRow.receipt)
          color: root.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: Model.receiptSubtitle(receiptRow.receipt)
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Column {
        id: amountStackR
        width: root.billFigureWidth
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          anchors.right: parent.right
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: receiptRow.receipt.total != null
            ? Model.currencySymbol(receiptRow.receipt.currency) + Model.formatGrouped(receiptRow.receipt.total)
            : "?"
          color: root.debitColor
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }

        Text {
          anchors.right: parent.right
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: receiptRow.receipt.state === "linked" ? ("••" + receiptRow.receipt.txnAmount) : ""
          visible: receiptRow.receipt.state === "linked"
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      id: detailsPanelR
      visible: receiptRow.expanded
      anchors.top: collapsedRowR.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: receiptRow.contentLeft
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(4)

      Rectangle { width: parent.width; height: Style.spacing.hairline; color: Qt.darker(root.foreground, 1.8) }

      // A small thumbnail, same footprint as every other row's inline
      // content — clicking it opens the full review window below rather
      // than growing the row itself, so the row stays a quick glance and
      // the photo gets the space it actually needs only once asked for.
      Rectangle {
        visible: !!(receiptRow.receipt.thumbPath || receiptRow.receipt.storedPath)
        width: Style.space(96)
        height: Style.space(96)
        radius: Style.cornerRadius
        color: Qt.darker(root.foreground, 2.4)
        clip: true

        Image {
          anchors.fill: parent
          // storedPath/thumbPath from the snapshot are relative to the
          // widget's data/ directory (txdb/receipts.py), not absolute —
          // the path a bare "file://" + that string resolves to doesn't
          // exist, which is how this first showed up as a silent blank box.
          source: receiptRow.receipt.thumbPath
            ? ("file://" + root.widgetDir + "/data/" + receiptRow.receipt.thumbPath)
            : (receiptRow.receipt.storedPath
                ? ("file://" + root.widgetDir + "/data/" + receiptRow.receipt.storedPath) : "")
          rotation: receiptRow.receipt.rotation || 0
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          sourceSize.height: Style.spaceReal(192)
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          preventStealing: true
          onClicked: root.openReceiptDetail(receiptRow.receipt)
        }
      }

      // The bill, neatly (see MiniBill); the full editor is in the review window.
      MiniBill {
        width: parent.width
        receipt: receiptRow.receipt
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

  // A transparent MouseArea stacked on top of a Flickable (declared after
  // it, so it is topmost and hit first) to take over its wheel handling.
  // Flickable's own built-in wheel-scroll claims the event before any
  // WheelHandler placed inside or as an ancestor of it ever sees it - the
  // same root cause already diagnosed for the photo pane's zoom, and the
  // reason the default wheel feel everywhere else in this widget was slow
  // and un-tunable. acceptedButtons: NoButton means it never intercepts
  // the press itself, so drag-to-scroll still reaches the Flickable
  // underneath untouched - only the wheel is rerouted here.
  //
  // The jump this applies is animated with a one-shot NumberAnimation,
  // not a `Behavior on contentY` on the target: a Behavior there would
  // also animate every contentY change Flickable's own drag handling
  // makes internally, fighting it frame by frame and making drag-to-
  // scroll feel laggy - the opposite of the point. Only a wheel-triggered
  // jump gets the easing; native drag/touch scrolling is untouched.
  component ScrollWheelArea: MouseArea {
    id: scrollWheel
    required property Flickable target
    // How many content pixels one wheel "line" (a mouse notch, or an
    // equivalent slice of trackpad pixelDelta) moves - tune this, not the
    // animation, to make scrolling faster or slower.
    property real speed: 2.5

    acceptedButtons: Qt.NoButton

    NumberAnimation {
      id: scrollAnim
      target: scrollWheel.target
      property: "contentY"
      duration: 90
      easing.type: Easing.OutCubic
    }

    onWheel: function (event) {
      // A touchpad reports smooth scrolling via pixelDelta (already real
      // pixels); angleDelta.y (eighths of a degree, 120 per notch on a
      // normal mouse wheel) is normalised against the same ~60px-per-
      // notch baseline browsers use, so both input types land in the same
      // speed scale.
      var raw = event.pixelDelta.y !== 0 ? event.pixelDelta.y : (event.angleDelta.y / 120) * 60
      if (raw !== 0) {
        var t = scrollWheel.target
        var maxY = Math.max(0, t.contentHeight - t.height)
        var y = Math.max(0, Math.min(maxY, t.contentY - raw * scrollWheel.speed))
        scrollAnim.to = y
        scrollAnim.restart()
      }
      event.accepted = true
    }
  }

  // A bill-style rule in the full-screen review window: one hairline, or a
  // doubled pair for a section boundary - the same "----" vs "====" a
  // printed till receipt uses to tell an item divider from the header/
  // GRAND TOTAL border.
  component FsRule: Item {
    id: fsRule
    property bool doubled: false
    width: parent.width
    height: fsRuleText.implicitHeight
    clip: true
    Text {
      id: fsRuleText
      width: parent.width
      textFormat: Text.PlainText
      wrapMode: Text.NoWrap
      text: (fsRule.doubled ? "=" : "-").repeat(120)
      color: Qt.darker(root.foreground, 1.8)
      font.family: "monospace"
      font.pixelSize: Style.font.caption
    }
  }

  // A blank box of the "add a product" row.
  component NewItemBox: TextField {
    color: root.foreground
    placeholderTextColor: Qt.darker(root.foreground, 2.0)
    font.family: "monospace"
    font.pixelSize: Style.font.caption
    background: Rectangle {
      radius: Style.cornerRadius
      color: Util.alpha(Color.accent, 0.08)
      border.width: 1
      border.color: Util.alpha(Color.accent, 0.4)
    }
  }

  // A text value of the bill (shop name, date, time, paid by) that edits where
  // it stands: plain text until clicked, then a box; Enter or clicking away
  // saves, Escape cancels. It is a fixed part of the card - not built per
  // refresh - so a database refresh while you type cannot close it. A date
  // must be a real one (DD-MM-YYYY and similar) or the box stays red and
  // nothing is saved.
  component InlineEdit: Item {
    id: ie
    property string fieldName: ""
    property string display: ""
    property string initial: ""
    property string placeholder: ""
    property color textColor: root.foreground
    property int hAlign: Text.AlignLeft
    property bool bold: false
    property int pixelSize: Style.font.caption
    property bool editing: false
    readonly property string billId: receiptFullScreen.r.id || ""
    readonly property bool invalid: ie.editing && ie.fieldName === "date"
      && Model.parseReceiptDate(input.text) === null
    onBillIdChanged: ie.editing = false

    implicitWidth: ie.editing ? Math.max(label.implicitWidth, Style.space(110)) : label.implicitWidth
    implicitHeight: ie.editing ? input.implicitHeight : label.implicitHeight

    Text {
      id: label
      visible: !ie.editing
      anchors.left: parent.left
      anchors.right: parent.right
      horizontalAlignment: ie.hAlign
      textFormat: Text.PlainText
      text: ie.display
      color: ie.textColor
      font.family: "monospace"
      font.bold: ie.bold
      font.pixelSize: ie.pixelSize
      wrapMode: Text.WordWrap
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        cursorShape: Qt.IBeamCursor
        onClicked: { input.text = ie.initial; ie.editing = true; input.forceActiveFocus(); input.selectAll() }
      }
    }

    TextField {
      id: input
      visible: ie.editing
      anchors.fill: parent
      horizontalAlignment: ie.hAlign
      placeholderText: ie.placeholder
      placeholderTextColor: Qt.darker(root.foreground, 2.0)
      color: ie.invalid ? root.debitColor : root.foreground
      font.family: "monospace"
      font.bold: ie.bold
      font.pixelSize: ie.pixelSize
      background: Rectangle {
        radius: Style.cornerRadius
        color: Util.alpha(Color.accent, 0.12)
        border.width: 1
        border.color: ie.invalid ? root.debitColor : Util.alpha(Color.accent, 0.6)
      }
      Keys.onEscapePressed: ie.editing = false
      onEditingFinished: {
        if (!ie.editing || ie.invalid) return
        var st = store
        var rid = receiptFullScreen.r.id
        var name = ie.fieldName
        var typed = text.trim()
        var changed = typed !== ie.initial.trim()
        if (name === "date") typed = Model.parseReceiptDate(typed)
        ie.editing = false
        if (changed) st.editReceiptField(rid, name, typed)
      }
    }
  }

  // A live log in a fixed-height box that scrolls: it follows the newest text
  // until you scroll up to read back (then it stays put; scroll to the bottom
  // to follow again), is selectable, and has a close button once it is done.
  component StreamBox: Item {
    id: sb
    property string text: ""
    property int boxHeight: Style.space(150)
    property bool closable: false
    signal closed()
    height: sb.boxHeight
    clip: true

    Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: Util.alpha(root.foreground, 0.05) }

    Flickable {
      id: sbFlick
      anchors.fill: parent
      anchors.margins: Style.space(6)
      clip: true
      contentWidth: width
      contentHeight: sbText.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      property bool follow: true
      property bool jumping: false
      onContentYChanged: if (!jumping) follow = contentY + height >= contentHeight - 12
      function toBottom() {
        jumping = true
        contentY = Math.max(0, contentHeight - height)
        jumping = false
        follow = true
      }

      TextEdit {
        id: sbText
        width: parent.width
        readOnly: true
        selectByMouse: true
        persistentSelection: true
        textFormat: TextEdit.PlainText
        text: sb.text
        wrapMode: TextEdit.WrapAnywhere
        color: Qt.darker(root.foreground, 1.4)
        font.family: "monospace"
        font.pixelSize: Style.font.caption
        onTextChanged: Qt.callLater(function () { if (sbFlick.follow) sbFlick.toBottom() })
      }
    }

    ScrollWheelArea { anchors.fill: sbFlick; target: sbFlick; speed: 2.5 }

    PanelActionButton {
      visible: sb.closable
      size: Style.space(20)
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      iconText: "×"
      tooltipText: "Close"
      foreground: root.foreground
      focusable: false
      onClicked: sb.closed()
    }
  }

  // One figure on an item row. Plain text until clicked; then only this
  // one becomes a box. Enter or clicking away saves, Escape cancels. The
  // qty cell takes "1.444kg" / "3 pc" and splits the unit off itself.
  component ItemCell: Item {
    id: ic
    property var line
    property string fieldName: ""
    property string display: ""
    property string initial: ""
    property color textColor: root.foreground
    property bool editing: false
    readonly property bool invalid: {
      var t = input.text.trim()
      if (!ic.editing || t === "") return false
      if (ic.fieldName === "qty") return !/^\d*\.?\d+\s*[^\d\s]*$/.test(t)
      return isNaN(Number(t))
    }
    implicitHeight: ic.editing ? input.implicitHeight : label.implicitHeight

    Text {
      id: label
      visible: !ic.editing
      anchors.left: parent.left
      anchors.right: parent.right
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: ic.display
      color: ic.textColor
      font.family: "monospace"
      font.pixelSize: Style.font.caption
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        cursorShape: Qt.IBeamCursor
        onClicked: { ic.editing = true; input.forceActiveFocus(); input.selectAll() }
      }
    }

    TextField {
      id: input
      visible: ic.editing
      anchors.fill: parent
      text: ic.initial
      horizontalAlignment: TextInput.AlignRight
      color: ic.invalid ? root.debitColor : root.foreground
      font.family: "monospace"
      font.pixelSize: Style.font.caption
      background: Rectangle {
        radius: Style.cornerRadius
        color: Util.alpha(Color.accent, 0.12)
        border.width: 1
        border.color: ic.invalid ? root.debitColor : Util.alpha(Color.accent, 0.6)
      }
      Keys.onEscapePressed: { input.text = ic.initial; ic.editing = false }
      onEditingFinished: {
        if (!ic.editing) return
        // Everything is read first: the first store call re-renders the
        // rows and destroys this cell, and nothing may touch it afterwards.
        var st = store
        var rid = receiptFullScreen.r.id
        var line = ic.line
        var field = ic.fieldName
        var t = text.trim()
        var changed = t !== ic.initial.trim()
        var ok = !ic.invalid
        ic.editing = false
        if (!ok || !changed) return
        if (field === "qty") {
          // "3" changes the number only; "3 pc" or "1.5kg" also sets the unit.
          // (Typing a bare number used to wipe the unit.)
          var m = /^(\d*\.?\d+)\s*(.*)$/.exec(t)
          if (m && m[2] !== "") st.editReceiptItemField(rid, line, "unit", m[2])
          st.editReceiptItemField(rid, line, "qty", m ? m[1] : t)
        } else {
          st.editReceiptItemField(rid, line, field, t)
        }
      }
    }
  }

  // One editable value in the full-screen review window: a label and a
  // value that is plain text until you click it - then just that one value
  // becomes a box (Enter or clicking away saves, Escape cancels). Nothing
  // else on the bill opens up. A numeric value that does not parse shows an
  // inline error and is not saved. `autoStart` opens it at once when it is
  // shown, for the header values chosen by clicking the title/date/time.
  //
  // `ledger: true` is the bill's right-aligned money layout (Subtotal, Bill
  // Discount, Round off, GRAND TOTAL); `big`/`valueColor` are for GRAND
  // TOTAL alone.
  component ReceiptEditField: Item {
    id: ef
    property bool ledger: false
    property bool big: false
    property var valueColor: null
    property string prefix: ""        // shown before the value, never part of what is typed or saved
    property var taxRate: null        // set on a GST row: save through the slab, not the header
    property var feeLine: null        // set on a fee row: save through that fee
    property bool autoStart: false
    signal finished()
    required property string label
    required property string fieldName
    required property string value
    property bool numeric: false
    property bool editing: ef.autoStart
    readonly property bool badDate: ef.editing && ef.fieldName === "date"
      && Model.parseReceiptDate(efInput.text) === null
    readonly property bool invalid: ef.badDate || (ef.editing && ef.numeric
      && efInput.text.trim() !== "" && isNaN(Number(efInput.text.trim())))
    width: parent.width
    height: efRow.implicitHeight + (ef.invalid ? Style.space(2) + efError.implicitHeight : 0)

    function startEditing() {
      ef.editing = true
      efInput.text = ef.value
      efInput.forceActiveFocus()
      efInput.selectAll()
    }
    Component.onCompleted: if (ef.autoStart) Qt.callLater(ef.startEditing)

    Column {
      id: efRow
      width: parent.width
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: efLabel
          width: ef.ledger ? Style.space(120) : Style.space(76)
          textFormat: Text.PlainText
          text: ef.label
          color: ef.big ? root.foreground : Qt.darker(root.foreground, 1.4)
          font.family: ef.ledger ? "monospace" : Style.font.family
          font.bold: ef.big
          font.pixelSize: ef.big ? Style.font.body : Style.font.caption
        }

        Text {
          visible: !ef.editing
          width: parent.width - efLabel.width - parent.spacing
          textFormat: Text.PlainText
          horizontalAlignment: ef.ledger ? Text.AlignRight : Text.AlignLeft
          text: ef.value ? ef.prefix + ef.value : "—"
          elide: Text.ElideRight
          color: ef.valueColor ? ef.valueColor
            : (ef.value && ef.ledger && Model.receiptIsBalanced(receiptFullScreen.r) ? root.creditColor
              : (ef.value ? Qt.darker(root.foreground, 1.2) : Qt.darker(root.foreground, 2.2)))
          font.family: ef.ledger ? "monospace" : Style.font.family
          font.bold: ef.big
          font.pixelSize: ef.big ? Style.font.body : Style.font.caption
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            cursorShape: Qt.IBeamCursor
            onClicked: ef.startEditing()
          }
        }

        TextField {
          id: efInput
          visible: ef.editing
          width: parent.width - efLabel.width - parent.spacing
          horizontalAlignment: ef.ledger ? TextInput.AlignRight : TextInput.AlignLeft
          text: ef.value
          color: ef.invalid ? root.debitColor : root.foreground
          font.family: ef.ledger ? "monospace" : Style.font.family
          font.bold: ef.big
          font.pixelSize: ef.big ? Style.font.body : Style.font.caption
          background: Rectangle {
            radius: Style.cornerRadius
            color: Util.alpha(Color.accent, 0.12)
            border.width: 1
            border.color: ef.invalid ? root.debitColor : Util.alpha(Color.accent, 0.6)
          }
          Keys.onEscapePressed: { ef.editing = false; ef.finished() }
          onEditingFinished: {
            if (!ef.editing) return
            if (ef.invalid) return
            // Read everything first: saving re-renders the bill and the
            // field may be destroyed by the time the store call returns.
            var st = store
            var rid = receiptFullScreen.r.id
            var name = ef.fieldName
            var rate = ef.taxRate
            var fee = ef.feeLine
            var typed = text
            var changed = text.trim() !== (ef.value || "").trim()
            // Dates are shown DD-MM-YYYY but stored ISO; a discount is
            // always a positive amount taken off, whatever sign the bill
            // printed it with.
            if (name === "date") typed = Model.parseReceiptDate(text)
            if (name === "discount") typed = text.replace(/^\s*-/, "")
            ef.editing = false
            ef.finished()
            if (!changed) return
            if (fee !== null) st.editReceiptFee(rid, fee, "amount", typed)
            else if (rate !== null) st.editReceiptTaxField(rid, rate, name, typed)
            else st.editReceiptField(rid, name, typed)
          }
        }
      }

      Text {
        id: efError
        visible: ef.invalid
        textFormat: Text.PlainText
        text: ef.badDate ? "Date needs DD-MM-YYYY (e.g. 25-06-2026)" : ef.label + " needs a plain number"
        color: root.debitColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
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
      preventStealing: true
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
    readonly property string accountName: Model.accountLabel(Model.cardLabelParts(
      Model.cardFallbackName(txn.accountType, txn.last4, store.cardOverviews, txn.bank),
      store.accountNameOverrides[txn.last4],
      (store.cardOverviews[txn.last4] || {}).network).label, txn.last4)
    readonly property string note: Model.transactionNote(txn)
    // The bill filed against this transaction, if any - its note icon opens it.
    readonly property var linkedReceipt: Model.linkedReceiptForTransaction(txn, store.receipts)
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

          // A small note: this transaction has a bill. Click it to open the
          // bill and its details.
          Rectangle {
            visible: !!card.linkedReceipt
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(20)
            height: width
            radius: Style.space(5)
            color: noteMouse.containsMouse ? Util.alpha(root.creditColor, 0.32) : Util.alpha(root.creditColor, 0.16)
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "󰎞"
              color: root.creditColor
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: noteMouse
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              preventStealing: true
              onClicked: root.openReceiptDetail(card.linkedReceipt)
            }
            ToolTip.visible: noteMouse.containsMouse
            ToolTip.text: "Bill: " + Model.receiptTitle(card.linkedReceipt || {}) + " — open"
            ToolTip.delay: 300
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

      // The bill filed against this transaction, shown right here (read live
      // off the receipt, never stored on the transaction - see
      // Model.receiptNoteForTransaction). The note icon beside the account
      // tag opens the full window to edit it.
      Column {
        visible: !!card.linkedReceipt
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "BILL  ·  " + Model.receiptTitle(card.linkedReceipt || ({}))
          color: root.creditColor
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        MiniBill {
          width: parent.width
          receipt: card.linkedReceipt || ({})
        }
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
