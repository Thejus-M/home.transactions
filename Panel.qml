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
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked && !t.accountClosed }).length
  readonly property int pendingTrackedCount: transactions.filter(function (t) { return t.tracked }).length

  // Photographed bills, unmatched ones first. receiptsToLink drives the
  // section header's count, the same way untrackedCount drives RECENT's.
  readonly property var receiptList: Model.receiptsSorted(store.receipts)
  // The RECEIPTS list folded away (its header and count stay).
  // The tab open under the chip line of RECENT: "" | "recurring" | "receipts" (saved in the filter file)
  property string drawerTab: ""
  onDrawerTabChanged: if (root.filterRestored) filterSaveTimer.restart()
  readonly property var recurringChip: Model.recurringChip(store.recurring)
  readonly property var receiptsChip: Model.receiptsChip(root.receiptList)
  readonly property var cashewControl: {
    var c = Model.cashewControl(root.cashewSync, cashewSyncProc.running || cashewChromiumProc.running)
    if (cashewChromiumProc.running) c = Object.assign({}, c, { tone: "busy", spin: true, glyph: "\u{F04E6}", badge: "",
      tooltip: "Syncing with Cashew (no window): " + (root.cashewChromiumLine || "starting…") })
    else if (root.cashewChromiumResult) c = Object.assign({}, c, { tooltip: root.cashewChromiumResult + "\n\n" + c.tooltip })
    return c
  }
  property bool recurringShowEnded: false
  readonly property var recurringSummary: Model.recurringSummary(store.recurring)
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
    if (!r) return
    if (r.storedPath) { Quickshell.execDetached(["xdg-open", root.widgetDir + "/data/" + r.storedPath]); return }
    if (r.imageSaved && r.imageSaved.bytes) {
      root._openPhotoAfterExport = r.id
      root.ensurePhotoExported(r)
      if (root._exportedPhotoIds[r.id] && !photoExportProc.running)
        Quickshell.execDetached(["xdg-open", root.cachedPhotoPath(r)])
    }
  }
  // Once a linked bill's own photo file is compressed into the database (see
  // the reader's compress_linked), there is no disk file for storedPath to
  // point at any more — only `receipt-image-export` can get the bytes back
  // out. The thumbnail alone (600 px) is too small to read a bill's fine
  // print, so a receipt in that state gets its database copy exported once
  // to a small on-disk cache the first time it is opened, and every full
  // photo view (in-app or "open externally") uses that from then on.
  readonly property string photoCacheDir: root.widgetDir + "/data/.photo-cache"
  function cachedPhotoPath(r) { return root.photoCacheDir + "/" + r.id + ".jpg" }
  // Local filesystem path (no "file://") to the best copy of this bill's
  // photo this session can show: the original file, or - once exported -
  // the cached copy of what is kept in the database. "" when neither exists
  // yet (an export may still be running; `photoCacheVersion` wakes bindings
  // that read this up once it finishes).
  function effectivePhotoFile(r) {
    if (!r) return ""
    if (r.storedPath) return root.widgetDir + "/data/" + r.storedPath
    if (r.imageSaved && r.imageSaved.bytes && root._exportedPhotoIds[r.id]) return root.cachedPhotoPath(r)
    return ""
  }
  property var _exportedPhotoIds: ({})
  property string _openPhotoAfterExport: ""
  // Bumped whenever an export finishes, purely so a `source:` binding that
  // reads effectivePhotoFile() is marked dirty and re-evaluates.
  property int photoCacheVersion: 0
  function ensurePhotoExported(r) {
    if (!r || r.storedPath || !(r.imageSaved && r.imageSaved.bytes)) return
    if (root._exportedPhotoIds[r.id] || photoExportProc.running) return
    photoExportProc.targetId = r.id
    photoExportProc.command = ["bash", "-c",
      "mkdir -p '" + root.photoCacheDir + "' && python3 '" + root.txdbBin +
      "' receipt-image-export '" + r.id + "' '" + root.cachedPhotoPath(r) + "'"]
    photoExportProc.running = true
  }
  Process {
    id: photoExportProc
    property string targetId: ""
    onExited: function (code) {
      if (code === 0) {
        var ids = root._exportedPhotoIds
        ids[targetId] = true
        root._exportedPhotoIds = ids
        root.photoCacheVersion += 1
        if (root._openPhotoAfterExport === targetId)
          Quickshell.execDetached(["xdg-open", root.photoCacheDir + "/" + targetId + ".jpg"])
      }
      root._openPhotoAfterExport = ""
    }
  }
  // Rows picked with their checkboxes (map: transaction id -> true). Separate
  // from "tracked": Track / Untrack act on the selection.
  property var selectedIds: ({})
  // id of the one card whose "i" panel is open ("t:<pair id>" / "x:<txn id>"); empty = none.
  property string infoOpenId: ""
  // Checkboxes and the selection controls show only in selection mode, which
  // the check button beside search turns on.
  property bool selectionMode: false
  // Only rows that are shown: a row hidden by a filter after it was ticked
  // must not be tracked by "Track (N)" behind the user's back.
  readonly property var selectedRows: filteredTransactions.filter(function (t) { return !!root.selectedIds[t.id] })
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

  // Everything RECENT is filtered by, as one object (see Model.defaultFilter):
  // search text, accounts, direction, tracked, transfers, bill, amount, month.
  // Always replace it, never mutate it, so bindings re-evaluate.
  property var filter: Model.defaultFilter()
  // The PORTFOLIO tab has its own search text. It used to share filter.q, so
  // a holdings search silently filtered RECENT (and the other way round).
  property string searchQuery: ""
  // Today (local ISO date). Refreshed when the popup opens, so "30d" and
  // "This month" do not go stale in a shell that runs for days.
  property string todayIso: Model.todayIso()
  // The inline filter panel under the RECENT header is open.
  property bool filterOpen: false
  function setFilterPart(part, value) {
    if (JSON.stringify(root.filter[part]) === JSON.stringify(value)) return
    root.filter = Model.filterWithPart(root.filter, part, value)   // a month clears the period
  }
  function toggleAccountFilter(key) {
    var list = root.filter.accounts.slice()
    var at = list.indexOf(key)
    if (at === -1) list.push(key)
    else list.splice(at, 1)
    root.setFilterPart("accounts", list)
  }
  function clearFilterPart(id) { root.filter = Model.removeFilterPart(root.filter, id) }
  function clearAllFilters() { root.filter = Model.defaultFilter() }
  function cycleFilterPart(part, order) {
    var at = order.indexOf(root.filter[part])
    root.setFilterPart(part, order[(at + 1) % order.length])
  }
  readonly property var accountOptions: Model.accountOptions(store.transactions, store.cardOverviews, store.accountNameOverrides)
  // accountChipOptions (below): the same accounts grouped by bank, bank
  // accounts before cards.
  readonly property var filterChips: Model.activeFilterChips(root.filter, root.accountOptions)
  readonly property var filterBounds: Model.filterBounds(root.transactions)
  readonly property var filteredTransactions: Model.filterTransactions(root.transactions, root.filter,
    { nameOverrides: store.transactionNameOverrides, linkedIds: root.linkedTransactionIds, today: root.todayIso,
      notes: store.txnNotes, bills: root.billSearchText })
  // transaction id -> the linked bill's text (merchant, items), for the search
  readonly property var billSearchText: {
    var m = {}
    for (var i = 0; i < store.receipts.length; i++) {
      var r = store.receipts[i]
      if (r.state !== "linked" || !r.transactionId) continue
      m[r.transactionId] = [r.merchant || "", r.title || "", (r.items || []).map(function (x) { return x.name || x.description || "" }).join(" ")].join(" ")
    }
    return m
  }

  // The filter is saved between restarts (never the search text or the
  // month). Restored once, after the accounts are known, so a saved account
  // that no longer exists is dropped. Writes are debounced and skipped when
  // the JSON has not changed.
  property bool filterRestored: false
  property string filterSavedJson: ""
  property string filterFileText: ""
  function restoreSavedFilter() {
    if (root.filterRestored || root.filterFileText === "") return
    // Wait for the transactions themselves: card overviews alone can fill
    // accountOptions first, and the bank accounts would be dropped as unknown.
    if (root.transactions.length === 0) return
    root.filterRestored = true
    var restored = Model.restoreFilter(root.filterFileText, root.accountOptions)
    root.filterSavedJson = Model.serializeFilter(restored, root.drawerTab)
    // Keep what the user typed or picked while the file was loading.
    restored.q = root.filter.q
    restored.month = root.filter.month
    restored.from = root.filter.from || ""
    restored.to = root.filter.to || ""
    root.filter = restored
  }
  // The chips are rebuilt only when the account list really changed, not on
  // every data refresh: a rebuilt Repeater drops keyboard focus.
  property var accountChipOptions: []
  function syncAccountChipOptions() {
    var next = root.accountOptions.slice().sort(function (a, b) {
      if (a.bank !== b.bank) return a.bank < b.bank ? -1 : 1
      if (a.accountType !== b.accountType) return a.accountType === "checking" ? -1 : 1
      return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0)
    })
    if (JSON.stringify(next) !== JSON.stringify(root.accountChipOptions)) root.accountChipOptions = next
  }
  onAccountOptionsChanged: { root.syncAccountChipOptions(); root.restoreSavedFilter() }
  onFilterChanged: if (root.filterRestored) filterSaveTimer.restart()
  Timer {
    id: filterSaveTimer
    interval: 120
    onTriggered: root.flushFilterSave()
  }
  // Writes the filter now if it differs from what is on disk. Also called
  // from Component.onDestruction so a late change survives a shell quit.
  function flushFilterSave() {
    filterSaveTimer.stop()
    if (!root.filterRestored) return
    var json = Model.serializeFilter(root.filter, root.drawerTab)
    if (json === root.filterSavedJson) return
    root.filterSavedJson = json
    filterFile.setText(json + "\n")
  }
  FileView {
    id: filterFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-filter.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.filterFileText = text() || ""
      root.drawerTab = Model.drawerRestore(root.filterFileText)
      if (root.filterFileText === "") root.filterRestored = true
      else root.restoreSavedFilter()
    }
    onLoadFailed: root.filterRestored = true
  }
  // ------------------------------------------------------------ Cashew
  // The verify window (cashewWin below) turns the untracked, settled rows
  // into Cashew links. The drafts and links come from `txdb cashew-draft` and
  // `txdb cashew-links`; the widget only edits and shows them. The state file
  // (merchant -> category, bank account -> Cashew name) is written here and
  // only read by Python.
  property bool cashewOpen: false
  // True until the window has loaded its drafts, and again after every real close.
  property bool cashewStale: true
  onCashewOpenChanged: if (!root.cashewOpen) root.cashewStale = true
  // Every AI category confirmed: the review UI has done its job.
  onCashewGuessedCountChanged: if (root.cashewGuessedCount === 0 && !root.cashewGuessing) cashewWin.resultsOpen = false
  property bool cashewLoading: false
  property string cashewError: ""
  property var cashewDrafts: []
  property var cashewDedupe: ({ ok: true, found: 0, unknownAccounts: [] })
  readonly property var cashewInCashewRows: root.cashewDrafts.filter(function (d) { return d.inCashew === true })
  property var cashewShown: []        // indexes into cashewDrafts that the table shows
  property var cashewCategories: []
  property var cashewAccountNames: []
  property var cashewState: ({ version: 1, categories: {}, accounts: {} })
  property string cashewStateSavedJson: ""
  property bool cashewStateLoaded: false
  // The window carries the same filter bar as the main list and always follows it.
  property bool cashewOnlyFilter: true
  property bool cashewGuessedOnly: false   // the list shows only rows guessed by the model
  property var cashewLinks: []
  property var cashewTransfers: []    // paired transfers: one addTransferRoute page each
  property var cashewWarnings: []
  readonly property var cashewRefundNotes: Model.cashewRefundNotes(root.cashewDrafts, root.cashewShown)
  // Rows a Cashew link would store wrongly (a refund in its purchase's category, a payment under an income
  // category) are added by file. The button in the window makes that file (txdb cashew-fix).
  readonly property int cashewFileRows: Model.cashewFileRows(root.cashewDrafts, root.cashewShown)
  property bool cashewFixing: false
  property string cashewFixPath: ""
  property string cashewFixMessage: ""
  // ---- automatic sync (txdb cashew-sync). After every change of the data (a fetch, a category, a note,
  // tracked or not) and every 2 minutes (Cashew itself may have changed, for example after an import), the
  // ready rows that Cashew does not have yet are written into one file, cashew-sync.sql. The badge next to the
  // Cashew chip shows how many wait; a click copies the file path and opens Cashew for the import. Rows Cashew
  // already has are marked as tracked when "After adding: mark as tracked" is on.
  property var cashewSync: ({ pending: -1, transfers: 0, waitingCategory: 0, inCashewIds: [], editedIds: [], path: "", error: "" })
  // rows Cashew has that were edited in the widget since the last sync: their mark says "needs sync"
  readonly property var cashewEditedIds: {
    var m = {}
    ;(root.cashewSync.editedIds || []).forEach(function (i) { m[i] = true })
    return m
  }
  readonly property string cashewSyncLabel: root.cashewSync.recatWaiting ? "Import the recategorise file first"
    : root.cashewSync.error ? "Sync: " + root.cashewSync.error
    : root.cashewSync.pending < 0 ? "Sync: checking…"
    : root.cashewSync.pending === 0 ? "Cashew is up to date"
    : "Import " + root.cashewSync.pending + (root.cashewSync.pending === 1 ? " change" : " changes") + " into Cashew"
  function cashewSyncNow() {
    if (cashewSyncProc.running) { cashewSyncTimer.interval = 1500; cashewSyncTimer.restart(); return }
    cashewSyncProc.running = true
  }
  // Cashew changed (an import, a row added in Cashew): its storage files change, and the sync runs within
  // seconds. The check is one cheap command every 5 s; the full sync only when its output changes.
  property string cashewStamp: ""
  Timer { interval: 5000; running: true; repeat: true; onTriggered: if (!cashewStampProc.running) cashewStampProc.running = true }
  Process {
    id: cashewStampProc
    command: ["python3", root.txdbBin, "cashew-stamp"]
    stdout: StdioCollector { id: cashewStampOut }
    onExited: function (exitCode) {
      var s = (cashewStampOut.text || "").trim()
      if (s === "" || s === root.cashewStamp) return
      var first = root.cashewStamp === ""
      root.cashewStamp = s
      if (!first) { cashewSyncTimer.interval = 3000; cashewSyncTimer.restart() }
    }
  }
  // A click checks first; Cashew opens only when rows really still wait (after an import it does not).
  property bool cashewSyncClicked: false
  // The sync button: a Chromium window off the screen edge logs in to Cashew, puts the waiting rows straight
  // into the open page, pulls down so Cashew syncs with Google Drive, and closes (txdb cashew-chromium sync).
  property string cashewChromiumLine: ""
  property string cashewChromiumResult: ""
  function cashewSyncClick() {
    if (cashewChromiumProc.running) return
    // the tick: nothing waits, so a click does nothing (a sync runs only when there is something to send)
    if (!root.cashewSync.error && !root.cashewSync.recatWaiting && root.cashewSync.pending === 0) return
    root.cashewChromiumLine = ""
    root.cashewChromiumResult = ""
    cashewChromiumProc.running = true
  }
  Process {
    id: cashewChromiumProc
    command: ["python3", root.txdbBin, "cashew-chromium", "sync", "--send", "--json"]
    stdout: StdioCollector { id: cashewChromiumOut }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { if (line.trim()) root.cashewChromiumLine = line.trim() }
    }
    onExited: function (exitCode) {
      var r
      try { r = JSON.parse((cashewChromiumOut.text || "").trim().split("\n").pop()) } catch (e) { r = { error: root.cashewChromiumLine || "no result" } }
      if (r.error || !r.signedIn) {
        root.cashewChromiumResult = "Last sync failed: " + (r.error || root.cashewChromiumLine)
        root.cashewGuessNotify("Cashew sync failed", r.error || root.cashewChromiumLine)
      } else {
        var calls = (r.driveCalls || []).filter(function (c) { return c.indexOf("OPTIONS") !== 0 }).length
        root.cashewChromiumResult = "Last sync: " + (r.added || 0) + (r.added === 1 ? " row" : " rows") + " sent"
          + (calls > 0 ? ", synced with Google Drive" : ", but Cashew made no Drive calls")
        root.cashewGuessNotify("Cashew synced", root.cashewChromiumResult.replace("Last sync: ", ""))
      }
      root.cashewSyncNow()            // the sent rows are in Cashew now: the count goes to 0, auto-track marks them
      root.refreshData()
    }
  }
  function cashewSyncAfterClick() {
    root.cashewSyncClicked = false
    if (root.cashewSync.error) return
    if (root.cashewSync.recatWaiting) {
      Quickshell.execDetached(["wl-copy", root.cashewSync.recatWaiting])
      Quickshell.execDetached(["xdg-open", "https://budget-track.web.app/"])
      root.cashewGuessNotify("Cashew: import the recategorise file", "Path copied: " + root.cashewSync.recatWaiting
        + "\nIn Cashew: Settings, Backup, Import. The sync waits until it is imported.")
      return
    }
    if (root.cashewSync.pending > 0 && root.cashewSync.path) {
      Quickshell.execDetached(["wl-copy", root.cashewSync.path])
      Quickshell.execDetached(["xdg-open", "https://budget-track.web.app/"])
      root.cashewGuessNotify("Cashew: import the sync file", "Path copied: " + root.cashewSync.path
        + "\nIn Cashew: Settings, Backup, Import. Use the only open Cashew tab and refresh it when it asks.")
    } else {
      root.cashewGuessNotify("Cashew is up to date", root.cashewSync.waitingCategory > 0
        ? root.cashewSync.waitingCategory + " rows still need a category." : "Nothing to import.")
    }
  }
  Timer { id: cashewSyncTimer; interval: 8000; onTriggered: root.cashewSyncNow() }
  Timer { interval: 300000; running: true; repeat: true; onTriggered: root.cashewSyncNow() }   // a safety net
  onTransactionsChanged: { cashewSyncTimer.interval = 8000; cashewSyncTimer.restart() }
  Process {
    id: cashewSyncProc
    command: ["python3", root.txdbBin, "cashew-sync", "--chromium"]
    stdout: StdioCollector { id: cashewSyncOut }
    onExited: function (exitCode) {
      var r
      try { r = JSON.parse((cashewSyncOut.text || "").trim().split("\n").pop()) } catch (e) { r = { error: "no result" } }
      var before = root.cashewSync.pending
      root.cashewSync = r.error ? Object.assign({}, root.cashewSync, { error: String(r.error).slice(0, 60) })
        : { pending: r.pending, rows: r.rows || 0, notes: r.notes || 0, edits: r.edits || 0, editedIds: r.editedIds || [], corrections: r.corrections || [],
            transfers: r.transfers, waitingCategory: r.waitingCategory, inCashewIds: r.inCashewIds || [], path: r.path || "",
            recatWaiting: r.recatWaiting || "", error: "" }
      // the options come from the state file through the script: this runs even when the Cashew window
      // never opened (then root.cashewState is not loaded)
      var done = (r.inCashewIds || []).concat(r.writtenIds || [])
      if (!r.error && r.autoTrack === true && done.length > 0)
        store.setTrackedMany(done.map(function (id) { return { id: id } }), true)
      if (!r.error && r.direct && r.written > 0)
        root.cashewGuessNotify("Cashew: " + r.written + (r.written === 1 ? " row" : " rows") + " written straight in",
          "Zen was closed, so the rows went straight into Cashew's storage. Backup: " + r.backup)
      if (root.cashewSyncClicked) root.cashewSyncAfterClick()
      if (!r.error && r.pending > 0 && r.pending !== before)
        root.cashewGuessNotify("Cashew: " + r.pending + (r.pending === 1 ? " row waits" : " rows wait"),
          "The sync file is ready: click the sync badge next to Cashew, then import it in Cashew.")
    }
  }

  // "Create the Cashew file" (txdb cashew-file): the ticked, shown rows written straight into a copy of the
  // Cashew database, for Cashew's own import. No browser window. After the file is made the widget waits (up
  // to 30 min) for the import: when Cashew has the new rows, they are marked "already in Cashew" (and tracked
  // when that option is on). The links stay as they are.
  property string cashewFixInput: ""
  property var cashewFileIds: []
  property int cashewFileAdded: 0
  property bool cashewImportWaiting: false
  property int cashewFileBase: 0
  function cashewFixStart() {
    if (root.cashewFixing || cashewFixProc.running || root.cashewSending || root.cashewSendPaused || !root.cashewVerifyGate()) return
    var keep = ({})
    root.cashewShown.forEach(function (i) { keep[i] = true })
    var chosen = root.cashewDrafts.filter(function (d, i) { return keep[i] && d.include !== false && d.inCashew !== true })
    root.cashewFixing = true
    root.cashewFixPath = ""
    root.cashewFixMessage = ""
    cashewImportWaitProc.running = false
    root.cashewImportWaiting = false
    root.cashewFixInput = JSON.stringify({ drafts: chosen }) + "\n"
    cashewFixProc.running = true
  }
  Process {
    id: cashewFixProc
    command: ["python3", root.txdbBin, "cashew-file", "-"]
    stdinEnabled: true
    stdout: StdioCollector { id: cashewFixOut }
    stderr: StdioCollector { id: cashewFixErr }
    onRunningChanged: if (cashewFixProc.running && root.cashewFixInput !== "") {
      cashewFixProc.write(root.cashewFixInput)
      root.cashewFixInput = ""
    }
    onExited: function (exitCode) {
      var r = Model.cashewFileResult(cashewFixOut.text, cashewFixErr.text)
      root.cashewFixPath = r.path
      root.cashewFixMessage = r.message
      root.cashewFixing = false
      root.cashewFileIds = r.ids
      root.cashewFileAdded = r.added
      root.cashewFileBase = r.base
      if (r.path !== "" && r.added > 0) {
        root.cashewImportWaiting = true
        cashewImportWaitProc.command = ["python3", root.txdbBin, "cashew-wait", String(r.added), "--timeout", "1800"]
        cashewImportWaitProc.running = true
        root.cashewGuessNotify("Cashew file ready", r.message + "\n" + r.path)
      }
    }
  }
  // Confirms the import: Cashew's row count rises by the rows of the file.
  Process {
    id: cashewImportWaitProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        var m
        try { m = JSON.parse(line) } catch (e) { return }
        if (m.added !== undefined && root.cashewImportWaiting)
          root.cashewFixMessage = "Waiting for the import in Cashew: " + Math.max(0, m.added) + " of " + root.cashewFileAdded + " rows there."
      }
    }
    onExited: function (exitCode) {
      if (!root.cashewImportWaiting) return
      root.cashewImportWaiting = false
      if (exitCode !== 0) {
        root.cashewFixMessage = "The import was not seen in 30 minutes. Import the file, then press Create the Cashew file again: rows already in Cashew are left out."
        return
      }
      // Cashew web asks for a refresh after an import; until then the tab holds the old database and can
      // still write it back. So the rows must still be there 30 s later.
      root.cashewImportWaiting = true
      root.cashewFixMessage = "Import seen. Refresh the Cashew tab when it asks; checking again in 30 s that the rows stay."
      cashewImportRecheck.restart()
    }
  }
  Timer {
    id: cashewImportRecheck
    interval: 30000
    onTriggered: if (root.cashewImportWaiting) cashewImportCountProc.running = true
  }
  Process {
    id: cashewImportCountProc
    command: ["python3", root.txdbBin, "cashew-count"]
    stdout: StdioCollector { id: cashewImportCountOut }
    onExited: function (exitCode) {
      if (!root.cashewImportWaiting) return
      root.cashewImportWaiting = false
      var n = parseInt((cashewImportCountOut.text || "").trim(), 10)
      if (!(n >= root.cashewFileBase + root.cashewFileAdded)) {
        root.cashewFixMessage = "The import did not stay: Cashew has " + (isNaN(n) ? "?" : n) + " rows, it should have "
          + (root.cashewFileBase + root.cashewFileAdded) + ". Another Cashew tab probably wrote its old data back. Close all Cashew tabs but one, refresh it, and import the file again."
        root.cashewGuessNotify("Cashew: the import did not stay", root.cashewFixMessage)
        return
      }
      var done = ({})
      root.cashewFileIds.forEach(function (id) { done[id] = true })
      root.cashewDrafts = root.cashewDrafts.map(function (d) {
        return done[d.id] ? Object.assign({}, d, { inCashew: true, include: false }) : d
      })
      root.cashewRebuildLinks()
      var tracked = root.cashewAutoTrack
      if (tracked) {
        store.setTrackedMany(root.cashewFileIds.map(function (id) { return { id: id } }), true)
        cashewSendReloadTimer.restart()
      }
      root.cashewFixMessage = "Imported: Cashew has the " + root.cashewFileAdded + " new rows" + (tracked ? " (marked as tracked)." : ".")
      root.cashewGuessNotify("Cashew: import confirmed", root.cashewFixMessage)
    }
  }
  property string cashewLinksError: ""
  // Same set the Python side drafts: untracked and settled.
  readonly property int cashewCount: transactions.filter(function (t) { return !t.tracked && !t.accountClosed }).length
  readonly property string cashewBase: root.cashewState.base === "web" ? "web" : "app"
  // Every model run in progress (AI categories, the bill scan, a bill reparse): the minimised windows show them.
  readonly property var llmLines: Model.llmStatusLines({
    guessing: root.cashewGuessing,
    guessText: root.cashewGuessing ? Model.cashewGuessProgressText(root.cashewGuessProgress, root.cashewGuessDone, root.cashewGuessTotal) : "",
    importing: receiptImportProc.running, importText: receiptImportOutput.text,
    reparsing: receiptReparseProc.running, reparseText: receiptReparseOutput.text,
    reparseTitle: (function () {
      var id = receiptReparseProc.receiptId, list = root.receiptList
      for (var i = 0; i < list.length; i++) if (list[i].id === id) return Model.receiptTitle(list[i])
      return ""
    })()
  })
  // Always "page": one Cashew transfer page per pair, a real LINKED transfer (tap Save in Cashew; "Add all"
  // waits for the tap). The old "silent" mode put both legs in the bulk link as two separate Balance
  // Correction rows, which Cashew cannot link (a link cannot set paired_transaction_fk); it is gone.
  readonly property string cashewTransferMode: "page"
  readonly property int cashewIncludedCount: Model.cashewIncluded(root.cashewDrafts, root.cashewShown).length
  // Rows of a closed account never reach the window's counts or links.
  readonly property var cashewClosedIds: {
    var set = ({})
    transactions.forEach(function (t) { if (t.accountClosed) set[t.id] = true })
    return set
  }
  readonly property var cashewFilterIds: {
    var set = ({})
    root.filteredTransactions.forEach(function (t) { set[t.id] = true })
    return set
  }

  // Unconfirmed AI categories are saved in the state file, so closing loses nothing.
  function closeCashew() {
    root.flushCashewSave()
    root.cashewOpen = false
  }
  function cashewLoad() {
    root.flushCashewSave()            // the file must hold the latest unconfirmed guesses before it is read back
    root.cashewStateLoaded = false    // nothing may rewrite the state from the empty drafts while loading
    root.cashewGuessError = ""
    root.cashewGuessLog = []
    root.cashewGuessRaw = []
    root.cashewGuessMeta = ({ batches: 0, seconds: 0, model: "" })
    root.cashewGuessGroupMap = ({})
    root.cashewLoading = true
    root.cashewError = ""
    root.cashewDrafts = []
    root.cashewShown = []
    root.cashewLinks = []
    root.cashewTransfers = []
    root.cashewWarnings = []
    root.cashewLinksError = ""
    if (!cashewDraftProc.running) cashewDraftProc.running = true
  }
  function cashewApplyDrafts(text) {
    if (!root.cashewOpen || text.trim() === "") return
    var data
    try { data = JSON.parse(text) } catch (e) { data = null }
    if (!data || !Array.isArray(data.drafts)) {
      root.cashewError = "The draft reader printed something that is not valid JSON."
      root.cashewLoading = false
      return
    }
    root.cashewCategories = data.categories || []
    root.cashewAccountNames = data.accountNames || []
    root.cashewState = data.state || ({ version: 1, categories: {}, accounts: {} })
    root.cashewStateSavedJson = JSON.stringify(root.cashewState)
    root.cashewStateLoaded = true
    if (root.cashewState.transfers !== undefined) {      // the old silent / page switch: gone
      var clean = Object.assign({}, root.cashewState)
      delete clean.transfers
      root.cashewState = clean
      cashewStateTimer.restart()
    }
    var mp = root.cashewState.mini
    if (mp && typeof mp.x === "number" && typeof mp.y === "number") { root.miniX = mp.x; root.miniY = mp.y }
    // Unconfirmed AI guesses saved in the state file come back as they were.
    // Which rows Cashew already has (txdb/cashew_dedupe.py): marked inCashew and not included.
    root.cashewDedupe = data.dedupe || ({ ok: false, reason: "the draft reader did not check Cashew" })
    root.cashewDrafts = Model.cashewRestorePending(data.drafts, root.cashewState)
    root.cashewLoading = false
    root.cashewReshow()   // also builds the links, once
    Qt.callLater(root.cashewAutoGuessStart)
  }
  // Recomputes which drafts the table shows; skipped when nothing changed so
  // the list keeps its scroll position.
  function cashewReshow() {
    var next = Model.cashewShownIndexes(root.cashewDrafts, root.cashewOnlyFilter, root.cashewFilterIds, root.cashewClosedIds)
    if (JSON.stringify(next) !== JSON.stringify(root.cashewShown)) root.cashewShown = next
    root.cashewRebuildLinks()
  }
  onCashewOnlyFilterChanged: if (root.cashewOpen) root.cashewReshow()
  onCashewFilterIdsChanged: if (root.cashewOpen && root.cashewOnlyFilter) root.cashewReshow()
  // Every edit replaces the drafts array once.
  // The ListView model is cashewShown (row indexes), not the drafts, so a new
  // drafts array re-reads each row but keeps every delegate and the scroll.
  // `typed` is true for a text cell: its rebuild waits 30 ms.
  function cashewEdit(next, typed) {
    root.cashewDrafts = next
    root.cashewSetState(root.cashewState)   // keeps the saved unconfirmed guesses in step
    if (typed === true) root.cashewQueueLinks()
    else root.cashewRebuildLinks()
  }
  // The select-all checkbox: only the rows the list shows now (its own filters included); turning rows on
  // leaves the ones the drafter turned off on purpose (a netted refund, a leg whose partner is tracked).
  function cashewSetAll(value) {
    root.cashewEdit(Model.cashewSetInclude(root.cashewDrafts, cashewWin.rowIdxs, value))
  }
  // Where the minimised cards sit (top-left corner, in the screen's coordinates); -1 = the bottom-right corner.
  property real miniX: -1
  property real miniY: -1
  function saveMiniPos(x, y) {
    root.miniX = Math.round(x)
    root.miniY = Math.round(y)
    if (root.cashewStateLoaded)
      root.cashewSetState(Object.assign({}, root.cashewState, { mini: { x: root.miniX, y: root.miniY } }))
  }
  function cashewSetState(next) {
    if (!root.cashewStateLoaded) { root.cashewState = next; return }
    // `pending` / `tried` always mirror the drafts and the run log (Model.cashewStateWithPending).
    var withPending = Model.cashewStateWithPending(next, root.cashewDrafts, root.cashewGuessLog)
    if (JSON.stringify(withPending) === JSON.stringify(root.cashewState)) return
    root.cashewState = withPending
    cashewStateTimer.restart()
  }
  // ---- auto-guess categories (txdb cashew-guess, local Ollama). Rows are
  // filled in as each batch finishes; nothing is remembered until accepted.
  property bool cashewGuessing: false
  property bool cashewGuessStopping: false
  property int cashewGuessDone: 0
  property int cashewGuessTotal: 0
  property string cashewGuessError: ""
  property var cashewGuessProgress: ({})       // last {batch, of, phase, tokens, elapsed} line
  property string cashewGuessDoneLine: ""      // what the last finished run left
  // "Stop" needs a second click within 6 s: the same button starts a run, and a
  // second click on "the button that seems to do nothing" used to cancel it.
  property bool cashewStopArmed: false
  Timer { id: cashewStopTimer; interval: 6000; onTriggered: root.cashewStopArmed = false }
  // A desktop alert each time a run ends, so a 6 minute run can be left alone.
  function cashewGuessNotify(title, body) {
    Quickshell.execDetached([
      Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
      "--app-name", "home.transactions", title, body
    ])
  }
  function cashewStopClick() {
    if (!root.cashewStopArmed) { root.cashewStopArmed = true; cashewStopTimer.restart(); return }
    root.cashewStopArmed = false
    cashewStopTimer.stop()
    root.cashewGuessStop()
  }
  property string cashewGuessInput: ""
  // Result log of the last run: one entry per row sent (see Model.cashewGuessLogNew).
  property var cashewGuessLog: []
  property var cashewGuessRaw: []      // the NDJSON lines received, the last 200
  property var cashewGuessMeta: ({ batches: 0, seconds: 0, model: "" })
  // Representative transaction id -> every transaction id it stands in for
  // (same-UPI-counterparty grouping, see Model.cashewGuessGroups). Built
  // fresh at the start of each run; lets a single result from the model be
  // copied onto every transaction asked about together.
  property var cashewGuessGroupMap: ({})
  readonly property var cashewGuessCounts: Model.cashewGuessLogCounts(root.cashewGuessLog)
  readonly property var cashewGuessPrefs: root.cashewState.guess || ({})
  // Ollama here loads one model at a time (OLLAMA_MAX_LOADED_MODELS=1): a
  // second worker just queues behind the first and barely helps (measured:
  // 3 workers were only ~20% faster than 1 on this machine), so guesses run
  // one at a time - simpler, and the per-row timing stays meaningful.
  readonly property int cashewGuessWorkers: 1
  // Rows with no category (notes or not); the ask-me flow walks them.
  readonly property int cashewNeedCount: Model.cashewNeedIdxs(root.cashewDrafts, root.cashewShown).length
  // Rows with a note and no category: the only ones the model reads.
  readonly property int cashewGuessCount: Model.cashewGuessRows(root.cashewDrafts, root.cashewShown, Model.cashewTriedAll(root.cashewState, root.cashewGuessLog)).length
  readonly property int cashewGuessedCount: Model.cashewGuessedCount(root.cashewDrafts)
  function cashewSetGuessPref(patch) {
    var prefs = Object.assign({}, root.cashewGuessPrefs, patch)
    delete prefs.onlyUncategorized   // old state files: the "All rows" mode is gone
    delete prefs.workers              // old state files: guesses always run one at a time now
    root.cashewSetState(Object.assign({}, root.cashewState, { guess: prefs }))
  }
  // The AI run for the rows whose category is only the HDFC default but which have a UPI remark: it starts by
  // itself when the window loads (Options can turn it off). Its answers wait for "Confirm" like any guess.
  readonly property bool cashewAutoGuess: root.cashewState.autoGuess !== false
  function cashewAutoGuessStart() {
    if (!root.cashewOpen || !root.cashewAutoGuess || root.cashewGuessing || cashewGuessProc.running) return
    if (root.cashewGuessedCount > 0) return               // guesses already wait for the person
    root.cashewGuessStart(true)
  }
  function cashewGuessStart(defaultedOnly) {
    if (root.cashewGuessing || cashewGuessProc.running) return
    var rows = Model.cashewGuessRows(root.cashewDrafts, root.cashewShown, Model.cashewTriedAll(root.cashewState, root.cashewGuessLog), defaultedOnly === true)
    if (rows.length === 0) return
    // Same-UPI-counterparty rows (Model.cashewGuessGroups) are asked about
    // once: one representative per group goes to the model, and its answer
    // is copied back onto every transaction in the group (cashewGuessLine
    // below, via cashewGuessGroupMap). A counterparty with only one
    // untracked row right now is its own group of 1 - unchanged behaviour.
    var groups = Model.cashewGuessGroups(rows)
    var requestRows = Model.cashewGuessRequestRows(groups)
    root.cashewGuessGroupMap = Model.cashewGuessGroupMap(groups)
    root.cashewGuessError = ""
    root.cashewGuessProgress = ({})
    root.cashewGuessDoneLine = ""
    root.cashewStopArmed = false
    root.cashewGuessDone = 0
    root.cashewGuessTotal = requestRows.length
    root.cashewGuessStopping = false
    root.cashewGuessLog = Model.cashewGuessLogNew(rows, root.cashewDrafts)
    root.cashewGuessRaw = []
    root.cashewGuessMeta = ({ batches: Math.ceil(requestRows.length / 8), seconds: 0, model: "" })
    root.cashewGuessInput = JSON.stringify({ rows: requestRows, taught: Model.cashewTaught(root.cashewState) }) + "\n"
    cashewGuessProc.command = ["python3", root.txdbBin, "cashew-guess", "-", "--workers", String(root.cashewGuessWorkers), "--batch", "8"]
    root.cashewGuessing = true
    cashewGuessProc.running = true
  }
  function cashewGuessStop() {
    if (!cashewGuessProc.running) { root.cashewGuessing = false; return }
    root.cashewGuessStopping = true
    cashewGuessProc.running = false
  }
  function cashewGuessLine(line) {
    if (line.trim() === "") return
    root.cashewGuessRaw = Model.cashewGuessRawPush(root.cashewGuessRaw, line, 200)
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (m.error) root.cashewGuessError = String(m.error)
    if (m.progress) { root.cashewGuessProgress = m.progress; return }
    if (m.finished) {
      var answered = Number(m.answered) || 0
      root.cashewSetState(root.cashewState)   // saves which rows got no answer
      root.cashewGuessDoneLine = Model.cashewGuessDoneText(answered, Number(m.total) || 0, Number(m.seconds) || 0)
      if (answered === 0 && root.cashewGuessError === "") root.cashewGuessError = "The AI gave no category for any row. See Results for the raw reply."
      root.cashewGuessNotify(answered === 0 ? "AI categories: no answer" : "AI categories finished", root.cashewGuessDoneLine)
      // Keep the review UI in front until every guess is confirmed (accepted or reverted).
      if (answered > 0) { cashewWin.resultsFilter = "guessed"; cashewWin.resultsOpen = true }
      root.cashewGuessLog = Model.cashewGuessLogFinish(root.cashewGuessLog)
      root.cashewGuessMeta = Object.assign({}, root.cashewGuessMeta, { seconds: Number(m.seconds) || 0, model: String(m.model || "") })
    }
    if (m.results) {
      // m.results is keyed by the representative transaction of each group
      // (see cashewGuessStart); expand it back to one entry per actual
      // transaction before touching the log or the drafts, so grouping is
      // invisible to cashewGuessLogApply/cashewApplyGuesses below - each
      // member still gets its own guess applied and validated exactly like
      // an ungrouped row always has.
      var expanded = Model.cashewGuessExpandResults(m.results, root.cashewGuessGroupMap)
      root.cashewGuessLog = Model.cashewGuessLogApply(root.cashewGuessLog, root.cashewDrafts, expanded)
      root.cashewEdit(Model.cashewApplyGuesses(root.cashewDrafts, expanded))
      root.cashewGuessDone = m.done
      root.cashewGuessTotal = m.total
    }
  }
  function cashewAcceptGuesses() {
    var ids = Model.cashewGuessLogLive(root.cashewGuessLog, root.cashewDrafts)
    var r = Model.cashewAcceptGuesses(root.cashewDrafts, root.cashewState)
    root.cashewGuessLog = Model.cashewGuessLogMark(root.cashewGuessLog, ids, "accepted")
    root.cashewEdit(r.drafts)
    root.cashewSetState(r.state)
  }
  // One or more rows of the results list: remember each for its merchant,
  // like "Accept guesses". A row not currently guessed (already accepted,
  // reverted, or hand-edited) is silently skipped - safe to pass a whole
  // group's ids at once for "Apply to all N".
  function cashewAcceptGuessRows(ids) {
    var r = Model.cashewAcceptSome(root.cashewDrafts, root.cashewState, ids)
    root.cashewGuessLog = Model.cashewGuessLogMark(root.cashewGuessLog, ids, "accepted")
    root.cashewEdit(r.drafts)
    root.cashewSetState(r.state)
  }
  function cashewAcceptOneGuess(id) {
    root.cashewAcceptGuessRows([id])
  }
  // Puts the rows in `ids` (null = every guessed row of the log) back as they were.
  function cashewRevertGuessRows(ids) {
    var list = ids || Model.cashewGuessLogLive(root.cashewGuessLog, root.cashewDrafts)
    if (list.length === 0) return
    var next = Model.cashewRevertGuesses(root.cashewDrafts, root.cashewGuessLog, list)
    root.cashewGuessLog = Model.cashewGuessLogMark(root.cashewGuessLog, list, "reverted")
    root.cashewEdit(next)
  }
  Process {
    id: cashewGuessProc
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.cashewGuessLine(line) }
    }
    stderr: StdioCollector { id: cashewGuessErr }
    onRunningChanged: if (cashewGuessProc.running && root.cashewGuessInput !== "") {
      cashewGuessProc.write(root.cashewGuessInput)
      root.cashewGuessInput = ""
    }
    onExited: function (exitCode) {
      root.cashewGuessing = false
      if (exitCode !== 0 && !root.cashewGuessStopping) {
        var first = (cashewGuessErr.text || "").trim().split("\n").pop()
        root.cashewGuessError = "Guessing failed (" + exitCode + ")" + (first ? ": " + first : "")
        root.cashewGuessNotify("AI categories failed", root.cashewGuessError)
      }
      root.cashewGuessStopping = false
    }
  }
  Timer {
    id: cashewStateTimer
    interval: 400
    onTriggered: root.flushCashewSave()
  }
  // Writes the state now if it differs from what is on disk. Also called from
  // Component.onDestruction.
  function flushCashewSave() {
    cashewStateTimer.stop()
    if (!root.cashewStateLoaded) return
    var json = JSON.stringify(root.cashewState)
    if (json === root.cashewStateSavedJson) return
    root.cashewStateSavedJson = json
    cashewStateFile.setText(json + "\n")
  }
  FileView {
    id: cashewStateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-cashew.json"
    atomicWrites: true
    printErrors: false
    // The taught categories in this file decide the category shown on every
    // transaction row (txdb snapshot reads it), so a save reloads the snapshot.
    onSaved: root.refreshData()
  }
  Process {
    id: cashewDraftProc
    command: ["python3", root.txdbBin, "cashew-draft"]
    stdout: StdioCollector { onStreamFinished: root.cashewApplyDrafts(text) }
    stderr: StdioCollector { id: cashewDraftErr }
    onExited: function (exitCode) {
      if (exitCode === 0) return
      var first = (cashewDraftErr.text || "").trim().split("\n").pop()
      root.cashewError = "cashew-draft failed (" + exitCode + ")" + (first ? ": " + first : "")
      root.cashewLoading = false
    }
  }

  // Links are built in-process by Model.cashewBuildLinks (microseconds): a
  // picker choice or checkbox rebuilds at once, a typed cell edit after a
  // very short Timer so typing stays smooth.
  function cashewRebuildLinks() {
    cashewLinksTimer.stop()
    if (!root.cashewOpen) return
    try {
      var out = Model.cashewBuildLinks(root.cashewDrafts, root.cashewShown, 6000, root.cashewCategories, root.cashewBase, root.cashewTransferMode)
      root.cashewLinksError = ""
      root.cashewLinks = out.links
      root.cashewTransfers = out.transfers
      root.cashewWarnings = out.warnings
    } catch (e) {
      root.cashewLinksError = "Could not build the links: " + e
    }
  }
  function cashewQueueLinks() { if (root.cashewOpen) cashewLinksTimer.restart() }

  // One click adds every selected row to the Cashew web app (https://budget-track.web.app/), one step after
  // the other: the bulk links first, then one Cashew transfer page per transfer pair (a real transfer: the
  // person taps Save there). A step starts only when Cashew has added the rows of the one before. "Added" is
  // read from the copy of Cashew's database the browser keeps (txdb cashew-wait): its count of transactions
  // must rise by the rows of the step (2 for a transfer). Rows without the tick, and rows hidden by the
  // filter, are not sent. The run goes on when the window is closed or minimised; a notification tells how
  // it ended, the sent rows are marked as tracked (option), and Cashew opens in the browser for a look.
  property var cashewSendItems: []            // the plan: [{kind, url, count, ids, title}] (Model.cashewSendPlan)
  property int cashewSendDone: 0              // steps complete
  property int cashewSendAdded: 0             // rows of the current step Cashew has so far
  property bool cashewSendOpened: false       // the current step was handed to the browser
  property bool cashewSendConfirmed: true     // every step so far was confirmed by the count
  property bool cashewSendFresh: false        // "done" and the drafts did not change since
  property string cashewSendPhase: ""         // "" | open | wait | blind | timeout | done | stopped
  property string cashewSendTracked: ""       // at "done": yes | off | unconfirmed
  // Every step opens in a new browser window (bin/cashew-open) that is closed once Cashew has its rows: a
  // normal link in a hidden window (nothing shows, the focus stays), a transfer page in a visible one (the
  // person taps Save). No tab is left behind.
  property string cashewSendWin: ""           // the window of the current step ("" = none)
  property bool cashewSendWinHidden: false
  property bool cashewSendHiddenOk: true      // false after the hidden way failed once (another browser)
  readonly property var cashewSendItem: root.cashewSendDone < root.cashewSendItems.length ? root.cashewSendItems[root.cashewSendDone] : null
  readonly property bool cashewSending: root.cashewSendPhase === "open" || root.cashewSendPhase === "wait" || root.cashewSendPhase === "blind"
  readonly property bool cashewSendPaused: root.cashewSendPhase === "timeout"
  readonly property bool cashewAutoTrack: root.cashewState.autoTrack !== false
  property string cashewSendNote: ""
  // How long a step may take: a hidden link 60 s; the transfers step 3 minutes plus 1 more per extra
  // transfer (you tap Save in each tab), at most 15. Without a readable copy of Cashew: a fixed wait.
  function cashewSendSecs(it, blind) {
    var kind = it ? it.kind : "link", n = it && it.n ? it.n : 1
    if (kind === "link") return blind ? 8 : 60
    return blind ? Math.min(30 * n, 300) : Math.min(180 + 60 * (n - 1), 900)
  }
  // What is left to add, for the minimised card and the progress card.
  readonly property var cashewSendLeftNow: {
    var idleRows = 0
    root.cashewLinks.forEach(function (l) { idleRows += l.count })
    idleRows += 2 * root.cashewTransfers.length
    var counting = root.cashewSending || root.cashewSendPaused || (root.cashewSendPhase === "done" && root.cashewSendFresh)
    return Model.cashewSendLeft({
      phase: counting ? root.cashewSendPhase : "", items: root.cashewSendItems, done: root.cashewSendDone,
      added: root.cashewSendAdded, idleRows: idleRows, idleLinks: root.cashewLinks.length, idleTransfers: root.cashewTransfers.length })
  }
  // The send itself, always (the progress card): never mixed with the counts of the list as it is now.
  readonly property var cashewSendProgress: Model.cashewSendLeft({
    phase: root.cashewSendPhase, items: root.cashewSendItems, done: root.cashewSendDone, added: root.cashewSendAdded })
  onCashewDraftsChanged: root.cashewSendFresh = false
  function cashewSendSay() {
    var items = root.cashewSendItems, it = root.cashewSendItem
    var last = items.length ? items[Math.max(0, Math.min(root.cashewSendDone, items.length) - 1)] : null
    var shown = it || last
    var kind = shown ? shown.kind : "link"
    var index = 0, total = 0, links = 0, transfers = 0, rows = 0
    items.forEach(function (x, i) {
      if (x.kind === "transfers") transfers += x.n || 0
      else if (x.kind === "transfer") transfers++
      else links++
      rows += x.count
      if (x.kind !== kind) return
      total++
      if (i <= root.cashewSendDone) index++
    })
    root.cashewSendNote = Model.cashewSendText({
      phase: root.cashewSendPhase, kind: kind, index: index, total: total, title: it ? it.title : "",
      n: shown && shown.n ? shown.n : 0,
      added: root.cashewSendAdded, of: it ? it.count : 0, rows: rows, links: links, transfers: transfers,
      tracked: root.cashewSendTracked, wait: root.cashewSendSecs(shown, root.cashewSendPhase === "blind") })
  }
  // "Add all" starts with a check: no Cashew tab may be open in Zen (txdb cashew-tabs). Cashew web keeps its
  // whole database in each open tab and the last tab to save wins, so an open Cashew tab would overwrite the
  // rows the send adds when it next saves or closes.
  function cashewSendAll() {
    if (root.cashewSending || root.cashewSendPaused || cashewTabsProc.running || !root.cashewVerifyGate()) return
    if (root.cashewImportWaiting || cashewFixProc.running) {
      // The file replaces the whole database when imported: rows a link adds now would be erased by it.
      root.cashewSendNote = "Not started: a Cashew file is waiting for its import. Import it first (or make a new file later): importing it after a link would erase what the link added."
      return
    }
    root.cashewSendPhase = ""
    root.cashewSendNote = "Checking that no Cashew tab is open in Zen…"
    cashewTabsProc.running = true
  }
  Process {
    id: cashewTabsProc
    command: ["python3", root.txdbBin, "cashew-tabs"]
    stdout: StdioCollector { id: cashewTabsOut }
    onExited: function (exitCode) {
      var r
      try { r = JSON.parse(cashewTabsOut.text) } catch (e) { r = { open: -1, reason: "the check printed no result" } }
      if (r.open > 0) {
        var where = (r.tabs || []).slice(0, 3).map(function (t) { return "window " + t.window + " tab " + t.tab }).join(", ")
        root.cashewSendNote = "Not started: " + r.open + (r.open === 1 ? " Cashew tab is" : " Cashew tabs are") + " open in Zen ("
          + where + "). Close every Cashew tab, wait 15 s (Zen saves its tab list that often), then press Add all again."
        root.cashewGuessNotify("Cashew: close the Cashew tabs first", root.cashewSendNote)
        return
      }
      if (r.open < 0) {
        root.cashewSendNote = "Not started: " + (r.reason || "Zen's tab list could not be read") + "."
        return
      }
      root.cashewSendAllGo()
    }
  }
  function cashewSendAllGo() {
    var out
    try { out = Model.cashewBuildLinks(root.cashewDrafts, root.cashewShown, 6000, root.cashewCategories, "web", root.cashewTransferMode) }
    catch (e) { root.cashewSendNote = "Could not build the links: " + e; return }
    var items = Model.cashewSendPlan(out)
    if (items.length === 0) { root.cashewSendPhase = ""; root.cashewSendNote = "Nothing selected to send."; return }
    root.cashewSendItems = items
    root.cashewSendHiddenOk = true
    root.cashewSendDone = 0
    root.cashewSendConfirmed = true
    root.cashewSendTracked = ""
    root.cashewSendFresh = false
    root.cashewSendStart()
  }
  // Starts the wait for the current step; the step is opened when the wait has read the count to start from
  // ({"ready": true}), so no row can be added before the count is known.
  function cashewSendStart() {
    var it = root.cashewSendItem
    if (!it) { root.cashewSendFinish(); return }
    root.cashewSendAdded = 0
    root.cashewSendOpened = false
    root.cashewSendPhase = "open"
    root.cashewSendSay()
    cashewWaitProc.command = ["python3", root.txdbBin, "cashew-wait", String(it.count), "--timeout", String(root.cashewSendSecs(it, false))]
    cashewWaitProc.running = true
  }
  function cashewSendOpen() {
    var it = root.cashewSendItem
    if (root.cashewSendOpened || !it) return
    root.cashewSendOpened = true
    root.cashewSendWin = ""
    root.cashewSendWinHidden = it.kind === "link"
    if (root.cashewSendHiddenOk) {
      // a link: one hidden window; the transfers: ONE visible window with every transfer page as a tab
      cashewOpenHiddenProc.command = [root.widgetDir + "/bin/cashew-open", it.kind === "link" ? "--hidden" : "--show"]
        .concat(it.urls && it.urls.length ? it.urls : [it.url])
      cashewOpenHiddenProc.running = true
    } else {
      ;(it.urls && it.urls.length ? it.urls : [it.url]).forEach(function (u) { Quickshell.execDetached(["xdg-open", u]) })
    }
  }
  // The window of the step is closed when the step is complete (or stopped). `then` runs once the window is
  // gone plus 1 s (bin/cashew-open --close): a new Cashew must not load before the closing one has saved.
  property var cashewAfterClose: null
  function cashewSendCloseWin(then) {
    if (root.cashewSendWin === "") { if (then) then(); return }
    root.cashewAfterClose = then || null
    cashewCloseProc.command = [root.widgetDir + "/bin/cashew-open", "--close", root.cashewSendWin]
    root.cashewSendWin = ""
    cashewCloseProc.running = true
  }
  Process {
    id: cashewCloseProc
    onExited: function (exitCode) {
      var then = root.cashewAfterClose
      root.cashewAfterClose = null
      if (then) then()
    }
  }
  // After a timeout the person must look: the hidden workspace with the window is shown.
  function cashewSendShowWin() {
    if (root.cashewSendWin === "" || !root.cashewSendWinHidden) return
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.workspace.toggle_special("cashew")'])
  }
  Process {
    id: cashewOpenHiddenProc
    stdout: StdioCollector { id: cashewOpenHiddenOut }
    onExited: function (exitCode) {
      var it = root.cashewSendItem
      if (exitCode === 0) {
        root.cashewSendWin = (cashewOpenHiddenOut.text || "").trim()
        if (!root.cashewSending && !root.cashewSendPaused) root.cashewSendCloseWin()   // stopped meanwhile
      } else if (it && root.cashewSending) {
        // Not possible here (exit 4: another browser) or no window came (5): open it the normal way.
        if (exitCode === 6) {
          // Zen was closed meanwhile: a link would start it and Zen would restore its last window mid-send.
          root.cashewSendPhase = "stopped"
          root.cashewSendNote = "Stopped: Zen is not running. Start Zen, close its Cashew tabs, wait 15 s, then press Add all again (rows already added are not sent twice)."
          cashewWaitProc.running = false
          return
        }
        if (exitCode === 4) root.cashewSendHiddenOk = false
        if (exitCode !== 5) (it.urls && it.urls.length ? it.urls : [it.url]).forEach(function (u) { Quickshell.execDetached(["xdg-open", u]) })
      }
    }
  }
  function cashewSendLine(line) {
    if (!root.cashewSending) return
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (m.ready) { root.cashewSendOpen(); root.cashewSendPhase = "wait" }
    if (m.added !== undefined) root.cashewSendAdded = Math.max(0, Number(m.added) || 0)
    root.cashewSendSay()
  }
  function cashewSendExited(exitCode) {
    if (!root.cashewSending) return                       // stopped by hand
    if (exitCode === 0) {
      // Cashew has these rows now: mark them so a second "Add all" in this window does not send them again.
      var done = ({})
      ;(root.cashewSendItem ? root.cashewSendItem.ids || [] : []).forEach(function (id) { done[id] = true })
      root.cashewDrafts = root.cashewDrafts.map(function (d) {
        return done[d.id] ? Object.assign({}, d, { inCashew: true, include: false }) : d
      })
      root.cashewSendDone += 1
      root.cashewSendCloseWin(function () { if (root.cashewSending) root.cashewSendStart() })
    } else if (exitCode === 3) {
      // The browser keeps no copy of Cashew that can be read (another browser): open the step and wait a fixed time.
      root.cashewSendOpen()
      root.cashewSendConfirmed = false
      root.cashewSendPhase = "blind"
      root.cashewSendSay()
      cashewSendBlindTimer.interval = root.cashewSendSecs(root.cashewSendItem, true) * 1000
      cashewSendBlindTimer.restart()
    } else {
      // Timeout (2), or the check itself failed: stop here and let the person look.
      root.cashewSendOpen()
      root.cashewSendPhase = "timeout"
      root.cashewSendSay()
      root.cashewSendShowWin()
      root.cashewGuessNotify("Cashew: waiting for you", root.cashewSendNote)
    }
  }
  // After a timeout: the person looked at the browser and wants the remaining steps.
  function cashewSendContinue() {
    if (!root.cashewSendPaused) return
    root.cashewSendConfirmed = false
    root.cashewSendDone += 1
    root.cashewSendPhase = "open"
    root.cashewSendCloseWin(function () { root.cashewSendStart() })
  }
  function cashewSendStop() {
    if (!root.cashewSending && !root.cashewSendPaused) return
    root.cashewSendPhase = "stopped"
    root.cashewSendSay()
    cashewSendBlindTimer.stop()
    cashewWaitProc.running = false
    root.cashewSendCloseWin()
  }
  function cashewSendFinish() {
    root.cashewSendTracked = !root.cashewSendConfirmed ? "unconfirmed" : (root.cashewAutoTrack ? "yes" : "off")
    root.cashewSendPhase = "done"
    root.cashewSendFresh = true
    root.cashewSendSay()
    if (root.cashewSendTracked === "yes") {
      var rows = []
      root.cashewSendItems.forEach(function (it) { (it.ids || []).forEach(function (id) { rows.push({ id: id }) }) })
      store.setTrackedMany(rows, true)
      cashewSendReloadTimer.restart()                     // the sent rows leave the list once the write is done
    }
    root.cashewGuessNotify("Cashew: all added", root.cashewSendNote)
    Quickshell.execDetached(["xdg-open", "https://budget-track.web.app/"])     // for a look at the result
  }
  Process {
    id: cashewWaitProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.cashewSendLine(line) }
    }
    onExited: function (exitCode) { root.cashewSendExited(exitCode) }
  }
  Timer {
    id: cashewSendBlindTimer
    interval: 8000
    onTriggered: if (root.cashewSendPhase === "blind") {
      root.cashewSendDone += 1
      root.cashewSendCloseWin(function () { if (root.cashewSending) root.cashewSendStart() })
    }
  }
  Timer {
    id: cashewSendReloadTimer
    interval: 2000
    onTriggered: if (root.cashewOpen && !root.cashewGuessing) root.cashewLoad(); else root.cashewStale = true
  }
  Timer {
    id: cashewLinksTimer
    interval: 30
    onTriggered: root.cashewRebuildLinks()
  }

  readonly property var groupedTransactions: Model.groupByDate(Model.collapseTransfers(root.filteredTransactions, store.transfers))
  // Flat, one-row-per-entry version of groupedTransactions for txnList (the
  // virtualized ListView below) — see Model.flattenGroups.
  // Only the newest rowLimit rows get a delegate: every row costs ~100 QML
  // objects, and the list is not virtualised (the outer Flickable scrolls it),
  // so 490 rows meant ~50k objects. "Show older" raises the limit.
  property int rowLimit: 120
  readonly property var allFlatRows: Model.flattenGroups(root.groupedTransactions)
  // id -> row, for text that names the other side of a link ("Refund of FLIPKART ...").
  readonly property var transactionById: {
    var m = ({})
    store.transactions.forEach(function (t) { m[t.id] = t })
    return m
  }
  readonly property var flatTransactionRows: allFlatRows.length > rowLimit ? allFlatRows.slice(0, rowLimit) : allFlatRows
  // Pushes flatTransactionRows into txnListModel (the ListModel actually
  // backing txnList) incrementally — see Model.syncFlatRowsModel. Keeps
  // rows' delegate Items alive across a filter/tracked/etc. change
  // instead of the ListView seeing a brand-new array and resetting.
  onFlatTransactionRowsChanged: Model.syncFlatRowsModel(txnListModel, root.flatTransactionRows)

  // Biggest bill first, then by card, so rows do not reshuffle between
  // snapshots. (Object.values alone put ••7462 before ••0220: JavaScript
  // walks integer-like keys first, and "0220" is not one.)
  readonly property var cardOverviewList: Object.values(store.cardOverviews).sort(Model.billOrder)
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

  // One tone per card, the same in the bar, its key and the strips under it.
  // Four tones are enough for the cards in use; a fifth wraps round.
  function limitCardColor(last4) {
    var tones = [Color.accent, root.pendingColor, root.creditColor, Util.alpha(Color.accent, 0.55)]
    var i = 0
    for (var k = 0; k < root.cardOverviewList.length; k++) {
      if (root.cardOverviewList[k].last4 === last4) { i = k; break }
    }
    return tones[i % tones.length]
  }

  function limitColor(percent) {
    return percent >= 50 ? root.debitColor : (percent >= 30 ? root.pendingColor : root.creditColor)
  }

  // A transfer between your own accounts is neither spending (red) nor income
  // (green): it gets the accent colour wherever it is drawn.
  function toneColor(tone) { return tone === "amber" ? root.pendingColor : (tone === "dim" ? Util.alpha(Color.accent, 0.6) : Color.accent) }
  function isTransferLeg(t) { return !!(t.transferId || t.transferSelf) }
  function rowBg(t) { return root.isTransferLeg(t) ? Util.alpha(Color.accent, 0.18) : (t.amount < 0 ? root.debitBg : root.creditBg) }
  function directionColor(t) { return root.isTransferLeg(t) ? Color.accent : (t.amount < 0 ? root.debitColor : root.creditColor) }

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

  // The RECENT list (txnList, see the bank-tab Column below) is a
  // virtualized ListView: only rows actually on screen (plus a cache
  // buffer) exist as real items. Set once txnList is created.
  property var txnListRef: null

  // Same as focusNext, but for a row inside txnList: nextItemInFocusChain
  // only ever walks items that already exist, so at the edge of the
  // realized window it would silently jump straight past every
  // not-yet-created row underneath to whatever real item comes next
  // (the empty-state text, the portfolio section, ...). Nudging the
  // ListView to the neighbouring index first forces that row to exist,
  // so the walk lands on it instead of skipping it.
  function focusNextInList(item, forward) {
    var view = root.txnListRef
    if (view && item && item.rowIndex !== undefined && item.rowIndex >= 0) {
      var want = item.rowIndex + (forward ? 1 : -1)
      if (want >= 0 && want < view.count) view.positionViewAtIndex(want, ListView.Contain)
    }
    root.focusNext(item, forward)
  }

  // Scrolls the popup's Flickable just enough to bring `item` fully into
  // view — Up/Down moving focus doesn't move the scroll position on its
  // own, so without this the newly focused row could land off-screen.
  // When `item` is a row inside the virtualized txnList, its OWN inner
  // viewport (a nested Flickable) needs the same treatment first, since
  // a realized-but-off-screen (cache buffer) row is clipped there too.
  function scrollIntoView(item) {
    if (!item) return
    var view = root.txnListRef
    if (view) {
      var p = item
      var insideList = false
      for (var i = 0; i < 100 && p; i++) {
        if (p === view || p === view.contentItem) { insideList = true; break }
        p = p.parent
      }
      if (insideList) {
        var innerPos = item.mapToItem(view.contentItem, 0, 0)
        var innerMargin = Style.spacing.sm
        var innerTop = innerPos.y - innerMargin
        var innerBottom = innerPos.y + item.height + innerMargin
        if (innerTop < view.contentY) view.contentY = Math.max(0, innerTop)
        else if (innerBottom > view.contentY + view.height) {
          view.contentY = Math.min(Math.max(0, view.contentHeight - view.height), innerBottom - view.height)
        }
      }
    }
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

  onOpenedChanged: if (!opened) {
    filterOpen = false          // the filter layer never outlives the popup
    infoOpenId = ""
    root.rowLimit = 120
    // The "new" marks stay while the popup is open; closing it means they were seen.
    if (store.transfers.some(function (t) { return t.isNew })) root.txdb(["transfers-mark-seen"])
  } else {
    root.todayIso = Model.todayIso()
    // No refresh here: data/.changed (dbChangedFile) already reloads on every
    // write by any process, and the shell loads once at start. Re-running the
    // snapshot on each open rebuilt every row for nothing.
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

  // Commands whose caller already applies an optimistic patch (trackedOverrides,
  // receiptOverrides, billOverrides, accountNameOverrides, transactionNameOverrides
  // — see store.setTracked/setTrackedMany/setBillPaid/setAccountName/
  // setTransactionName and every store.*Receipt* function) before calling
  // root.txdb(). For these, the UI already shows the right result; the write's
  // own .changed touch (see dbChangedFile below) would just force a redundant
  // full snapshot reload a few hundred ms later, throwing the optimistic state
  // away and rebuilding everything (a visible double-rebuild). See selfWriteCredits.
  // transfer-split / transfer-restore / transfers-mark-seen are deliberately left
  // out: they have no optimistic patch and still need the real reload.
  readonly property var _optimisticWriteCmds: ({
    "set-tracked": true, "set-tracked-many": true,
    "bill-paid": true, "bill-notified": true,
    "account-name": true, "rename": true, "txn-note": true,
    // receipt-link / receipt-unlink / receipt-set-category are NOT here: they change a
    // transaction row's category (a linked bill's category wins), which only the
    // snapshot knows, so their own reload must run.
    "receipt-cash": true, "receipt-ignore": true,
    "receipt-remove": true, "receipt-review": true, "receipt-edit": true, "receipt-edit-item": true,
    "receipt-add-item": true, "receipt-delete-item": true, "receipt-edit-tax": true,
    "receipt-add-fee": true, "receipt-edit-fee": true, "receipt-delete-fee": true,
    "receipt-add-tax": true, "receipt-recalc": true, "receipt-use-computed": true,
  })
  // One credit per optimistic write we have queued but whose matching
  // dbChangedFile touch has not arrived yet. dbChangedFile.onFileChanged
  // consumes one credit (and skips its reload) instead of treating that
  // touch as a change from some OTHER process (bank fetchers, the receipt
  // reader) that really does need a full reload.
  property int selfWriteCredits: 0
  property bool _lastWriteOptimistic: false

  function refreshData() {
    if (snapshotProc.running || txdbWriteProc.running || txdbQueue.length > 0) {
      refreshPending = true
      return
    }
    snapshotProc.running = true
  }

  // Queues one write; writes run one at a time, in order.
  function txdb(args) {
    if (root._optimisticWriteCmds[args[0]] === true) root.selfWriteCredits++
    txdbQueue = txdbQueue.concat([args])
    runNextWrite()
  }

  function runNextWrite() {
    if (txdbWriteProc.running) return
    if (txdbQueue.length === 0) {
      if (refreshPending) { refreshPending = false; refreshData() }
      return
    }
    root._lastWriteOptimistic = root._optimisticWriteCmds[txdbQueue[0][0]] === true
    txdbWriteProc.command = ["python3", root.txdbBin].concat(txdbQueue[0])
    txdbQueue = txdbQueue.slice(1)
    txdbWriteProc.running = true
  }

  Process {
    id: txdbWriteProc
    stderr: StdioCollector { id: writeErr }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        console.warn("txdb write failed (" + exitCode + "): " + command.slice(2).join(" "))
        // No touch is coming for this one (txdb/db.py only touches .changed
        // after a successful commit) — give back the credit so a later,
        // real external change is not mistaken for this failed self-write.
        if (root._lastWriteOptimistic && root.selfWriteCredits > 0) root.selfWriteCredits--
        // The screen must equal the database: undo the optimistic change by
        // reloading the snapshot, and say that the save failed.
        var failed = command.slice(2)
        Quickshell.execDetached([
          Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
          "--app-name", "home.transactions", "Could not save: " + failed[0],
          (writeErr.text || "").trim().split("\n").pop() || ("exit " + exitCode)
        ])
        root.refreshData()
      } else if (command.slice(2)[0] === "txn-category") {
        // A category chosen in the main list is in the state file now. The Cashew window
        // keeps its own copy of that file and of the drafts built from it: drop the copy
        // (so nothing can write the old one back) and rebuild, or the choice is ignored there.
        root.cashewStale = true
        root.cashewStateLoaded = false
        if (root.cashewOpen && !root.cashewGuessing) root.cashewLoad()
        // The row's category circle comes from the snapshot, which txn-category
        // never touches .changed for: reload it or the circle stays stale.
        root.refreshData()
      }
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
    // Skip the reload this touch would trigger when we already know it is
    // the one our own optimistic write just caused (see selfWriteCredits
    // above) — the UI already shows the result. A touch with no credit
    // outstanding is from some other process and still reloads as before.
    onFileChanged: {
      if (root.selfWriteCredits > 0) { root.selfWriteCredits--; return }
      root.refreshData()
    }
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
    onTriggered: { root.queueCompress(); root.runAutoLink() }
  }

  // First catch-up runs a minute after start, not during it, so the OCR-sized
  // Python imports do not compete with the shell and the first popup open.
  Timer {
    interval: 60 * 1000
    running: true
    onTriggered: { root.queueCompress(); root.runAutoLink() }
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
    // compress-linked prints one line per photo it changed. No line, nothing
    // written, so no reason to reload the whole snapshot.
    property int changed: 0
    onRunningChanged: if (running) changed = 0
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { if (line.length > 0) { receiptCompressProc.changed++; console.log("receipt photo: " + line) } }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) console.warn("Receipt photo compress exited " + exitCode)
      if (receiptCompressProc.changed > 0) root.refreshData()
    }
  }

  Component.onCompleted: {
    root.syncAccountChipOptions()
    refreshData()
    // Seeds txnListModel for whatever flatTransactionRows already is at
    // startup (onFlatTransactionRowsChanged only fires on later changes).
    Model.syncFlatRowsModel(txnListModel, root.flatTransactionRows)
  }
  Component.onDestruction: { root.flushFilterSave(); root.flushCashewSave() }

  QtObject {
    id: store
    property var trackedOverrides: ({})   // optimistic tracked changes not yet in a snapshot
    property var rawTransactions: []
    property var transfers: []         // detected transfer pairs (txdb/transfers.py)
    property var lastFetched: ({})     // bank -> ISO time of its last successful fetch
    property var transactions: []
    property var cardOverviews: ({})   // map: last4 -> overview entry
    property var accountBalances: []   // list of {bank, accountType, last4, balance, currency}
    property var billOverrides: ({})   // map: last4 -> { markedPaid, notifiedDate }
    property var accountNameOverrides: ({})   // map: last4 -> user-set display name
    property var txnNotes: ({})                  // map: transaction id -> the user's own note
    property var recurring: []                   // Cashew's recurring series with their state (snapshot)
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
    property var receiptCategories: []
    property var receiptOverrides: ({})   // optimistic: id -> {state, transactionId, ...}
    property var receipts: []

    // Loads one `txdb snapshot`. A snapshot that doesn't parse is ignored,
    // so the widget keeps showing the last good data. Everything is set
    // together before bill reminders run, so "marked paid" is never lost
    // to load order.
    property string lastSnapshotText: ""
    function applySnapshot(text) {
      // An identical snapshot (a touch with no real change) would only
      // re-assign every array and re-run every row binding.
      if (text === store.lastSnapshotText) return
      var snap
      try { snap = JSON.parse(text) } catch (e) { console.warn("txdb snapshot unreadable: " + e); return }
      if (root.txdbQueue.length > 0 || txdbWriteProc.running) { root.refreshPending = true; return }
      store.lastSnapshotText = text
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
      txnNotes = snap.txnNotes || {}
      recurring = snap.recurring || []
      portfolio = snap.portfolio || ({})
      holdings = snap.holdings || []
      allocation = snap.allocation || []
      portfolioActivity = snap.portfolioActivity || []
      portfolioHistory = snap.portfolioHistory || []
      trackedOverrides = {}
      rawTransactions = snap.transactions || []
      transfers = snap.transfers || []
      lastFetched = snap.lastFetched || ({})
      rawReceipts = snap.receipts || []
      receiptCategories = snap.receiptCategories || []
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

    // ---- refunds (txdb/refunds.py). Not optimistic: a link changes the month totals and the Cashew
    // category, which only the snapshot knows, so each command is followed by a reload.
    function linkRefund(refundId, originalId, note) { root.txdb(["refund-link", refundId, originalId || "-", note || ""]) }
    function unlinkRefund(refundId) { root.txdb(["refund-unlink", refundId]) }
    function markNotRefund(refundId) { root.txdb(["refund-not", refundId]) }
    function allowRefund(refundId) { root.txdb(["refund-restore", refundId]); root.txdb(["refund-verify"]) }
    function setRefundMode(refundId, mode) { root.txdb(["refund-mode", refundId, mode]) }
    function expectRefund(originalId) { root.txdb(["refund-expect", originalId]) }
    function unexpectRefund(originalId) { root.txdb(["refund-unexpect", originalId]) }

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
      discount: "discount", round_off: "roundOff", printed_total: "printedTotal", tax: "tax",
      platform: "platform", order_id: "orderId", payment_method: "paymentMethod",
    })
    readonly property var _receiptMoneyFields: ({ total: true, subtotal: true, discount: true, roundOff: true,
                                                  printedTotal: true, tax: true })
    function editReceiptField(id, field, value) {
      var jsKey = _receiptFieldToJs[field]
      var before = receipts.find(function (r) { return r.id === id })
      var mode = before ? Model.receiptTaxMode(before) : "inside"
      var patch = {}
      var trimmed = String(value || "").trim()
      patch[jsKey] = trimmed === "" ? null : (_receiptMoneyFields[jsKey] ? Number(trimmed) : trimmed)
      // The amount paid and the stored total are one figure (receipts.edit_field).
      if (field === "printed_total" || (field === "total" && before && before.printedTotal != null)) {
        patch.printedTotal = patch[jsKey]; patch.total = patch[jsKey]
      }
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
      if (!cur || cur.printedTotal != null) return   // the printed total is what the bill says, never followed
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
    function addReceiptFee(id, label, amount, original, waived) {
      var current = receipts.find(function (r) { return r.id === id })
      var isFree = waived === true
      var amt = isFree ? 0 : Math.abs(Number(amount))
      var orig = String(original || "").trim() === "" ? null : Math.abs(Number(original))
      if (orig !== null && isNaN(orig)) return false
      if (!current || (!isFree && !(amt > 0))) return false
      var mode = Model.receiptTaxMode(current)
      var fees = (current.fees || []).slice()
      var line = fees.reduce(function (m, f) { return Math.max(m, f.line) }, 0) + 1
      var name = String(label || "").trim() || "Fee"
      fees.push({ line: line, label: name, amount: amt, original: orig, waived: isFree })
      _patchReceipt(id, { fees: fees })
      root.txdb(["receipt-add-fee", id, name, String(amt), orig === null ? "" : String(orig), isFree ? "1" : "0"])
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
      var sent = trimmed
      if (field === "amount") {
        var n = Math.abs(Number(trimmed))
        if (!(n > 0)) return
        f.amount = n; f.waived = false
        sent = String(n)
      } else if (field === "original") {
        var o = Math.abs(Number(trimmed))
        f.original = trimmed === "" || isNaN(o) ? null : o
        sent = f.original === null ? "" : String(f.original)
      } else if (field === "waived") {
        f.waived = trimmed === "1"
        if (f.waived) f.amount = 0
        else if (!f.amount && f.original) f.amount = f.original
      } else {
        f.label = trimmed || "Fee"
        sent = f.label
      }
      _patchReceipt(id, { fees: fees })
      root.txdb(["receipt-edit-fee", id, String(line), field, sent])
      if (field === "amount" || field === "waived") _followTotal(id, mode)
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
      // a bill with a printed total keeps it (and the total equal to it)
      _patchReceipt(id, current.printedTotal != null ? { subtotal: rc.subtotal } : { subtotal: rc.subtotal, total: rc.total })
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
      var after = Object.assign({}, current, { items: items, subtotal: rc.subtotal })
      if (current.printedTotal != null) {
        // Non-destructive for the printed total: the parts are recomputed and
        // the check shown; the warnings go only when the parts agree with it.
        var ok = Model.receiptParts(after).ok
        _patchReceipt(id, ok ? { items: items, subtotal: rc.subtotal, warnings: [], needsReview: false }
                             : { items: items, subtotal: rc.subtotal })
      } else {
        _patchReceipt(id, { items: items, subtotal: rc.subtotal, total: rc.total, warnings: [], needsReview: false })
      }
      root.txdb(["receipt-recalc", id, "verify"])
    }

    // The explicit override: the printed total becomes what the parts add up to.
    function useComputedTotal(id) {
      var current = receipts.find(function (r) { return r.id === id })
      if (!current) return
      var p = Model.receiptParts(current)
      _patchReceipt(id, { printedTotal: p.computed, total: p.computed })
      root.txdb(["receipt-use-computed", id])
    }

    // The user's own category for a bill; an empty category removes the choice.
    function setReceiptCategory(id, category, sub) {
      _patchReceipt(id, { category: category ? { category: category, subcategory: sub || "", source: "user" } : null })
      root.txdb(["receipt-set-category", id, category || "", sub || ""])
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

    function setTxnNote(txnId, text) {
      var next = Object.assign({}, txnNotes)
      var trimmed = String(text || "").trim()
      if (trimmed) next[txnId] = trimmed
      else delete next[txnId]
      txnNotes = next
      root.txdb(["txn-note", txnId, trimmed])
    }

    // Teach a category: for every transaction of this payee, or for this one only.
    // An empty category clears the answer. The snapshot reload shows it.
    function setTxnCategory(txnId, category, sub, onlyThis) {
      root.txdb(["txn-category", txnId, category || "", sub || ""].concat(onlyThis ? ["--only-this"] : []))
    }

    // A bill made from typed text, filed against the transaction.
    function noteBill(txnId, text) {
      root.txdb(["note-bill", txnId, String(text || "").replace(/\n/g, "\\n")])
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
    // A bank row may arrive after the bill that paid for it: file every bill
    // that now has exactly one matching transaction (written to the database).
    root.runAutoLink()
  }

  // receipt-ledger-stitcher's strict rule (same date, same amount to the
  // paisa, one candidate). Writes through txdb, which touches data/.changed,
  // so the snapshot reloads by itself. Also runs at start and every 30 min.
  function runAutoLink() {
    if (!autoLinkProc.running) autoLinkProc.running = true
  }
  Process {
    id: autoLinkProc
    command: ["bash", "-c", "cd '" + root.receiptStitcherDir + "' && .venv/bin/python -m src.main auto-link 2>&1"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { if (line.indexOf("LINK ") !== -1) console.log("auto-link: " + line) }
    }
    onExited: function (exitCode) { if (exitCode !== 0) console.warn("auto-link exited " + exitCode) }
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

  // Unverified AI categories: the first Copy/Open of a link while any AI
  // guess is still unaccepted only arms this; a second click within 8 s
  // goes through. Inline, no popup.
  property bool cashewVerifyArmed: false
  Timer { id: cashewVerifyTimer; interval: 8000; onTriggered: root.cashewVerifyArmed = false }
  // True when the click may go ahead.
  function cashewVerifyGate() {
    if (root.cashewGuessedCount === 0 || root.cashewVerifyArmed) { root.cashewVerifyArmed = false; return true }
    root.cashewVerifyArmed = true
    cashewVerifyTimer.restart()
    return false
  }

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
        // An open filter panel collapses first; a second Esc closes.
        Keys.onEscapePressed: function (event) {
          if (root.filterOpen) {
            root.filterOpen = false
            event.accepted = true
          } else {
            root.close()
          }
        }

        // Focus lands here when the popup opens (panel.focusTarget: column)
        // and whenever it's released back here (search close, Escape from a
        // row). Without these, the very first Down/Up press did nothing.
        Keys.onDownPressed: root.focusNext(column, true)
        Keys.onUpPressed: root.focusNext(column, false)

        // "/" or Ctrl+F: focus the search box (BANK: the filter bar,
        // PORTFOLIO: the holdings search). Alt+1..6 toggle the first six
        // account chips; Ctrl+Backspace clears every filter. Only reaches
        // here when no focused child already claimed the key: a focused
        // TextField (search, amount, rename) consumes printable keys itself.
        Keys.onPressed: function (event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var alt = (event.modifiers & Qt.AltModifier) !== 0
          if (event.text === "/" || (ctrl && event.key === Qt.Key_F)) {
            if (root.tab === "bank") filterBar.focusSearch()
            else Qt.callLater(function () { portfolioSearch.forceActiveFocus() })
            event.accepted = true
          } else if (alt && root.tab === "bank" && event.key >= Qt.Key_1 && event.key <= Qt.Key_6) {
            var opt = root.accountChipOptions[event.key - Qt.Key_1]
            if (opt) root.toggleAccountFilter(opt.key)
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_Backspace) {
            root.clearAllFilters()
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
                ? "to pay " + Model.currencySymbol("INR") + Model.formatGrouped(Math.round(root.billsDueTotal))
                : "nothing to pay"
              color: root.billsDueTotal > 0 ? root.debitColor : root.creditColor
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: Math.round(root.billsNextTotal) > 0
              textFormat: Text.PlainText
              text: "·  building " + Model.currencySymbol("INR") + Model.formatGrouped(Math.round(root.billsNextTotal))
              color: Qt.darker(root.foreground, 1.4)
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
            + Style.space(4) + (limitTotalKey.visible ? limitTotalKey.implicitHeight + Style.space(5) : 0)
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
                + " / " + Model.currencySymbol("INR") + Model.formatGrouped(limitHeader.total.limit)
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
            anchors.topMargin: Style.space(4)
            height: Style.space(4)
            clip: true

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.darker(root.foreground, 3.0)
            }

            Row {
              anchors.left: parent.left
              height: parent.height
              spacing: Style.space(1)          // a hairline between cards, so each reads as its own piece

              Repeater {
                model: limitHeader.total.cards || []
                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  height: limitTotalTrack.height
                  width: limitHeader.total.limit > 0
                    ? Math.max(modelData.amount > 0 ? 1 : 0, limitTotalTrack.width * modelData.fraction)
                    : 0
                  radius: height / 2
                  color: root.limitCardColor(modelData.last4)
                  Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // Every card, in its own tone: "HDFC ••7462 8%". A card with no
          // limit read yet says so, and is not drawn in the bar.
          Flow {
            id: limitTotalKey
            visible: limitHeader.total.limit > 0
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.top: limitTotalTrack.bottom
            anchors.topMargin: Style.space(6)
            spacing: Style.space(8)             // one row for four cards: same-bank cards share a name

            Repeater {
              model: limitHeader.total.cards || []
              delegate: Row {
                required property var modelData
                required property int index
                // The last four digits only where two cards share a bank, and the bank's name
                // only on the first of them: "HDFC 0220 8%  7462 8%".
                readonly property bool firstOfBank: (limitHeader.total.cards || []).findIndex(function (c) { return c.bank === modelData.bank }) === index
                readonly property bool sameBank: (limitHeader.total.cards || []).filter(function (c) { return c.bank === modelData.bank }).length > 1
                spacing: Style.space(4)
                Rectangle {
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.limitCardColor(modelData.last4)
                }
                Text {
                  textFormat: Text.PlainText
                  text: [parent.firstOfBank ? modelData.bank : "", parent.sameBank ? modelData.last4 : "",
                         Math.round(modelData.percent) + "%"].filter(function (s) { return s !== "" }).join(" ")
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
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
                      color: root.limitCardColor(modelData.last4)
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
                      color: root.limitCardColor(modelData.last4)
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

        // RECENT: the title line, then the chip line (the Recurring and Receipts tabs and the Cashew control),
        // then the drawer of the open tab (one at a time), then the transactions.
        Item {
          visible: root.tab === "bank"
          width: parent.width
          height: Math.max(recentHeader.implicitHeight, Style.space(26))
          PanelSectionHeader {
            id: recentHeader
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: root.untrackedCount > 0 ? ("RECENT  ·  " + root.untrackedCount + " TO TRACK") : "RECENT"
            foreground: root.foreground
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            PanelActionButton {
              id: selectToggleBtn
              size: Style.space(24)
              iconText: "󰄹"
              tooltipText: root.selectionMode ? "Done selecting" : "Select transactions"
              foreground: root.selectionMode ? Color.accent : root.foreground
              hoverColor: Color.accent
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

        // The chip line: [Recurring n •] [Receipts n]   ...   [sync │ Cashew]
        Item {
          id: chipLine
          visible: root.tab === "bank"
          width: parent.width
          height: Style.space(28)
          Row {
            id: drawerChips
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Repeater {
              model: [
                { tab: "recurring", chip: root.recurringChip },
                { tab: "receipts", chip: root.receiptsChip }
              ]
              delegate: BorderSurface {
                id: tabChip2
                required property var modelData
                readonly property bool open: root.drawerTab === tabChip2.modelData.tab
                readonly property bool _hot: tabChipMouse.containsMouse || tabChip2.activeFocus
                height: Style.space(24)
                width: tabChipRow.implicitWidth + Style.space(16)
                radius: Style.space(8)
                opacity: tabChipMouse.pressed ? 0.7 : (tabChip2.modelData.chip.dim && !tabChip2.open ? 0.55 : 1)
                color: tabChip2.open ? Util.alpha(Color.accent, 0.26) : Util.alpha(root.foreground, tabChip2._hot ? 0.12 : 0.06)
                borderSpec: tabChip2.activeFocus || tabChip2.open ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()
                activeFocusOnTab: tabChip2.visible
                function press() { root.drawerTab = Model.drawerToggle(root.drawerTab, tabChip2.modelData.tab) }
                Keys.onReturnPressed: tabChip2.press()
                Keys.onEnterPressed: tabChip2.press()
                Keys.onSpacePressed: tabChip2.press()
                Keys.onDownPressed: root.focusNext(tabChip2, true)
                Keys.onUpPressed: root.focusNext(tabChip2, false)
                Row {
                  id: tabChipRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: tabChip2.modelData.chip.label
                    color: tabChip2.open ? root.foreground : Qt.darker(root.foreground, 1.15)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    visible: tabChip2.modelData.chip.count > 0
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: String(tabChip2.modelData.chip.count)
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Rectangle {
                    visible: !!tabChip2.modelData.chip.late
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: root.pendingColor
                  }
                }
                MouseArea {
                  id: tabChipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: tabChip2.press()
                }
                ToolTip.visible: tabChipMouse.containsMouse
                ToolTip.text: tabChip2.modelData.chip.tooltip
                ToolTip.delay: 400
              }
            }
          }

          // The Cashew control: the sync state (left part) and "Cashew" (right part) in one chip.
          BorderSurface {
            id: cashewCtl
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(24)
            width: cashewCtlRow.implicitWidth
            radius: Style.space(8)
            readonly property var st: root.cashewControl
            readonly property color toneColor: st.tone === "error" ? root.debitColor
              : st.tone === "pending" ? root.pendingColor : (st.tone === "ok" ? root.creditColor : root.foreground)
            color: Util.alpha(st.tone === "pending" ? root.pendingColor : Color.accent, st.tone === "pending" ? 0.16 : 0.12)
            borderSpec: cashewSyncSeg.activeFocus || cashewOpenSeg.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()
            Row {
              id: cashewCtlRow
              height: parent.height
              Item {
                id: cashewSyncSeg
                width: cashewSyncRow.implicitWidth + Style.space(14)
                height: parent.height
                activeFocusOnTab: cashewCtl.visible
                Keys.onReturnPressed: root.cashewSyncClick()
                Keys.onEnterPressed: root.cashewSyncClick()
                Keys.onSpacePressed: root.cashewSyncClick()
                Keys.onDownPressed: root.focusNext(cashewSyncSeg, true)
                Keys.onUpPressed: root.focusNext(cashewSyncSeg, false)
                Rectangle { anchors.fill: parent; radius: Style.space(8); color: Util.alpha(root.foreground, cashewSyncMouse.containsMouse ? 0.10 : 0) }
                Row {
                  id: cashewSyncRow
                  anchors.centerIn: parent
                  spacing: Style.space(4)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(14)
                    height: Style.space(14)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    textFormat: Text.PlainText
                    text: cashewCtl.st.glyph
                    color: cashewCtl.toneColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    RotationAnimation on rotation { running: cashewCtl.st.spin; from: 0; to: 360; duration: 900; loops: Animation.Infinite; alwaysRunToEnd: true }
                  }
                  Text {
                    visible: cashewCtl.st.badge !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: cashewCtl.st.badge
                    color: cashewCtl.toneColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
                MouseArea {
                  id: cashewSyncMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: cashewCtl.st.tone === "ok" ? Qt.ArrowCursor : Qt.PointingHandCursor   // the tick is not a button
                  onClicked: root.cashewSyncClick()
                }
                ToolTip.visible: cashewSyncMouse.containsMouse
                ToolTip.text: cashewCtl.st.tooltip
                ToolTip.delay: 300
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: Style.space(14)
                color: Util.alpha(root.foreground, 0.18)
              }
              Item {
                id: cashewOpenSeg
                width: cashewBtnText.implicitWidth + Style.space(18)
                height: parent.height
                activeFocusOnTab: cashewCtl.visible
                Keys.onReturnPressed: root.cashewOpen = true
                Keys.onEnterPressed: root.cashewOpen = true
                Keys.onSpacePressed: root.cashewOpen = true
                Keys.onDownPressed: root.focusNext(cashewOpenSeg, true)
                Keys.onUpPressed: root.focusNext(cashewOpenSeg, false)
                Rectangle { anchors.fill: parent; radius: Style.space(8); color: Util.alpha(root.foreground, cashewBtnMouse.containsMouse ? 0.10 : 0) }
                Text {
                  id: cashewBtnText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "Cashew"
                  color: Qt.tint(Color.accent, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75))
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  id: cashewBtnMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cashewOpen = true
                }
                ToolTip.visible: cashewBtnMouse.containsMouse
                ToolTip.text: Model.cashewOpenTooltip(root.cashewCount)
                ToolTip.delay: 400
              }
            }
          }
        }

        // The drawer: the open tab's tools, its empty text and its rows.
        Column {
          id: drawer
          visible: root.tab === "bank" && root.drawerTab !== ""
          width: parent.width
          spacing: Style.spacing.xxs
          Item {
            id: drawerTools
            width: parent.width
            height: Style.space(26)
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.right: drawerToolRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.drawerTab === "recurring" ? root.recurringSummary.text
                : (root.receiptsToLink + " TO LINK" + (root.receiptsFiledCount > 0 ? "  ·  " + root.receiptsFiledCount + " LINKED" : ""))
              color: Qt.darker(root.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.6
            }
            Row {
              id: drawerToolRow
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Row {
                visible: root.drawerTab === "receipts"
                spacing: Style.space(4)
                PanelActionButton {
                  id: filedToggleBtn
                  size: Style.space(24)
                  visible: root.receiptsFiledCount > 0
                  iconText: "󰎞"
                  tooltipText: root.showFiled ? "Hide the linked bills" : "Show the linked bills (" + root.receiptsFiledCount + ")"
                  foreground: root.showFiled ? Color.accent : root.foreground
                  hoverColor: Color.accent
                  focusable: true
                  Keys.onDownPressed: root.focusNext(filedToggleBtn, true)
                  Keys.onUpPressed: root.focusNext(filedToggleBtn, false)
                  onClicked: root.showFiled = !root.showFiled
                }

                PanelActionButton {
                  id: importReceiptsBtn
                  size: Style.space(24)
                  iconText: receiptImportProc.running ? "…" : "+"
                  tooltipText: "Import new photos from " + root.receiptsDir
                  foreground: root.foreground
                  hoverColor: Color.accent
                  focusable: true
                  enabled: !receiptImportProc.running
                  Keys.onDownPressed: root.focusNext(importReceiptsBtn, true)
                  Keys.onUpPressed: root.focusNext(importReceiptsBtn, false)
                  onClicked: { receiptImportOutput.text = ""; receiptImportProc.running = true }
                }
              }
              Text {
                id: recEndedLink
                visible: root.drawerTab === "recurring" && root.recurringSummary.ended > 0
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.recurringShowEnded ? "Hide ended" : "Ended (" + root.recurringSummary.ended + ")"
                color: recEndedMouse.containsMouse || recEndedLink.activeFocus ? Color.accent : Qt.darker(root.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                activeFocusOnTab: visible
                Keys.onReturnPressed: root.recurringShowEnded = !root.recurringShowEnded
                Keys.onSpacePressed: root.recurringShowEnded = !root.recurringShowEnded
                Keys.onDownPressed: root.focusNext(recEndedLink, true)
                Keys.onUpPressed: root.focusNext(recEndedLink, false)
                MouseArea {
                  id: recEndedMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.recurringShowEnded = !root.recurringShowEnded
                }
              }
            }
          }
          StreamBox {
            visible: (root.drawerTab === "receipts" || receiptImportProc.running) && (receiptImportProc.running || receiptImportOutput.text.length > 0)
            width: parent.width - 2 * Style.spacing.rowPaddingX
            x: Style.spacing.rowPaddingX
            boxHeight: Style.space(150)
            text: receiptImportOutput.text
            closable: !receiptImportProc.running
            onClosed: receiptImportOutput.text = ""
          }
          Text {
            readonly property string msg: Model.drawerEmptyText(root.drawerTab, {
              toLink: root.receiptsToLink, filed: root.receiptsFiledCount, showFiled: root.showFiled,
              series: store.recurring.length, active: root.recurringChip.count, showEnded: root.recurringShowEnded })
            visible: msg !== ""
            x: Style.spacing.rowPaddingX
            width: parent.width - 2 * Style.spacing.rowPaddingX
            height: Style.space(32)
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: msg
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          // RECURRING rows: the recurring transactions set in Cashew (read only, txdb/cashew_recurring.py)
          Column {
            id: recurringList
            visible: root.drawerTab === "recurring"
            width: parent.width
            spacing: Style.spacing.xxs
            Repeater {
              model: Model.recurringOrder(store.recurring, root.recurringShowEnded)
              delegate: RecurringRow {
                width: recurringList.width
              }
            }
          }
          // RECEIPTS rows: photographed bills, stitched to the transaction that paid for them
          Column {
            id: receiptsList
            visible: root.drawerTab === "receipts"
            width: parent.width
            spacing: Style.spacing.xxs
            Repeater {
              model: root.visibleReceipts
              delegate: ReceiptRow {
                id: receiptRowDelegate
                required property var modelData
                width: parent.width
                receipt: receiptRowDelegate.modelData
              }
            }
          }
        }
        PanelSeparator { visible: drawer.visible; foreground: root.foreground }

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

        FilterBar {
          id: filterBar
          visible: root.tab === "bank"
          width: parent.width
        }

        // PORTFOLIO keeps a plain holdings search; PortfolioSection reads
        // root.searchQuery (its own text, not the RECENT filter's).
        TextField {
          id: portfolioSearch
          visible: root.tab === "portfolio"
          width: parent.width
          placeholderText: "Search holdings…  (/)"
          onTextChanged: root.searchQuery = text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Keys.onEscapePressed: function (event) {
            if (portfolioSearch.text !== "") {
              portfolioSearch.text = ""
              event.accepted = true
            } else {
              event.accepted = false
            }
          }
        }

        Column {
          visible: root.tab === "bank"
          width: parent.width
          spacing: Style.spacing.lg

          // The transaction list used to be a plain Repeater of date groups,
          // each with its own nested Repeater of rows — no virtualization,
          // so ANY state change (tracking a row, clearing a filter, ...)
          // destroyed and rebuilt every single delegate, even the ones
          // scrolled far off screen. A later attempt fixed that by giving
          // this ListView a capped, internally-scrolling height nested
          // inside the popup's own outer Flickable (`flick`) — that broke
          // scrolling ("can't see all the transactions") and was reverted:
          // height tracks contentHeight again below, so `flick` is the
          // only scroll surface, same as the original Repeater layout.
          //
          // The actual rebuild cost was never "off-screen rows have
          // delegates" (height == contentHeight means every row is
          // "on screen" from the ListView's own point of view anyway) —
          // it was "every row's delegate gets destroyed and recreated on
          // every small change", because root.flatTransactionRows is a
          // brand-new array each time, and reassigning `model:` to a new
          // array is a full ListView reset. Fixed at the model layer
          // instead, with zero change to scrolling: txnListModel is a
          // QML ListModel populated once, then updated incrementally by
          // Model.syncFlatRowsModel (see root.flatTransactionRows'
          // onFlatTransactionRowsChanged above and root's
          // Component.onCompleted) — only rows that actually changed get
          // `.set()`/`.insert()`/`.remove()`, so an unrelated row's
          // delegate Item is never torn down. The date-header + day-total
          // look is drawn by the delegate itself, keyed off each row's
          // own sectionFirst/sectionLabel/sectionTotal fields, rather
          // than by a separate Repeater per day.
          ListView {
            id: txnList
            width: parent.width
            height: contentHeight
            clip: false
            interactive: false
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: Style.space(2000)
            model: ListModel { id: txnListModel }
            Component.onCompleted: root.txnListRef = txnList
            Component.onDestruction: if (root.txnListRef === txnList) root.txnListRef = null

            delegate: Column {
              id: rowWrap
              required property var modelData
              required property int index
              width: txnList.width
              spacing: 0

              // The gap before this row: none for the very first row in
              // the whole list, Style.spacing.lg before a new day's
              // header, Style.spacing.xxs between rows of the same day —
              // exactly the gaps the old outer-Column (lg) / inner-Column
              // (xxs) nesting produced.
              Item {
                width: 1
                height: rowWrap.index === 0 ? 0
                  : (rowWrap.modelData.sectionFirst ? Style.spacing.lg : Style.spacing.xxs)
              }

              // Date-group header: label on the left, that day's net
              // total on the right (e.g. "Friday, October 2" / "-₹47.36").
              // Only the first row of each day draws one.
              Item {
                id: dateHeader
                visible: rowWrap.modelData.sectionFirst
                width: parent.width
                height: visible ? dateLabel.implicitHeight : 0

                Text {
                  id: dateLabel
                  anchors.left: parent.left
                  textFormat: Text.PlainText
                  text: rowWrap.modelData.sectionLabel
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  visible: rowWrap.modelData.sectionTotal !== 0
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: Model.formatAmount({ amount: rowWrap.modelData.sectionTotal, currency: rowWrap.modelData.sectionCurrency })
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                width: 1
                height: rowWrap.modelData.sectionFirst ? Style.spacing.sm : 0
              }

              // A transfer between your own accounts is one TransferCard;
              // everything else is an ordinary TransactionCard.
              Item {
                id: rowSlot
                width: parent.width
                height: slotLoader.height

                Loader {
                  id: slotLoader
                  width: parent.width
                  sourceComponent: rowWrap.modelData.isTransfer ? transferCardC : txnCardC
                  opacity: rowWrap.modelData.accountClosed === true ? 0.55 : 1
                }
                Text {
                  visible: rowWrap.modelData.accountClosed === true
                  z: 2
                  anchors { right: parent.right; bottom: parent.bottom; rightMargin: Style.space(10); bottomMargin: Style.space(4) }
                  textFormat: Text.PlainText
                  text: "closed card"
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Component { id: txnCardC; TransactionCard { txn: rowWrap.modelData; selectable: true; rowIndex: rowWrap.index } }
                Component { id: transferCardC; TransferCard { transfer: rowWrap.modelData; rowIndex: rowWrap.index } }
              }
            }
          }

          Item {
            visible: root.allFlatRows.length > root.rowLimit
            width: parent.width
            height: showOlder.height + Style.space(8)
            TextAction {
              id: showOlder
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              label: "Show older (" + (root.allFlatRows.length - root.rowLimit) + " more)"
              onTriggered: root.rowLimit += 150
            }
          }

          Column {
            visible: root.filteredTransactions.length === 0
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.filterChips.length === 0 ? "Nothing pending."
                : "No matches for: " + root.filterChips.map(function (c) { return c.label }).join(", ")
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Item {
              visible: root.filterChips.length > 0
              width: parent.width
              height: emptyClear.height
              TextAction {
                id: emptyClear
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Clear all"
                onTriggered: root.clearAllFilters()
              }
            }
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

    ScrollWheelArea {
      anchors.fill: flick
      target: flick
      // The amount fields and the month stepper take the wheel first.
      interceptWheel: function (source, event) { return filterBar.handleWheel(source, event) }
    }

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
    // Minimised: a small card in the corner with the bill's name, total and state; the keyboard and the rest
    // of the screen go back to the other windows.
    WlrLayershell.keyboardFocus: receiptFullScreen.compact ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    property bool compact: false
    property Region miniMask: Region { item: fsMini }
    mask: receiptFullScreen.compact ? receiptFullScreen.miniMask : null
    onCompactChanged: if (receiptFullScreen.visible) (receiptFullScreen.compact ? fsMini : fsCard).forceActiveFocus()

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
    // The info panel is the last thing in a long column, so switching it on used to
    // look like nothing happened: scroll to it.
    onShowInfoChanged: if (showInfo) Qt.callLater(function () {
      var y = fsInfoBox.mapToItem(fsColumn, 0, 0).y
      fsDetailsFlick.contentY = Math.max(0, Math.min(y - Style.space(8), fsDetailsFlick.contentHeight - fsDetailsFlick.height))
    })
    // The AI re-read output: open while it runs, then folds down to one line.
    property bool outputExpanded: false
    Connections {
      target: receiptReparseProc
      function onRunningChanged() { if (!receiptReparseProc.running) receiptFullScreen.outputExpanded = false }
    }
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
    // How far past "fits the pane" zoom can go. A linked bill's photo is
    // often the compressed copy receipt-ledger-stitcher leaves behind (long
    // side shrunk to 1600px) once the original is deleted, but an unlinked
    // bill's photo is still the original, full-resolution phone shot (often
    // 3000-4000px on the long side) — a flat 5x used to sit right around, or
    // just under, the point where a full-res photo reaches 1:1 pixel
    // density, so zoom seemed to "stop working" just as more detail would
    // have appeared. 8x clears that for typical phone photos while still
    // stopping well short of zooming into pure upscaled noise.
    property real maxPhotoZoom: 24.0
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
      receiptFullScreen.compact = false
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
    onBillIdChanged: {
      receiptFullScreen.photoZoom = 1.0
      receiptFullScreen.extraRotation = 0
      root.ensurePhotoExported(receiptFullScreen.r)
    }

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
      visible: !receiptFullScreen.compact
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)
      MouseArea { anchors.fill: parent; onClicked: root.closeReceiptDetail() }
    }

    // ---- minimised: which bill, its total and state, and the way to the next one
    Item {
      id: fsMini
      readonly property var mark: Model.receiptStateMark(receiptFullScreen.r)
      visible: receiptFullScreen.compact
      x: root.miniX >= 0 ? Math.max(0, Math.min(root.miniX, parent.width - width)) : parent.width - width - Style.space(24)
      y: root.miniY >= 0 ? Math.max(0, Math.min(root.miniY, parent.height - height)) : parent.height - height - Style.space(24)
      width: Style.space(340)
      height: fsMiniCol.implicitHeight + Style.space(28)
      focus: receiptFullScreen.compact
      Keys.onEscapePressed: function (event) { receiptFullScreen.compact = false; event.accepted = true }
      Keys.onLeftPressed: receiptFullScreen.stepReceipt(-1)
      Keys.onRightPressed: receiptFullScreen.stepReceipt(1)

      BorderSurface {
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.none()
        radius: Style.cornerRadius
      }
      DragHandler {
        id: fsMiniDrag
        target: null
        property real sx: 0
        property real sy: 0
        onActiveChanged: if (active) { sx = fsMini.x; sy = fsMini.y }
        onActiveTranslationChanged: if (active) root.saveMiniPos(sx + activeTranslation.x, sy + activeTranslation.y)
      }
      HoverHandler { cursorShape: fsMiniDrag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor }

      Column {
        id: fsMiniCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(14) }
        spacing: Style.space(6)

        Item {
          width: parent.width
          height: Style.space(24)
          Text {
            anchors { left: parent.left; right: fsMiniTotal.left; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: Model.receiptTitle(receiptFullScreen.r)
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: fsMiniTotal
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            text: receiptFullScreen.r.total != null ? Model.cashewMoney(receiptFullScreen.r.total) : ""
            color: root.debitColor
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: fsMini.mark.pill + "  ·  " + Model.receiptSubtitle(receiptFullScreen.r)
            + (receiptFullScreen.linkedTxn ? "  ·  " + Model.transactionDisplayName(receiptFullScreen.linkedTxn, store.transactionNameOverrides) : "")
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        LlmStatus { width: parent.width }
        Item {
          width: parent.width
          height: Style.space(28)
          Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            spacing: Style.space(4)
            PanelActionButton {
              size: Style.space(24)
              iconText: "<"
              tooltipText: "Previous bill (Left arrow)"
              foreground: root.foreground
              onClicked: receiptFullScreen.stepReceipt(-1)
            }
            PanelActionButton {
              size: Style.space(24)
              iconText: ">"
              tooltipText: "Next bill (Right arrow)"
              foreground: root.foreground
              onClicked: receiptFullScreen.stepReceipt(1)
            }
          }
          Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: Style.space(4)
            PanelActionButton {
              size: Style.space(24)
              iconText: "󰖯"
              tooltipText: "Expand (Esc)"
              foreground: root.foreground
              onClicked: receiptFullScreen.compact = false
            }
            PanelActionButton {
              size: Style.space(24)
              iconText: "x"
              tooltipText: "Close"
              foreground: root.foreground
              onClicked: root.closeReceiptDetail()
            }
          }
        }
      }
    }

    Item {
      id: fsCard
      visible: !receiptFullScreen.compact
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(960))
      height: Math.min(parent.height - Style.space(80), Style.space(680))
      focus: !receiptFullScreen.compact
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
      PanelActionButton {
        id: fsMiniBtn
        anchors.top: parent.top
        anchors.right: fsCloseBtn.left
        anchors.margins: Style.space(10)
        anchors.rightMargin: Style.space(6)
        size: Style.space(28)
        iconText: "󰖰"
        tooltipText: "Minimise: keep this bill in the corner"
        foreground: root.foreground
        focusable: true
        onClicked: { receiptFullScreen.pickingLink = false; receiptFullScreen.compact = true }
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
            anchors.margins: 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // The photo's own aspect, read from a tiny copy so it never depends on the
            // zoomed Image below (that would loop). Turned 90 or 270 degrees, the shape on
            // screen swaps width and height.
            readonly property real photoAspect: aspectProbe.implicitHeight > 0 ? aspectProbe.implicitWidth / aspectProbe.implicitHeight : 1.0
            readonly property int turn: ((receiptFullScreen.r.rotation || 0) + receiptFullScreen.extraRotation + 360) % 360
            readonly property bool sideways: turn === 90 || turn === 270
            readonly property real shownAspect: sideways ? 1.0 / photoAspect : photoAspect
            // The photo as shown at zoom 1: the biggest box of its shape that fits the pane.
            readonly property real fitW: shownAspect > width / Math.max(1, height) ? width : height * shownAspect
            readonly property real fitH: shownAspect > width / Math.max(1, height) ? width / shownAspect : height
            // Content IS the photo (no empty margin around it), so no pan can leave the picture.
            contentWidth: fitW * receiptFullScreen.photoZoom
            contentHeight: fitH * receiptFullScreen.photoZoom
            // A photo smaller than the pane (zoom 1) is centred, not pinned to a corner.
            leftMargin: Math.max(0, (width - contentWidth) / 2)
            rightMargin: leftMargin
            topMargin: Math.max(0, (height - contentHeight) / 2)
            bottomMargin: topMargin

            // Zoom to `z`, keeping the point (vx, vy) of the pane where it is on the photo.
            function zoomTo(z, vx, vy) {
              var clamped = Math.max(1.0, Math.min(receiptFullScreen.maxPhotoZoom, z))
              if (clamped === receiptFullScreen.photoZoom) return
              var fx = (contentX + vx - leftMargin) / Math.max(1, contentWidth)
              var fy = (contentY + vy - topMargin) / Math.max(1, contentHeight)
              receiptFullScreen.photoZoom = clamped
              contentX = fx * contentWidth - vx + leftMargin
              contentY = fy * contentHeight - vy + topMargin
              returnToBounds()
            }
            // Centre the pane on a point of the photo given as fractions (0..1) of it.
            function centreOn(fx, fy) {
              contentX = fx * contentWidth - width / 2 + leftMargin
              contentY = fy * contentHeight - height / 2 + topMargin
              returnToBounds()
            }

            Image {
              id: aspectProbe
              visible: false
              source: photoImg.source
              sourceSize.width: 64
              asynchronous: true
              cache: false
            }

            Image {
              id: photoImg
              // The box has the photo's own shape (turned back when sideways), so
              // PreserveAspectFit leaves no empty margin inside it.
              width: photoFlick.sideways ? photoFlick.contentHeight : photoFlick.contentWidth
              height: photoFlick.sideways ? photoFlick.contentWidth : photoFlick.contentHeight
              x: (photoFlick.contentWidth - width) / 2
              y: (photoFlick.contentHeight - height) / 2
              source: {
                var _dep = root.photoCacheVersion       // re-evaluate once an export finishes
                var full = root.effectivePhotoFile(receiptFullScreen.r)
                return full ? ("file://" + full)
                  : (receiptFullScreen.r.thumbPath ? ("file://" + root.widgetDir + "/data/" + receiptFullScreen.r.thumbPath) : "")
              }
              rotation: photoFlick.turn
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              cache: false
              // Decode at the size the photo is actually shown at, so zooming in
              // re-decodes sharper, up to the file's own resolution.
              sourceSize.width: Math.ceil(width)
              sourceSize.height: Math.ceil(height)
            }
          }

          // Where you are on the photo: a small square at the top right with a box for
          // the part on screen. Shown only when zoomed in. Click or drag in it to jump.
          Rectangle {
            id: photoMap
            visible: receiptFullScreen.photoZoom > 1.0
            readonly property real side: Style.space(72)
            width: photoFlick.shownAspect >= 1 ? side : side * photoFlick.shownAspect
            height: photoFlick.shownAspect >= 1 ? side / photoFlick.shownAspect : side
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            color: Qt.rgba(0, 0, 0, 0.45)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.55)
            radius: Style.space(2)

            Rectangle {
              // the part of the photo on screen
              readonly property real cw: Math.max(1, photoFlick.contentWidth)
              readonly property real ch: Math.max(1, photoFlick.contentHeight)
              x: Math.max(0, Math.min(photoMap.width - width, (photoFlick.contentX + photoFlick.leftMargin) / cw * photoMap.width))
              y: Math.max(0, Math.min(photoMap.height - height, (photoFlick.contentY + photoFlick.topMargin) / ch * photoMap.height))
              width: Math.min(photoMap.width, photoFlick.width / cw * photoMap.width)
              height: Math.min(photoMap.height, photoFlick.height / ch * photoMap.height)
              color: Qt.rgba(1, 1, 1, 0.22)
              border.width: 1
              border.color: "#ffffff"
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              function jump(mouse) {
                photoFlick.centreOn(Math.max(0, Math.min(1, mouse.x / photoMap.width)),
                                    Math.max(0, Math.min(1, mouse.y / photoMap.height)))
              }
              onPressed: function (mouse) { jump(mouse) }
              onPositionChanged: function (mouse) { if (pressed) jump(mouse) }
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
          // Plain wheel scrolls the photo up/down (shift: left/right).
          // Middle button held + wheel (or Ctrl + wheel) zooms around the cursor.
          MouseArea {
            id: photoWheel
            anchors.fill: photoFlick
            acceptedButtons: Qt.MiddleButton
            property bool midDown: false
            onPressed: midDown = true
            onReleased: midDown = false
            onCanceled: midDown = false
            onWheel: function (event) {
              var delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
              if (delta !== 0) {
                if (midDown || (event.buttons & Qt.MiddleButton) || (event.modifiers & Qt.ControlModifier)) {
                  var factor = delta > 0 ? 1.2 : (1 / 1.2)
                  photoFlick.zoomTo(receiptFullScreen.photoZoom * factor, event.x, event.y)
                } else {
                  var step = event.pixelDelta.y !== 0 ? delta : delta * 0.5
                  if (event.modifiers & Qt.ShiftModifier) photoFlick.contentX -= step
                  else photoFlick.contentY -= step
                  photoFlick.returnToBounds()
                }
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
              tooltipText: "Zoom out (middle button + wheel)"
              foreground: "#ffffff"
              focusable: false
              enabled: receiptFullScreen.photoZoom > 1.0
              onClicked: photoFlick.zoomTo(receiptFullScreen.photoZoom / 1.3, photoFlick.width / 2, photoFlick.height / 2)
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
              enabled: receiptFullScreen.photoZoom < receiptFullScreen.maxPhotoZoom
              onClicked: photoFlick.zoomTo(receiptFullScreen.photoZoom * 1.3, photoFlick.width / 2, photoFlick.height / 2)
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

          ScrollWheelArea { anchors.fill: linkFlick; target: linkFlick }
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

            // The bill's category sits right above the bill, where it is seen
            // first, not 600 lines down below the totals. It is a chip that opens a small picker right
            // here in the card (no popup). Choosing writes the user's own
            // category, which a later re-read never overwrites.
            Item {
              id: catBox
              property bool picking: false
              property string pickMain: ""
              readonly property var cur: receiptFullScreen.r.category
              readonly property var catDef: {
                var list = store.receiptCategories || []
                for (var k = 0; k < list.length; k++) if (cur && list[k].name === cur.category) return list[k]
                return null
              }
              // Expense categories only: a bill is money out.
              readonly property var choices: (store.receiptCategories || []).filter(function (c) { return c.type === "expense" })
              readonly property var mainDef: {
                var list = catBox.choices
                for (var k = 0; k < list.length; k++) if (list[k].name === catBox.pickMain) return list[k]
                return null
              }
              width: parent.width
              height: catColumn.implicitHeight
              Column {
                id: catColumn
                width: parent.width
                spacing: Style.space(4)
                Rectangle {
                  implicitWidth: chipText.implicitWidth + Style.space(16)
                  implicitHeight: chipText.implicitHeight + Style.space(8)
                  width: implicitWidth; height: implicitHeight
                  radius: height / 2
                  color: Util.alpha(catBox.catDef && catBox.catDef.color ? catBox.catDef.color : Color.accent, 0.35)
                  border.width: 1
                  border.color: Util.alpha(root.foreground, 0.25)
                  Text {
                    id: chipText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: catBox.cur
                      ? ((catBox.catDef && catBox.catDef.icon ? catBox.catDef.icon + " " : "") + catBox.cur.category
                         + (catBox.cur.subcategory ? " › " + catBox.cur.subcategory : "")
                         + (catBox.cur.source === "user" ? "" : "  (suggested)"))
                      : "＋ Category"
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { catBox.pickMain = catBox.cur ? catBox.cur.category : ""; catBox.picking = !catBox.picking }
                  }
                }
                // Step 1: the main categories as tiles, the same look as the
                // transaction edit panel. A bill is money out, so only expense
                // categories are offered (not Salary, Rent Received, Balance...).
                Grid {
                  id: billCatGrid
                  visible: catBox.picking && catBox.pickMain === ""
                  columns: 4
                  spacing: Style.space(6)
                  width: parent.width
                  readonly property real tileW: (width - 3 * spacing) / 4
                  Repeater {
                    model: catBox.picking ? catBox.choices : []
                    delegate: CatTile {
                      required property var modelData
                      width: billCatGrid.tileW
                      glyph: modelData.icon || ""
                      label: modelData.name
                      tint: modelData.color || Color.accent
                      selected: !!catBox.cur && catBox.cur.source === "user" && catBox.cur.category === modelData.name
                      marked: !!catBox.cur && catBox.cur.source !== "user" && catBox.cur.category === modelData.name
                      onClicked: {
                        if ((modelData.subcategories || []).length > 0) catBox.pickMain = modelData.name
                        else { store.setReceiptCategory(receiptFullScreen.r.id, modelData.name, ""); catBox.picking = false }
                      }
                    }
                  }
                }

                // Step 2: the sub-categories of the chosen one, in the same place.
                Column {
                  visible: catBox.picking && catBox.pickMain !== ""
                  width: parent.width
                  spacing: Style.space(6)
                  Row {
                    spacing: Style.space(8)
                    TextAction { label: "‹ Back"; onTriggered: catBox.pickMain = "" }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: (catBox.mainDef && catBox.mainDef.icon ? catBox.mainDef.icon + "  " : "") + catBox.pickMain
                      color: catBox.mainDef && catBox.mainDef.color ? catBox.mainDef.color : root.foreground
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: Style.font.subtitle
                    }
                    TextAction {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !!catBox.cur && catBox.cur.source === "user"
                      label: "clear my choice"
                      onTriggered: { store.setReceiptCategory(receiptFullScreen.r.id, "", ""); catBox.picking = false }
                    }
                  }
                  Grid {
                    id: billSubGrid
                    columns: 3
                    spacing: Style.space(6)
                    width: parent.width
                    readonly property real tileW: (width - 2 * spacing) / 3
                    CatTile {
                      width: billSubGrid.tileW
                      glyph: "󰄬"
                      label: "Just " + catBox.pickMain
                      tint: catBox.mainDef && catBox.mainDef.color ? catBox.mainDef.color : Color.accent
                      primary: true
                      selected: !!catBox.cur && catBox.cur.category === catBox.pickMain && !catBox.cur.subcategory
                      onClicked: { store.setReceiptCategory(receiptFullScreen.r.id, catBox.pickMain, ""); catBox.picking = false }
                    }
                    Repeater {
                      model: catBox.mainDef ? (catBox.mainDef.subcategories || []) : []
                      delegate: CatTile {
                        required property string modelData
                        width: billSubGrid.tileW
                        glyph: ((catBox.mainDef && catBox.mainDef.subIcons) || {})[modelData] || ""
                        label: modelData
                        tint: catBox.mainDef && catBox.mainDef.color ? catBox.mainDef.color : Color.accent
                        selected: !!catBox.cur && catBox.cur.category === catBox.pickMain && catBox.cur.subcategory === modelData
                        onClicked: { store.setReceiptCategory(receiptFullScreen.r.id, catBox.pickMain, modelData); catBox.picking = false }
                      }
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

                // App orders: which app, and the order number, as muted lines.
                Row {
                  visible: !receiptFullScreen.billCollapsed && (!!receiptFullScreen.r.platform || receiptFullScreen.editingFields)
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText; text: "via"
                    color: Qt.darker(root.foreground, 1.6)
                    font.family: "monospace"; font.pixelSize: Style.font.caption
                  }
                  InlineEdit {
                    fieldName: "platform"
                    display: receiptFullScreen.r.platform || "—"
                    initial: receiptFullScreen.r.platform || ""
                    textColor: Qt.darker(root.foreground, 1.6)
                    placeholder: "Swiggy, Zomato…"
                  }
                }
                Row {
                  visible: !receiptFullScreen.billCollapsed && (!!receiptFullScreen.r.orderId || receiptFullScreen.editingFields)
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText; text: "Order"
                    color: Qt.darker(root.foreground, 1.6)
                    font.family: "monospace"; font.pixelSize: Style.font.caption
                  }
                  InlineEdit {
                    fieldName: "order_id"
                    display: receiptFullScreen.r.orderId || "—"
                    initial: receiptFullScreen.r.orderId || ""
                    textColor: Qt.darker(root.foreground, 1.6)
                    placeholder: "Order id"
                  }
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
                        placeholder: "02-Nov-26"
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
                        display: receiptFullScreen.r.time ? Model.formatClock(receiptFullScreen.r.time) : "—"
                        initial: receiptFullScreen.r.time ? Model.formatClock(receiptFullScreen.r.time) : ""
                        textColor: Qt.darker(root.foreground, 1.1)
                        placeholder: "8:15 PM"
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

                // Item total, then one row per charge, then the discount, the
                // taxes and the round off, as the app prints them. The
                // discount is kept as a positive amount but printed with its
                // minus sign.
                ReceiptEditField {
                  ledger: true
                  numeric: true
                  label: "Item total"
                  fieldName: "subtotal"
                  value: receiptFullScreen.r.subtotal != null ? receiptFullScreen.r.subtotal.toFixed(2) : ""
                }

                // Platform / delivery / service charges, as printed. A waived
                // one shows the struck-through original and a green FREE.
                // Click an amount to change it. (Edit mode: waive it, remove
                // it, or add one.)
                Repeater {
                  model: receiptFullScreen.r.fees || []
                  delegate: Item {
                    id: feeRow
                    required property var modelData
                    width: parent.width
                    height: feeField.height
                    ReceiptEditField {
                      id: feeField
                      width: parent.width - (receiptFullScreen.editingFields ? Style.space(84) : 0)
                      ledger: true
                      numeric: true
                      label: feeRow.modelData.label
                      fieldName: feeRow.modelData.waived ? "original" : "amount"
                      feeField: feeRow.modelData.waived ? "original" : "amount"
                      feeLine: feeRow.modelData.line
                      struck: !!feeRow.modelData.waived && feeRow.modelData.original != null
                      free: !!feeRow.modelData.waived
                      value: feeRow.modelData.waived
                        ? (feeRow.modelData.original != null ? Number(feeRow.modelData.original).toFixed(2) : "")
                        : Number(feeRow.modelData.amount).toFixed(2)
                    }
                    TextAction {
                      visible: receiptFullScreen.editingFields
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(24)
                      anchors.verticalCenter: parent.verticalCenter
                      label: feeRow.modelData.waived ? "charge" : "free"
                      onTriggered: {
                        var rid = receiptFullScreen.r.id, ln = feeRow.modelData.line
                        var next = feeRow.modelData.waived ? "0" : "1"
                        store.editReceiptFee(rid, ln, "waived", next)
                      }
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

                  NewItemBox { id: addFeeLabel; width: Style.space(130); placeholderText: "Charge (Platform fee…)" }
                  NewItemBox { id: addFeeAmt; width: Style.space(64); placeholderText: "amount" }
                  NewItemBox {
                    id: addFeeOrig; width: Style.space(64); placeholderText: "was"
                    onAccepted: addFeeBtn.triggered()
                  }
                  TextAction {
                    id: addFeeBtn
                    label: "+ Add"
                    onTriggered: {
                      if (store.addReceiptFee(receiptFullScreen.r.id, addFeeLabel.text, addFeeAmt.text,
                                              addFeeOrig.text, false)) {
                        addFeeLabel.text = ""; addFeeAmt.text = ""; addFeeOrig.text = ""
                        addFeeLabel.forceActiveFocus()
                      }
                    }
                  }
                  TextAction {
                    label: "+ Add free"
                    onTriggered: {
                      if (store.addReceiptFee(receiptFullScreen.r.id, addFeeLabel.text, "0",
                                              addFeeOrig.text, true)) {
                        addFeeLabel.text = ""; addFeeAmt.text = ""; addFeeOrig.text = ""
                        addFeeLabel.forceActiveFocus()
                      }
                    }
                  }
                }

                ReceiptEditField {
                  ledger: true
                  numeric: true
                  label: "Discount"
                  fieldName: "discount"
                  value: receiptFullScreen.r.discount != null
                    ? (receiptFullScreen.r.discount ? "-" : "") + Math.abs(receiptFullScreen.r.discount).toFixed(2) : ""
                }

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

                ReceiptEditField {
                  ledger: true
                  numeric: true
                  label: "Round off"
                  fieldName: "round_off"
                  value: receiptFullScreen.r.roundOff != null ? receiptFullScreen.r.roundOff.toFixed(2) : ""
                }

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
                  label: receiptFullScreen.r.paymentMethod
                    ? "PAID VIA " + String(receiptFullScreen.r.paymentMethod).toUpperCase() : "GRAND TOTAL"
                  fieldName: receiptFullScreen.r.printedTotal != null ? "printed_total" : "total"
                  prefix: Model.currencySymbol(receiptFullScreen.r.currency)
                  value: Model.receiptPrinted(receiptFullScreen.r) != null
                    ? Model.receiptPrinted(receiptFullScreen.r).toFixed(2) : ""
                  valueColor: Model.receiptIsBalanced(receiptFullScreen.r) ? root.creditColor : root.debitColor
                }

                // Parts against the printed total, quietly: green when they
                // agree, the gap in the debit colour when they do not.
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignRight
                  text: Model.receiptCheckLine(receiptFullScreen.r)
                  wrapMode: Text.WordWrap
                  color: Model.receiptParts(receiptFullScreen.r).ok ? Util.alpha(root.creditColor, 0.85) : root.debitColor
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
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

            TextAction {
              visible: !Model.receiptParts(receiptFullScreen.r).ok && Model.receiptPrinted(receiptFullScreen.r) != null
                && Model.receiptItemCount(receiptFullScreen.r) > 0
              label: "Use computed total"
              onTriggered: store.useComputedTotal(receiptFullScreen.r.id)
            }

            Text {
              visible: receiptFullScreen.r.saved != null && receiptFullScreen.r.saved > 0
              textFormat: Text.PlainText
              text: "You saved " + Model.currencySymbol(receiptFullScreen.r.currency)
                + (receiptFullScreen.r.saved || 0).toFixed(2)
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
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
              id: fsInfoBox
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

          ScrollWheelArea { visible: !parent.folded; anchors.fill: fsDetailsFlick; target: fsDetailsFlick }

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
            readonly property bool open: receiptReparseProc.running || receiptFullScreen.outputExpanded
            height: open ? Style.space(150) : Style.space(26)
            visible: !parent.folded && receiptReparseProc.receiptId === receiptFullScreen.r.id
              && (receiptReparseProc.running || receiptReparseOutput.text.length > 0)
            clip: true

            Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: Util.alpha(root.foreground, 0.05) }

            // Folded: one line, click to read the output again.
            Item {
              visible: !fsOutputBox.open
              anchors.fill: parent
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                textFormat: Text.PlainText
                text: "AI output  ·  click to show"
                color: Qt.darker(root.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: receiptFullScreen.outputExpanded = true
              }
            }
            TextAction {
              visible: fsOutputBox.open && !receiptReparseProc.running
              z: 2
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(6)
              label: "Collapse"
              onTriggered: receiptFullScreen.outputExpanded = false
            }
            Flickable {
              id: fsOutputFlick
              visible: fsOutputBox.open
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

            ScrollWheelArea { anchors.fill: fsOutputFlick; target: fsOutputFlick }
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

    TextMetrics {
      id: badgeMetrics
      text: tabChip.badge
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Text {
      id: badgeDot
      anchors.left: tabLabel.right
      anchors.leftMargin: tabChip.badge === "" ? 0 : Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
      // Width from a TextMetrics, not from this Text's own implicitWidth:
      // that read was the "Binding loop detected for property width".
      width: tabChip.badge === "" ? 0 : Math.ceil(badgeMetrics.advanceWidth)
      visible: tabChip.badge !== ""
      textFormat: Text.PlainText
      text: tabChip.badge
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // RECURRING row: one recurring series set in Cashew (read only). The
  // category circle of the transaction rows, the title and "next · account",
  // and on the right the amount over a state pill. Click / Enter / Space
  // opens one detail line under it.
  component RecurringRow: BorderSurface {
    id: recurringRow
    required property var modelData
    property bool expanded: false
    readonly property var series: recurringRow.modelData
    readonly property var st: Model.recurringStateText(recurringRow.series)
    readonly property bool ended: !recurringRow.series.active || recurringRow.series.state === "ended"
    readonly property bool isDebit: Number(recurringRow.series.amount) < 0
    readonly property color directionColor: recurringRow.isDebit ? root.debitColor : root.creditColor
    readonly property color toneColor: recurringRow.st.tone === "debit" ? root.debitColor
      : (recurringRow.st.tone === "pending" ? root.pendingColor
        : (recurringRow.st.tone === "credit" ? root.creditColor : Qt.darker(root.foreground, 1.4)))
    readonly property string categoryIcon: recurringRow.series.category ? Model.categoryIcon(recurringRow.series.category, store.receiptCategories) : ""
    readonly property string subIcon: recurringRow.series.category ? Model.subcategoryIcon(recurringRow.series.category, recurringRow.series.subcategory, store.receiptCategories) : ""
    readonly property bool _hot: recHover.hovered || recurringRow.activeFocus
    readonly property int collapsedHeight: Style.space(52)

    implicitHeight: recurringRow.collapsedHeight + (recurringRow.expanded ? recDetail.implicitHeight + Style.space(8) : 0)
    height: implicitHeight
    clip: true
    radius: Style.cornerRadius
    opacity: recMouse.pressed ? 0.75 : (recurringRow.ended ? 0.6 : 1.0)
    color: recurringRow._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent"
    borderSpec: recurringRow.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 80 } }

    HoverHandler { id: recHover }

    activeFocusOnTab: true
    Keys.onReturnPressed: recurringRow.expanded = !recurringRow.expanded
    Keys.onEnterPressed: recurringRow.expanded = !recurringRow.expanded
    Keys.onSpacePressed: recurringRow.expanded = !recurringRow.expanded
    Keys.onUpPressed: root.focusNext(recurringRow, false)
    Keys.onDownPressed: root.focusNext(recurringRow, true)

    Item {
      id: recCollapsed
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: recurringRow.collapsedHeight

      MouseArea {
        id: recMouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { recurringRow.forceActiveFocus(); recurringRow.expanded = !recurringRow.expanded }
      }

      // The category circle, as in the transaction rows.
      Rectangle {
        id: recAvatar
        width: Style.space(36)
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 1.5
        border.color: Util.alpha(recurringRow.directionColor, 0.85)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: recurringRow.categoryIcon !== "" ? recurringRow.categoryIcon : (recurringRow.isDebit ? "↓" : "↑")
          color: recurringRow.directionColor
          opacity: recurringRow.categoryIcon !== "" ? 1.0 : 0.6
          font.family: recurringRow.categoryIcon !== "" ? "JetBrainsMono Nerd Font" : Style.font.family
          font.bold: recurringRow.categoryIcon === ""
          font.pixelSize: recurringRow.categoryIcon !== "" ? Style.font.title : Style.font.subtitle
        }

        Rectangle {
          visible: recurringRow.subIcon !== ""
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: -Style.space(5)
          anchors.bottomMargin: -Style.space(4)
          width: Style.space(16)
          height: width
          radius: width / 2
          color: Color.background
          border.width: 1.5
          border.color: Util.alpha(recurringRow.directionColor, 0.85)
          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: recurringRow.subIcon
            color: recurringRow.directionColor
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: Style.space(10)
          }
        }
      }

      Column {
        anchors.left: recAvatar.right
        anchors.leftMargin: Style.space(10)
        anchors.right: recAmountStack.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: recurringRow.series.title || ""
          color: root.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: Model.recurringLine(recurringRow.series)
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Column {
        id: recAmountStack
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)
        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: Model.formatAmount({ amount: Number(recurringRow.series.amount), currency: "INR" })
          color: recurringRow.directionColor
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
        Rectangle {
          id: recPill
          visible: recurringRow.st.pill !== ""
          anchors.right: parent.right
          width: recPillText.implicitWidth + Style.space(10)
          height: recPillText.implicitHeight + Style.space(3)
          radius: Style.space(4)
          color: Util.alpha(recurringRow.toneColor, 0.18)
          Text {
            id: recPillText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: recurringRow.st.pill
            color: recurringRow.toneColor
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption - 1
          }
        }
        Text {
          visible: recurringRow.st.pill === "" && recurringRow.st.short !== ""
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: recurringRow.st.short
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    // The detail line, shown when the row is open.
    Text {
      id: recDetail
      visible: recurringRow.expanded
      anchors.top: recCollapsed.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(46)
      anchors.rightMargin: Style.spacing.rowPaddingX
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: Model.recurringDetail(recurringRow.series)
      color: Qt.darker(root.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
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
    readonly property string billState: billRow.parts.awaiting
      ? "awaiting"
      : (billRow.parts.payNow > 0
        ? "due"
        : (billRow.parts.nextBill > 0 && !billRow.parts.inCredit ? "pending" : "settled"))
    readonly property bool displayPaid: billRow.billState === "settled"
    readonly property color statusColor: billRow.billState === "settled"
      ? root.creditColor
      : (billRow.billState === "due" ? root.debitColor : root.pendingColor)
    readonly property string statusGlyph: billRow.billState === "settled"
      ? "✓"
      : (billRow.billState === "due" ? "!" : (billRow.billState === "awaiting" ? "…" : "●"))
    // Everything the collapsed row shows: Model.billRowView.
    readonly property var view: Model.billRowView(billRow.overview, billRow.paid)
    readonly property var glyphs: ({ alert: "󰗖", clock: "󰅐", check: "󰄬", plus: "󰐕" })
    function toneColor(tone) {
      return tone === "debit" ? root.debitColor : (tone === "pending" ? root.pendingColor
        : (tone === "credit" ? root.creditColor : (tone === "foreground" ? root.foreground : Qt.darker(root.foreground, 1.4))))
    }
    readonly property bool _hot: rowHover.hovered || billRow.activeFocus
    // The status column (disc + label) is the tallest thing in the row, so
    // it sets this; the two text lines need less.
    readonly property int collapsedHeight: Style.space(52)
    // Where the row's text starts — the status column plus its gap. Shared
    // with the detail panel, so the panel's text lines up under the card
    // name instead of an inset worked out from a disc size long since gone.
    readonly property int contentLeft: Style.spacing.rowPaddingX

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

      // Clicking anywhere on the row expands its details.
      MouseArea {
        id: rowMouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: billRow.expanded = !billRow.expanded
      }

      // Line 1:  ₹ bill   ₹ so far                         STATE
      // Line 2:  card ••1234 · detail
      // Both figures are always shown, in fixed columns so they line up from row to
      // row. The one to act on is bold; the other is muted.
      Row {
        id: figures
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.top: parent.top
        anchors.topMargin: Style.space(8)
        spacing: Style.space(6)

        Item {
          width: Style.space(90)
          height: Style.font.subtitle + Style.space(4)
          Text {
            id: billAmount
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: billRow.view.bill.text
            // the state's colour (red unpaid, amber sent, green paid); dimmer when it is not the one to act on
            color: billRow.view.bill.tone === "muted"
              ? (billRow.view.bill.primary ? root.foreground : Qt.darker(root.foreground, 1.5))
              : Util.alpha(billRow.toneColor(billRow.view.bill.tone), billRow.view.bill.primary ? 1.0 : 0.8)
            font.family: Style.font.family
            font.bold: billRow.view.bill.primary
            font.pixelSize: billRow.view.bill.primary ? Style.font.subtitle : Style.font.body
          }
          Text {
            anchors.left: billAmount.right
            anchors.leftMargin: Style.space(4)
            anchors.baseline: billAmount.baseline
            textFormat: Text.PlainText
            text: billRow.view.bill.text.indexOf("credit") >= 0 ? "" : "bill"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: Style.space(100)
          height: Style.font.subtitle + Style.space(4)
          Text {
            id: soFarAmount
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: billRow.view.soFar.text
            color: billRow.view.soFar.tone === "pending"
              ? Util.alpha(root.pendingColor, billRow.view.soFar.primary ? 1.0 : 0.8)
              : (billRow.view.soFar.primary ? root.foreground : Qt.darker(root.foreground, 1.5))
            font.family: Style.font.family
            font.bold: billRow.view.soFar.primary
            font.pixelSize: billRow.view.soFar.primary ? Style.font.subtitle : Style.font.body
          }
          Text {
            anchors.left: soFarAmount.right
            anchors.leftMargin: Style.space(4)
            anchors.baseline: soFarAmount.baseline
            textFormat: Text.PlainText
            text: "so far"
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Rectangle {
        id: statePill
        readonly property color tone: billRow.toneColor(billRow.view.pillTone)
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: figures.verticalCenter
        anchors.verticalCenterOffset: -Style.space(1)
        width: pillText.implicitWidth + Style.space(10)
        height: pillText.implicitHeight + Style.space(3)
        radius: Style.space(4)
        color: Util.alpha(statePill.tone, 0.18)
        Text {
          id: pillText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: billRow.view.pill
          color: statePill.tone
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.caption - 1
        }
      }

      // Line 2: the card, then what matters about it.
      Row {
        id: cardLine
        anchors.left: figures.left
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.top: figures.bottom
        anchors.topMargin: Style.space(4)
        spacing: Style.space(6)

        BrandMark {
          id: billBrandMark
          anchors.verticalCenter: parent.verticalCenter
          network: billRow.brand.network
          markHeight: Style.spaceReal(9)
        }
        Text {
          id: nameText
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: billRow.bank + " ••" + billRow.overview.last4
          color: root.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.caption
        }
        Text {
          id: detailText
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, cardLine.width - (billBrandMark.visible ? billBrandMark.width + cardLine.spacing : 0)
                          - nameText.implicitWidth - cardLine.spacing)
          textFormat: Text.PlainText
          text: billRow.view.line2
          color: billRow.view.rightUrgent ? root.debitColor : Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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

      // Was the status disc's click: say by hand that you paid this bill.
      Row {
        spacing: Style.space(6)
        TxnBtn {
          label: billRow.paid ? "Mark as unpaid" : "Mark as paid"
          onClicked: store.setBillPaid(billRow.overview.last4, !billRow.paid)
        }
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
          { label: "Last bill", value: billRow.parts.hasBreakdown ? billRow.overview.last_statement_amount : "" },
          // paidIn is only known once the Outstanding Summary has been
          // scraped; until then the same money shows as this cycle's credits.
          { label: "Paid into card", value: billRow.parts.paidIn > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.paidIn)
              : (Model.parseCurrencyString(billRow.overview.credited_this_cycle) !== 0
                  ? billRow.overview.credited_this_cycle : "") },
          { label: "Paid, bank not updated", value: billRow.parts.awaiting
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.awaitingAmount)
                + (billRow.parts.awaitingDate ? "  ·  " + Model.formatShortDate(billRow.parts.awaitingDate, true) : "") : "" },
          { label: "Left to pay", value: billRow.parts.payNow > 0
              ? Model.currencySymbol("INR") + Model.formatGrouped(billRow.parts.payNow) : "" },
          { label: "In credit", value: billRow.parts.inCredit
              ? Model.currencySymbol("INR") + Model.formatGrouped(Math.abs(billRow.parts.payNow)) : "" },
          { label: "Last bill closed", value: Model.cycleClose(billRow.overview).known ? Model.formatShortDate(Model.cycleClose(billRow.overview).lastClosed, true) : Model.formatShortDate(billRow.overview.statementDate, true) },
          { label: "Minimum due", value: billRow.parts.payNow > 0 ? (billRow.overview.minimum_due || "") : "" },
          { label: "Pay by", value: billRow.overview.dueDate
              ? Model.formatShortDate(billRow.overview.dueDate, true) + "  ·  " + Model.dueCountdown(billRow.overview.dueDate) : "" },
          { label: "Next bill closes", value: Model.cycleClose(billRow.overview).known ? Model.formatShortDate(Model.cycleClose(billRow.overview).closesOn, true) : "" },
          { label: "Bill so far", value: Math.round(billRow.parts.nextBill) > 0
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
            anchors.left: labelText.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
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
            mb.receipt.time ? Model.formatClock(mb.receipt.time) : "",
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
    readonly property string accountName: Model.accountChipText(txn, store.cardOverviews, store.accountNameOverrides)
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
            text: pick.accountName
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
    readonly property int collapsedHeight: Style.space(52)
    // The expanded part lines up with the title column (ring + gap).
    readonly property int contentLeft: Style.spacing.rowPaddingX + Style.space(36) + Style.space(10)
    readonly property bool hasCategory: !!(receiptRow.receipt.category && receiptRow.receipt.category.category)
    readonly property string categoryIcon: receiptRow.hasCategory
      ? Model.categoryIcon(receiptRow.receipt.category.category, store.receiptCategories) : ""

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

      // A ring like the transaction avatar: the state colour around the
      // receipt's category icon (or a plain receipt glyph).
      Rectangle {
        id: avatarR
        width: Style.space(36)
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 1.5
        border.color: Util.alpha(receiptRow.statusColor, 0.85)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: receiptRow.categoryIcon !== "" ? receiptRow.categoryIcon : String.fromCodePoint(0xF0F28)
          color: receiptRow.statusColor
          font.family: "JetBrainsMono Nerd Font"
          font.pixelSize: Style.font.title
        }

        // The one place a quick decision lives without opening the whole
        // row — same precedent as BillRow's "mark as paid" disc.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            // An unmatched bill's quick decision lives in the full-screen
            // window, so this ring opens straight there; anything else
            // just expands the quick-glance thumbnail+text.
            if (receiptRow.receipt.state === "unmatched") {
              root.openReceiptDetail(receiptRow.receipt)
            } else {
              receiptRow.expanded = true
            }
          }
        }
      }

      Column {
        anchors.left: avatarR.right
        anchors.leftMargin: Style.space(10)
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
          font.pixelSize: Style.font.subtitle
          elide: Text.ElideRight
        }

        // Line 2: a state dot and word in the state colour, then the
        // date / items / GST in grey.
        Row {
          width: parent.width
          spacing: Style.space(4)

          Rectangle {
            id: stateDotR
            width: Style.space(6)
            height: width
            radius: width / 2
            color: receiptRow.statusColor
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: stateTagR
            textFormat: Text.PlainText
            text: receiptRow.mark.tag
            color: receiptRow.statusColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            readonly property string sub: Model.receiptSubtitle(receiptRow.receipt)
            width: Math.max(0, parent.width - stateDotR.width - stateTagR.implicitWidth - 2 * parent.spacing)
            visible: sub !== ""
            textFormat: Text.PlainText
            text: "· " + sub
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      Column {
        id: amountStackR
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: receiptRow.receipt.total != null
            ? Model.currencySymbol(receiptRow.receipt.currency) + Model.formatGrouped(receiptRow.receipt.total)
            : "—"
          color: receiptRow.receipt.total == null ? Qt.darker(root.foreground, 1.5)
            : (receiptRow.mark.tag === "check" ? receiptRow.statusColor : root.foreground)
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }

        Text {
          anchors.right: parent.right
          readonly property bool hasPaid: receiptRow.receipt.state === "linked"
            && receiptRow.receipt.txnAmount != null && receiptRow.receipt.txnAmount !== ""
            && !isNaN(Number(receiptRow.receipt.txnAmount))
          visible: hasPaid
          textFormat: Text.PlainText
          text: hasPaid
            ? "paid " + Model.currencySymbol(receiptRow.receipt.currency) + Model.formatGrouped(Math.abs(Number(receiptRow.receipt.txnAmount)))
            : ""
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Row {
      id: detailsPanelR
      visible: receiptRow.expanded
      anchors.top: collapsedRowR.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: receiptRow.contentLeft
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(10)

      // A small thumbnail beside the bill — clicking it opens the full
      // review window rather than growing the row itself, so the row stays
      // a quick glance and the photo gets its space only once asked for.
      Rectangle {
        id: thumbR
        visible: !!(receiptRow.receipt.thumbPath || receiptRow.receipt.storedPath)
        width: Style.space(64)
        height: Style.space(64)
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
        width: parent.width - (thumbR.visible ? thumbR.width + parent.spacing : 0)
        receipt: receiptRow.receipt
      }
    }
  }

  // ---- The RECENT filter: inline, under the RECENT header ------------------
  // A plain Item tree (no Popup, Menu or ComboBox), so it scrolls with the
  // list and can never draw outside the widget. Changing the filter only
  // changes bindings: no TextField and no transaction delegate is rebuilt.

  // One toggle chip. Left click or Space/Enter: clicked(). Right or middle
  // click, or Delete: cleared(). Left/Right move to the neighbouring chip.
  component FilterChip: BorderSurface {
    id: chip
    property string label: ""
    property string bank: ""
    property string network: ""
    property bool active: false
    property bool closable: false
    property bool focusable: true
    property string tip: ""
    signal clicked()
    signal cleared()

    readonly property bool _hot: chipMouse.containsMouse || chip.activeFocus
    // Active label colour: the accent pulled toward the foreground. Plain
    // accent on its own 20% tint is under 4.5:1 in 16 of 23 shipped themes
    // (2.6:1 in rose-pine); this mix is 4.0:1 or better in all of them.
    readonly property color _activeText: Qt.tint(Color.accent, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75))
    // A label wider than this is cut with an ellipsis (a long account name
    // must not push the chip past the widget).
    property real maxLabelWidth: Style.space(190)

    // Quiet by default: no border, a faint tonal fill. Active = accent tint.
    // Only keyboard focus draws a ring.
    implicitHeight: Style.space(26)
    implicitWidth: chipRow.implicitWidth + Style.space(14)
    radius: Style.space(13)
    opacity: chipMouse.pressed ? 0.7 : 1
    color: chip.active
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, chip._hot ? 0.24 : 0.20)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, chip._hot ? 0.13 : 0.06)
    borderSpec: chip.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    activeFocusOnTab: chip.focusable && chip.visible
    Keys.onReturnPressed: chip.clicked()
    Keys.onEnterPressed: chip.clicked()
    Keys.onSpacePressed: chip.clicked()
    Keys.onDeletePressed: chip.cleared()
    Keys.onLeftPressed: root.focusNext(chip, false)
    Keys.onRightPressed: root.focusNext(chip, true)
    Keys.onDownPressed: root.focusNext(chip, true)
    Keys.onUpPressed: root.focusNext(chip, false)
    Keys.onEscapePressed: function (event) {
      if (!root.filterOpen) { event.accepted = false; return }
      root.filterOpen = false
      event.accepted = true
      Qt.callLater(function () { column.forceActiveFocus() })
    }

    Behavior on color { ColorAnimation { duration: 100 } }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      HdfcLogo {
        variant: "icon"
        visible: chip.bank === "HDFC"
        markSize: Style.spaceReal(9)
        anchors.verticalCenter: parent.verticalCenter
      }
      AxisLogo {
        visible: chip.bank === "AXIS"
        markSize: Style.spaceReal(9)
        anchors.verticalCenter: parent.verticalCenter
      }
      SbiLogo {
        visible: chip.bank === "SBI"
        markSize: Style.spaceReal(9)
        anchors.verticalCenter: parent.verticalCenter
      }
      BrandMark {
        network: chip.network
        markHeight: Style.spaceReal(9)
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: chip.label
        width: Math.min(implicitWidth, chip.maxLabelWidth)
        elide: Text.ElideRight
        color: chip.active ? chip._activeText : root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: chip.active
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        visible: chip.closable
        textFormat: Text.PlainText
        text: "×"
        color: chip._activeText
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    ToolTip.visible: chipMouse.containsMouse && chip.tip !== ""
    ToolTip.text: chip.tip
    ToolTip.delay: 500

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onClicked: function (mouse) {
        // Capture first: the handlers can change what this chip shows, and a
        // summary chip is destroyed when its filter part is removed.
        var left = mouse.button === Qt.LeftButton
        if (left) chip.clicked()
        else chip.cleared()
      }
    }
  }

  // Min / Max amount field. Takes "5k", "1.2L", "1,200". The wheel steps by
  // 100 (Shift: 1,000); the wheel is routed here by the list's
  // ScrollWheelArea (see FilterBar.handleWheel).
  component FilterAmountField: TextField {
    id: field
    property string which: "min"

    implicitWidth: Style.space(84)
    implicitHeight: Style.space(28)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    horizontalAlignment: TextInput.AlignRight
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    selectByMouse: true
    // Only what Model.parseAmountInput reads: digits, comma, dot, space,
    // the rupee sign and the letters of k l lac lakh cr crore m.
    validator: RegularExpressionValidator { regularExpression: /^[0-9.,\s\u20b9klacrohem]*$/i }
    background: Rectangle {
      radius: Style.space(8)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, field.activeFocus ? 0.12 : 0.06)
      border.width: field.activeFocus ? 1 : 0
      border.color: Color.accent
    }

    // The value this field last showed. A change from outside (the x on a
    // summary chip, Clear all) must reach the text even while the field has
    // focus; plain typing does not change the filter, so it is left alone.
    property var shown: null
    function syncFromFilter() {
      var v = root.filter[field.which]
      if (v === undefined) v = null
      var want = v === null ? "" : Model.formatGrouped(v)
      if (v !== field.shown) field.shown = v
      else if (field.activeFocus) return
      if (field.text !== want && (!field.activeFocus || v !== field._lastSynced)) field.text = want
      field._lastSynced = v
    }
    property var _lastSynced: null
    function commit() {
      softCommitTimer.stop()
      var parsed = Model.parseAmountInput(field.text)
      if (parsed === 0 && field.which === "min") parsed = null   // "0" = no lower bound
      root.setFilterPart(field.which, parsed)
      field.text = parsed === null ? "" : Model.formatGrouped(parsed)
    }
    // Commit while typing (debounced) without touching the text, so the
    // cursor stays. `shown` and `_lastSynced` are set first so that
    // syncFromFilter sees its own value and leaves the text alone.
    function softCommit() {
      var parsed = Model.parseAmountInput(field.text)
      if (parsed === null && field.text.trim() !== "") return
      if (parsed === 0 && field.which === "min") parsed = null
      var cur = root.filter[field.which]
      if (cur === undefined) cur = null
      if (parsed === cur) return
      field.shown = parsed
      field._lastSynced = parsed
      root.setFilterPart(field.which, parsed)
    }
    Timer {
      id: softCommitTimer
      interval: 400
      onTriggered: field.softCommit()
    }
    onTextEdited: softCommitTimer.restart()
    function step(up, big) {
      var cur = root.filter[field.which]
      if (cur === null || cur === undefined) cur = field.which === "max" ? root.filterBounds.max : 0
      var next = Math.max(0, cur + (up ? 1 : -1) * (big ? 1000 : 100))
      var value = (field.which === "min" && next === 0) ? null : next
      root.setFilterPart(field.which, value)
      field.text = value === null ? "" : Model.formatGrouped(value)
    }

    Component.onCompleted: field.syncFromFilter()
    Connections {
      target: root
      function onFilterChanged() { field.syncFromFilter() }
    }

    onEditingFinished: field.commit()
    Keys.onReturnPressed: function (event) {
      field.commit()
      event.accepted = true
      Qt.callLater(function () { column.forceActiveFocus() })
    }
    Keys.onEnterPressed: function (event) {
      field.commit()
      event.accepted = true
      Qt.callLater(function () { column.forceActiveFocus() })
    }
    Keys.onEscapePressed: function (event) {
      event.accepted = true
      root.filterOpen = false
      Qt.callLater(function () { column.forceActiveFocus() })
    }
  }

  component FilterBar: Column {
    id: bar
    spacing: Style.space(8)

    // The summary strip lists every active part except the search text,
    // which is already visible in the search field.
    // Reassigned only when the list really changes, so typing in the search
    // box does not rebuild the summary chips on every pause.
    property var summary: []
    readonly property int activeCount: bar.summary.length
    readonly property bool anyActive: root.filterChips.length > 0
    readonly property string thisMonth: root.todayIso.slice(0, 7)
    property bool calOpen: false               // the period calendar under the Date row
    property string calMonth: ""               // the month the calendar shows ("YYYY-MM")
    function syncSummary() {
      var next = root.filterChips.filter(function (c) { return c.id !== "q" })
      if (JSON.stringify(next) !== JSON.stringify(bar.summary)) bar.summary = next
    }
    Component.onCompleted: bar.syncSummary()
    Connections {
      target: root
      function onFilterChipsChanged() { bar.syncSummary() }
    }

    function focusSearch() {
      searchInput.forceActiveFocus()
      searchInput.selectAll()
    }

    function stepMonth(dir) {
      var b = root.filterBounds
      var cur = root.filter.month
      if (!b.lastMonth) return
      var next
      if (cur === "" || cur === "30d") next = dir < 0 ? b.lastMonth : ""
      else {
        next = Model.shiftMonth(cur, dir)
        if (next === "") next = dir < 0 ? b.lastMonth : ""
        else if (next > b.lastMonth) next = dir < 0 ? b.lastMonth : ""
        else if (next < b.firstMonth) next = b.firstMonth
      }
      root.setFilterPart("month", next)
    }

    function _inside(source, item, event) {
      if (!item.visible) return false
      var p = source.mapToItem(item, event.x, event.y)
      return p.x >= 0 && p.y >= 0 && p.x < item.width && p.y < item.height
    }

    // The list's wheel area asks here first. True = the wheel was used on an
    // amount field or the month stepper and must not scroll the list.
    function handleWheel(source, event) {
      if (!bar.visible || !root.filterOpen) return false
      var target = bar._inside(source, minField, event) ? minField
        : (bar._inside(source, maxField, event) ? maxField
        : (bar._inside(source, monthStepper, event) ? monthStepper : null))
      if (!target) { bar._wheelAcc = 0; return false }
      // One step per 120 units (a mouse notch). A touchpad sends many small
      // deltas, and phase-end events with a delta of 0, which must not step.
      var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y * 2
      bar._wheelAcc += delta
      if (Math.abs(bar._wheelAcc) < 120) return true
      var up = bar._wheelAcc > 0
      bar._wheelAcc = 0
      var big = (event.modifiers & Qt.ShiftModifier) !== 0
      if (target === monthStepper) bar.stepMonth(up ? 1 : -1)
      else target.step(up, big)
      return true
    }
    property real _wheelAcc: 0

    // Row 1: search + the Filter toggle.
    Item {
      width: bar.width
      height: Style.space(28)

      BorderSurface {
        id: toggle
        anchors.right: parent.right
        height: parent.height
        width: toggleRow.implicitWidth + Style.space(22)
        radius: Style.space(8)
        readonly property bool _hot: toggleMouse.containsMouse || toggle.activeFocus
        readonly property color _activeText: Qt.tint(Color.accent, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75))
        opacity: toggleMouse.pressed ? 0.7 : 1
        color: root.filterOpen || bar.activeCount > 0
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, toggle._hot ? 0.24 : 0.20)
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, toggle._hot ? 0.13 : 0.06)
        borderSpec: toggle.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

        activeFocusOnTab: toggle.visible
        Keys.onReturnPressed: root.filterOpen = !root.filterOpen
        Keys.onEnterPressed: root.filterOpen = !root.filterOpen
        Keys.onSpacePressed: root.filterOpen = !root.filterOpen
        Keys.onDownPressed: root.focusNext(toggle, true)
        Keys.onUpPressed: root.focusNext(toggle, false)
        // Esc collapses an open panel first (it used to close the popup).
        Keys.onEscapePressed: function (event) {
          if (!root.filterOpen) { event.accepted = false; return }
          root.filterOpen = false
          event.accepted = true
        }

        Row {
          id: toggleRow
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            textFormat: Text.PlainText
            text: "󰈳"
            color: bar.activeCount > 0 ? toggle._activeText : root.foreground
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: "Filter"
            color: bar.activeCount > 0 ? toggle._activeText : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: bar.activeCount > 0
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            visible: bar.activeCount > 0
            textFormat: Text.PlainText
            text: String(bar.activeCount)
            color: toggle._activeText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: root.filterOpen ? "▴" : "▾"
            color: root.foreground
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: toggleMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.filterOpen = !root.filterOpen
        }
      }

      TextField {
        id: searchInput
        anchors.left: parent.left
        anchors.right: toggle.left
        anchors.rightMargin: Style.space(6)
        height: parent.height
        placeholderText: "Search merchant or note"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        selectByMouse: true
        leftPadding: Style.space(12)
        background: Rectangle {
          radius: Style.space(8)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, searchInput.activeFocus ? 0.12 : 0.06)
          border.width: searchInput.activeFocus ? 1 : 0
          border.color: Color.accent
        }

        // The text reaches root.filter after a short pause (and on Enter),
        // not on every key, and is never bound back: no binding loop.
        onTextChanged: searchDebounce.restart()
        onEditingFinished: { searchDebounce.stop(); root.setFilterPart("q", searchInput.text) }
        Keys.onReturnPressed: function (event) {
          searchDebounce.stop()
          root.setFilterPart("q", searchInput.text)
          event.accepted = true
          Qt.callLater(function () { column.forceActiveFocus(); root.focusNext(column, true) })
        }
        Keys.onEnterPressed: function (event) {
          searchDebounce.stop()
          root.setFilterPart("q", searchInput.text)
          event.accepted = true
          Qt.callLater(function () { column.forceActiveFocus(); root.focusNext(column, true) })
        }
        Keys.onDownPressed: root.focusNext(searchInput, true)
        // Esc: clear the text, then collapse the panel, then close the popup
        // (the event goes on to the column's own Escape handler).
        Keys.onEscapePressed: function (event) {
          if (searchInput.text !== "") {
            searchDebounce.stop()
            searchInput.text = ""
            root.setFilterPart("q", "")
            event.accepted = true
          } else if (root.filterOpen) {
            root.filterOpen = false
            event.accepted = true
          } else {
            event.accepted = false
          }
        }

        Timer {
          id: searchDebounce
          interval: 150
          onTriggered: root.setFilterPart("q", searchInput.text)
        }
        // Clear all / the x on a chip empty the field from outside.
        Connections {
          target: root
          function onFilterChanged() {
            if (root.filter.q === "" && searchInput.text !== "" && !searchDebounce.running) searchInput.text = ""
          }
        }
      }
    }

    // Row 2: one chip per active part, the count, Clear all.
    Flow {
      width: bar.width
      spacing: Style.space(6)
      visible: bar.anyActive

      Repeater {
        model: bar.summary
        delegate: FilterChip {
          required property var modelData
          label: modelData.label
          active: true
          closable: true
          focusable: false
          tip: "Click or right-click to remove"
          onClicked: { var id = modelData.id; root.clearFilterPart(id) }
          onCleared: { var id = modelData.id; root.clearFilterPart(id) }
        }
      }

      Text {
        height: Style.space(26)
        leftPadding: Style.space(4)
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: root.filteredTransactions.length + " of " + root.transactions.length + " rows"
        color: Qt.darker(root.foreground, 1.2)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextAction {
        label: "Clear all"
        onTriggered: root.clearAllFilters()
      }
    }

    // The expanded panel: four labelled rows, a caption column on the left
    // and chips on the right, with room between the rows.
    Column {
      id: panel
      width: bar.width
      spacing: Style.space(12)
      topPadding: Style.space(6)
      bottomPadding: Style.space(4)
      visible: root.filterOpen

      readonly property real captionWidth: Style.space(46)

      // Accounts, sorted by bank. Short and the same length: the logo and the
      // last four digits; the full name is in the tooltip. Alt+1..6 toggle the first six.
      Row {
        spacing: Style.space(8)
        Text {
          width: panel.captionWidth
          height: Style.space(26)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "Account"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Flow {
          width: panel.width - panel.captionWidth - Style.space(8)
          spacing: Style.space(6)

          Repeater {
            model: root.accountChipOptions
            delegate: FilterChip {
              required property var modelData
              required property int index
              label: ((modelData.label.match(/(\d{4})\s*$/) || ["", modelData.label])[1])
              bank: modelData.accountType === "checking" ? modelData.bank : ""
              network: modelData.network || ""
              active: root.filter.accounts.indexOf(modelData.key) !== -1
              tip: modelData.label + (index < 6 ? "  ·  Alt+" + (index + 1) : "")
              onClicked: { var key = modelData.key; root.toggleAccountFilter(key) }
              onCleared: {
                var key = modelData.key
                if (root.filter.accounts.indexOf(key) !== -1) root.toggleAccountFilter(key)
              }
            }
          }
        }
      }

      // Direction and the cycling chips.
      Row {
        spacing: Style.space(8)
        Text {
          width: panel.captionWidth
          height: Style.space(26)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "Show"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Flow {
          width: panel.width - panel.captionWidth - Style.space(8)
          spacing: Style.space(6)

          FilterChip {
            label: "In"
            active: root.filter.dir === "in"
            onClicked: root.setFilterPart("dir", root.filter.dir === "in" ? "any" : "in")
            onCleared: root.setFilterPart("dir", "any")
          }
          FilterChip {
            label: "Out"
            active: root.filter.dir === "out"
            onClicked: root.setFilterPart("dir", root.filter.dir === "out" ? "any" : "out")
            onCleared: root.setFilterPart("dir", "any")
          }
          FilterChip {
            label: root.filter.tracked === "untracked" ? "Not tracked" : "Tracked"
            active: root.filter.tracked !== "any"
            tip: "Click cycles any, tracked, not tracked"
            onClicked: root.cycleFilterPart("tracked", ["any", "tracked", "untracked"])
            onCleared: root.setFilterPart("tracked", "any")
          }
          FilterChip {
            label: root.filter.transfers === "hide" ? "No transfers" : (root.filter.transfers === "only" ? "Transfers only" : "Transfers")
            active: root.filter.transfers !== "any"
            tip: "Click cycles any, only, hide"
            onClicked: root.cycleFilterPart("transfers", ["any", "only", "hide"])
            onCleared: root.setFilterPart("transfers", "any")
          }
          FilterChip {
            label: root.filter.pending === "hide" ? "Settled only" : "Pending"
            active: root.filter.pending !== "any"
            tip: "Click cycles any, pending only, settled only"
            onClicked: root.cycleFilterPart("pending", ["any", "only", "hide"])
            onCleared: root.setFilterPart("pending", "any")
          }
          FilterChip {
            visible: store.receipts.length > 0 || root.filter.bill !== "any"
            label: root.filter.bill === "none" ? "No bill" : (root.filter.bill === "has" ? "Has bill" : "Bill")
            active: root.filter.bill !== "any"
            tip: "Click cycles any, has bill, no bill"
            onClicked: root.cycleFilterPart("bill", ["any", "has", "none"])
            onCleared: root.setFilterPart("bill", "any")
          }
          FilterChip {
            label: root.filter.refund === "needs" ? "Needs refund link" : "Refunds"
            active: !!root.filter.refund && root.filter.refund !== "any"
            tip: "Click cycles any, refunds, credits that still need a link"
            onClicked: root.cycleFilterPart("refund", ["any", "linked", "needs"])
            onCleared: root.setFilterPart("refund", "any")
          }
        }
      }

      // Amount range.
      Row {
        spacing: Style.space(8)
        Text {
          width: panel.captionWidth
          height: Style.space(28)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "Amount"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Row {
          spacing: Style.space(8)
          FilterAmountField { id: minField; which: "min"; placeholderText: "Min" }
          Text {
            height: Style.space(28)
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: "to"
            color: Qt.darker(root.foreground, 1.2)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          FilterAmountField {
            id: maxField
            which: "max"
            placeholderText: root.filterBounds.max > 0 ? Model.formatGrouped(root.filterBounds.max) : "Max"
          }
        }
      }

      // Date: a month stepper and three shortcuts.
      Row {
        spacing: Style.space(8)
        Text {
          width: panel.captionWidth
          height: Style.space(26)
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "Date"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Flow {
          width: panel.width - panel.captionWidth - Style.space(8)
          spacing: Style.space(6)

          Row {
            id: monthStepper
            spacing: Style.space(2)
            FilterChip {
              label: "‹"
              tip: "Earlier month (wheel)"
              onClicked: bar.stepMonth(-1)
              onCleared: root.setFilterPart("month", "")
            }
            Text {
              height: Style.space(26)
              width: Style.space(88)
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: root.filter.month === "" ? "All months" : (root.filter.month === "30d" ? "Last 30 days" : Model.monthLabel(root.filter.month))
              color: root.filter.month === "" ? Qt.darker(root.foreground, 1.2) : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: root.filter.month !== ""
            }
            FilterChip {
              label: "›"
              tip: "Later month (wheel)"
              onClicked: bar.stepMonth(1)
              onCleared: root.setFilterPart("month", "")
            }
          }
          FilterChip {
            label: "30d"
            active: root.filter.month === "30d"
            onClicked: root.setFilterPart("month", root.filter.month === "30d" ? "" : "30d")
            onCleared: root.setFilterPart("month", "")
          }
          FilterChip {
            label: "This month"
            active: root.filter.month === bar.thisMonth
            onClicked: root.setFilterPart("month", root.filter.month === bar.thisMonth ? "" : bar.thisMonth)
            onCleared: root.setFilterPart("month", "")
          }
          FilterChip {
            readonly property bool hasPeriod: !!(root.filter.from || root.filter.to)
            label: hasPeriod ? Model.periodLabel(root.filter.from, root.filter.to) : "Period…"
            tip: "Pick a first and a last day in a calendar"
            active: hasPeriod || bar.calOpen
            onClicked: {
              if (!bar.calOpen) bar.calMonth = (root.filter.from || root.filter.to || root.todayIso).slice(0, 7)
              bar.calOpen = !bar.calOpen
            }
            onCleared: { root.filter = Model.filterWithPeriod(root.filter, "", ""); bar.calOpen = false }
          }
        }
      }

      // Period: a click picks the first day, the next click the last day (a third starts again).
      Item {
        visible: bar.calOpen
        width: panel.width
        height: visible ? calCol.implicitHeight : 0
        Column {
          id: calCol
          x: panel.captionWidth + Style.space(8)
          width: Math.min(panel.width - x, Style.space(7 * 34))
          spacing: Style.space(4)
          Item {
            width: parent.width
            height: Style.space(26)
            FilterChip {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              label: "‹"
              tip: "Earlier month"
              onClicked: bar.calMonth = Model.shiftMonth(bar.calMonth, -1)
            }
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: Model.monthLabel(bar.calMonth)
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            FilterChip {
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              label: "›"
              tip: "Later month"
              onClicked: bar.calMonth = Model.shiftMonth(bar.calMonth, 1)
            }
          }
          Grid {
            columns: 7
            Repeater {
              model: ["M", "T", "W", "T", "F", "S", "S"]
              delegate: Text {
                required property string modelData
                width: calCol.width / 7
                height: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: modelData
                color: Qt.darker(root.foreground, 1.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Repeater {
              model: bar.calOpen ? Model.calendarCells(bar.calMonth) : []
              delegate: Rectangle {
                id: calDay
                required property var modelData
                readonly property bool edge: modelData.iso === root.filter.from || modelData.iso === root.filter.to
                readonly property bool inside: !!(root.filter.from && root.filter.to)
                  && modelData.iso > root.filter.from && modelData.iso < root.filter.to
                width: calCol.width / 7
                height: Style.space(26)
                radius: Style.space(6)
                color: calDay.edge ? Util.alpha(Color.accent, 0.55)
                  : (calDay.inside ? Util.alpha(Color.accent, 0.18) : (calDayHover.hovered ? Util.alpha(root.foreground, 0.08) : "transparent"))
                HoverHandler { id: calDayHover }
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: calDay.modelData.day
                  color: calDay.modelData.inMonth ? root.foreground : Qt.darker(root.foreground, 2.2)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: calDay.modelData.iso === root.todayIso || calDay.edge
                  font.underline: calDay.modelData.iso === root.todayIso
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var p = Model.periodPick(root.filter.from, root.filter.to, calDay.modelData.iso)
                    root.filter = Model.filterWithPeriod(root.filter, p.from, p.to)
                  }
                }
              }
            }
          }
          Item {
            width: parent.width
            height: Style.space(24)
            Text {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              textFormat: Text.PlainText
              text: root.filter.from && !root.filter.to ? "Now pick the last day"
                : (root.filter.from || root.filter.to ? Model.periodLabel(root.filter.from, root.filter.to) : "Pick the first day")
              color: Qt.darker(root.foreground, 1.2)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Row {
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: Style.space(6)
              FilterChip {
                visible: !!(root.filter.from || root.filter.to)
                label: "Clear"
                onClicked: root.filter = Model.filterWithPeriod(root.filter, "", "")
              }
              FilterChip { label: "Done"; onClicked: bar.calOpen = false }
            }
          }
        }
      }

      // One quiet line: the count on the left, the way out on the right.
      Item {
        width: panel.width
        height: Style.space(18)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.filteredTransactions.length + " of " + root.transactions.length + " rows shown"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Esc to close"
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
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
    // animation, to make scrolling faster or slower. 5 = ~300 px a notch.
    property real speed: 5.0
    property double _lastWheel: 0
    // Optional function(source, event) -> bool. True = it used the wheel.
    property var interceptWheel: null

    acceptedButtons: Qt.NoButton

    NumberAnimation {
      id: scrollAnim
      target: scrollWheel.target
      property: "contentY"
      duration: 240
      easing.type: Easing.OutQuart
    }

    onWheel: function (event) {
      if (scrollWheel.interceptWheel && scrollWheel.interceptWheel(scrollWheel, event)) {
        event.accepted = true
        return
      }
      // A touchpad reports smooth scrolling via pixelDelta (already real
      // pixels); angleDelta.y (eighths of a degree, 120 per notch on a
      // normal mouse wheel) is normalised against the same ~60px-per-
      // notch baseline browsers use, so both input types land in the same
      // speed scale.
      var touchpad = event.pixelDelta.y !== 0
      var raw = touchpad ? event.pixelDelta.y : (event.angleDelta.y / 120) * 60
      if (raw !== 0) {
        var now = Date.now()
        // A wheel spun quickly keeps speeding up (up to 2x), the way a long
        // scroll should; a single notch stays precise.
        var gain = (!touchpad && now - scrollWheel._lastWheel < 90) ? 2.0 : 1.0
        scrollWheel._lastWheel = now
        var t = scrollWheel.target
        var maxY = Math.max(0, t.contentHeight - t.height)
        // Continue from where the running glide is headed, not from where it
        // happens to be this frame: notches that arrive mid-glide add up
        // instead of each restarting from a half-finished position (that
        // lost most of a fast spin and made the page stutter).
        var base = scrollAnim.running ? scrollAnim.to : t.contentY
        var y = Math.max(0, Math.min(maxY, base - raw * scrollWheel.speed * gain))
        scrollAnim.duration = touchpad ? 90 : 240
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
      // Long enough for any window width; the Item clips it. (120 stopped short of the right edge on a wide window.)
      text: (fsRule.doubled ? "=" : "-").repeat(600)
      elide: Text.ElideNone
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
  // must be a real one (02-Nov-26, 02/11/26 and similar) or the box stays red and
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
    readonly property bool invalid: ie.editing
      && ((ie.fieldName === "date" && Model.parseReceiptDate(input.text) === null)
          || (ie.fieldName === "time" && Model.parseReceiptTime(input.text) === null))
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
        if (name === "time") typed = Model.parseReceiptTime(typed)
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

    ScrollWheelArea { anchors.fill: sbFlick; target: sbFlick }

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
    property string feeField: "amount" // which of the fee's fields the value is (amount / original)
    property bool struck: false       // the value is drawn struck through (a waived charge's original)
    property bool free: false         // a green FREE follows the value
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
          width: ef.big ? Style.space(170) : (ef.ledger ? Style.space(120) : Style.space(76))
          textFormat: Text.PlainText
          text: ef.label
          color: ef.big ? root.foreground : Qt.darker(root.foreground, 1.4)
          font.family: ef.ledger ? "monospace" : Style.font.family
          font.bold: ef.big
          font.pixelSize: ef.big ? Style.font.body : Style.font.caption
        }

        Text {
          visible: !ef.editing
          width: parent.width - efLabel.width - parent.spacing - (ef.free ? freeBadge.width + parent.spacing : 0)
          textFormat: Text.PlainText
          horizontalAlignment: ef.ledger ? Text.AlignRight : Text.AlignLeft
          font.strikeout: ef.struck
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

        Text {
          id: freeBadge
          visible: ef.free && !ef.editing
          textFormat: Text.PlainText
          text: "FREE"
          color: root.creditColor
          font.family: "monospace"
          font.bold: true
          font.pixelSize: Style.font.caption
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
            var feeName = ef.feeField
            var typed = text
            var changed = text.trim() !== (ef.value || "").trim()
            // Dates are shown DD-Mmm-YY but stored ISO; a discount is
            // always a positive amount taken off, whatever sign the bill
            // printed it with.
            if (name === "date") typed = Model.parseReceiptDate(text)
            if (name === "time") typed = Model.parseReceiptTime(text)
            if (name === "discount") typed = text.replace(/^\s*-/, "")
            ef.editing = false
            ef.finished()
            if (!changed) return
            if (fee !== null) st.editReceiptFee(rid, fee, feeName, typed)
            else if (rate !== null) st.editReceiptTaxField(rid, rate, name, typed)
            else st.editReceiptField(rid, name, typed)
          }
        }
      }

      Text {
        id: efError
        visible: ef.invalid
        textFormat: Text.PlainText
        text: ef.badDate ? "Date needs a form like 25-Jun-26 or 25/06/26" : ef.label + " needs a plain number"
        color: root.debitColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------------------------------
  // Cashew verify window: a layer-shell surface like receiptFullScreen. Left,
  // the drafts to check and edit; right, the links built from them. Nothing
  // is marked tracked until the user says so.
  PanelWindow {
    id: cashewWin
    visible: root.cashewOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-transactions-cashew"
    WlrLayershell.layer: WlrLayer.Overlay
    // NOT Exclusive (confirmed live, 2026-11-12): Exclusive keyboard focus
    // makes Hyprland close this whole layer surface - killing an in-flight
    // AI guess run and resetting all state - the instant ANY other window
    // becomes active (even just this machine's own terminal regaining
    // focus for a second). A guess run against a realistic row count takes
    // several minutes; expecting zero focus changes anywhere on the desktop
    // for that whole time is not realistic. OnDemand still gives this
    // window real keyboard focus (the "N" shortcut, text fields, Escape)
    // whenever it's the active surface, it just doesn't get force-closed
    // the moment focus moves elsewhere.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    // Minimised: only the small card takes the pointer; clicks elsewhere reach the windows below.
    property Region miniMask: Region { item: cashewMini }
    mask: cashewWin.compact ? cashewWin.miniMask : null

    // The in-card picker: "" (closed), "category" or "account".
    property string pickKind: ""
    property int pickIdx: -1
    property string pickMain: ""
    property bool pickRemember: true
    // Starts collapsed: links are logically step 2, after categorising, so
    // the pane doesn't compete with the categorisation work for ~40% of the
    // card width before there is anything to copy yet (audit: LINKS pane
    // dominance). Not reset on reopen (see onVisibleChanged below), so a
    // user's own choice to expand it still carries across reopens.
    property bool linksCollapsed: true
    property bool confirmMark: false
    property bool oldestFirst: false
    property bool optionsOpen: false          // the Options row; persists across reopens
    property bool needOnly: false             // the list shows only rows with no category; persists across reopens
    // Minimised: a small card in the corner with only what the sending step needs (totals, Send all, the
    // links, Mark as tracked). The rest of the screen stays usable (see `mask`). Reset on every open.
    property bool compact: false
    property bool warnOpen: false             // the warnings list shows every line, not the first five
    property bool leftOnly: true              // during and after a send the list hides the rows Cashew has
    property var visRows: []                  // the rows the list shows (syncRows), for the day checkboxes
    readonly property var rowStates: Model.cashewSendRowStates(root.cashewSendItems, root.cashewSendDone, root.cashewSendPhase)
    property var rowIdxs: []                  // draft indexes of the rows the list shows (set by syncRows)
    readonly property string selectState: Model.cashewSelectState(root.cashewDrafts, cashewWin.rowIdxs)
    readonly property var selection: Model.cashewSelectionSummary(root.cashewDrafts, cashewWin.rowIdxs)
    // "Look": how every shown row leaves (which link, a transfer page, not sent), from the built links.
    readonly property var fates: Model.cashewRowFates(root.cashewDrafts, root.cashewShown,
      { links: root.cashewLinks, transfers: root.cashewTransfers })
    property bool askActive: false            // the ask-me sequence is running
    // The guess results panel (an in-card overlay).
    property bool resultsOpen: false
    property bool resultsRaw: false
    property string resultsFilter: "all"      // all | guessed | none
    property int flashIdx: -1
    readonly property var catMap: Model.cashewCategoryMap(root.cashewCategories)
    readonly property var dayTotals: Model.cashewDayTotals(root.cashewDrafts, root.cashewShown)
    readonly property color muted: Qt.darker(root.foreground, 1.2)
    readonly property var pickDraft: cashewWin.pickIdx >= 0 ? (root.cashewDrafts[cashewWin.pickIdx] || ({})) : ({})
    readonly property var pickCats: cashewWin.pickKind === "category"
      ? Model.cashewCategoriesFor(root.cashewCategories, cashewWin.pickDraft.amount) : []
    readonly property var pickSubs: {
      for (var i = 0; i < cashewWin.pickCats.length; i++)
        if (cashewWin.pickCats[i].name === cashewWin.pickMain) return cashewWin.pickCats[i].subcategories || []
      return []
    }

    onVisibleChanged: {
      // optionsOpen and needOnly are deliberately NOT reset here any more —
      // they are plain view preferences (which filter row is showing), cheap
      // to keep, and resetting them every reopen was pure friction (audit:
      // "nothing persists across a close/reopen"). Everything else below is
      // tied to a specific in-progress interaction (a picker, a confirm, the
      // ask-sequence, the results overlay) and still resets, since those
      // reference draft rows that get reloaded fresh on every open.
      cashewWin.pickKind = ""
      cashewWin.confirmMark = false
      cashewWin.resultsOpen = false
      cashewWin.resultsRaw = false
      cashewWin.askActive = false
      cashewWin.compact = false
      // Closing this window (Close button, Escape, backdrop click) no
      // longer stops a running guess - it keeps going in the background
      // and its results are there waiting the next time the window opens.
      // Only the explicit "Stop" button (cashewGuessStop, next to the "AI
      // categories" button) actually cancels it: a close is "get this out
      // of my way for now", not "cancel what I started", and conflating
      // the two is also what made an incidental compositor visibility blip
      // (see below) kill a multi-minute run by accident in the first
      // place - fixed 2026-11-12.
      if (cashewWin.visible) {
        // Skip the reload while a guess is actively running: becoming
        // visible again, whether from a real reopen or the compositor
        // transiently remapping this Overlay layer surface (confirmed
        // live: happens on an unrelated window becoming active, even with
        // keyboardFocus set to OnDemand rather than Exclusive), must not
        // wipe the in-progress guess log/drafts out from under it.
        // Reload only after a real close (cashewStale), never because the compositor
        // remapped the layer while the window stayed open: that wiped the guessed
        // categories and sent the screen back to the start once a run had finished.
        if (root.cashewGuessing) root.cashewStale = false
        else if (root.cashewStale) { root.cashewStale = false; console.log("cashew: reload after close"); root.cashewLoad() }
        cashewCard.forceActiveFocus()
      }
    }

    // The list rows, in day order. Only a new set of shown rows, a date edit or
    // the order toggle rebuilds it; every other edit keeps the delegates.
    ListModel { id: cwRows }
    function syncRows() {
      var hide = null
      if (cashewWin.leftOnly && root.cashewSendPhase !== "") {
        hide = ({})
        Object.keys(cashewWin.rowStates).forEach(function (id) { if (cashewWin.rowStates[id] === "added") hide[id] = true })
      }
      var rows = Model.cashewVisibleRows(root.cashewDrafts, root.cashewShown,
        { newestFirst: !cashewWin.oldestFirst, needOnly: cashewWin.needOnly, guessedOnly: root.cashewGuessedOnly, hideIds: hide })
      cashewWin.visRows = rows
      cashewWin.rowIdxs = Model.cashewRowIdxs(rows)
      cwRows.clear()
      for (var i = 0; i < rows.length; i++) cwRows.append(rows[i])
    }
    onCompactChanged: if (cashewWin.visible) (cashewWin.compact ? cashewMini : cashewCard).forceActiveFocus()
    onOldestFirstChanged: cashewWin.syncRows()
    onLeftOnlyChanged: cashewWin.syncRows()
    onRowStatesChanged: if (cashewWin.leftOnly) cashewWin.syncRows()
    onNeedOnlyChanged: cashewWin.syncRows()
    Connections {
      target: root
      function onCashewShownChanged() { cashewWin.syncRows() }
      function onCashewGuessedOnlyChanged() { cashewWin.syncRows() }
      function onCashewGuessLogChanged() { if (cashewWin.resultsOpen) cashewWin.syncGuessRows() }
      function onCashewDraftsChanged() { if (cashewWin.resultsOpen) cashewWin.syncGuessRows() }
      function onCashewGuessedCountChanged() {
        // Accepting/reverting every guess can empty this filter outright (same
        // as needOnly below): turn it off instead of leaving a silent blank list.
        if (!root.cashewGuessedOnly) return
        if (root.cashewGuessedCount === 0) root.cashewGuessedOnly = false   // its change handler syncs
        else cashewWin.syncRows()
      }
      function onCashewNeedCountChanged() {
        if (!cashewWin.needOnly) return
        if (root.cashewNeedCount === 0) cashewWin.needOnly = false   // its change handler syncs
        else cashewWin.syncRows()
      }
    }

    onResultsOpenChanged: if (cashewWin.resultsOpen) cashewWin.syncGuessRows()
    onResultsFilterChanged: cashewWin.syncGuessRows()
    ListModel { id: cgRows }
    Timer { id: cwFlashTimer; interval: 1600; onTriggered: cashewWin.flashIdx = -1 }
    // Brings cgRows up to date in place, so the rows and the scroll stay while a run adds results.
    function syncGuessRows() {
      var view = Model.cashewGuessLogView(root.cashewGuessLog, root.cashewDrafts, cashewWin.resultsFilter)
      var n = Math.min(view.length, cgRows.count)
      var prefix = cgRows.count <= view.length
      for (var i = 0; prefix && i < n; i++) if (cgRows.get(i).gid !== view[i].gid) prefix = false
      if (!prefix) { cgRows.clear(); n = 0; cgList.positionViewAtBeginning() }
      for (var j = 0; j < n; j++) {
        var cur = cgRows.get(j)
        if (cur.st !== view[j].st || cur.guessCat !== view[j].guessCat || cur.idx !== view[j].idx) cgRows.set(j, view[j])
      }
      for (var k = n; k < view.length; k++) cgRows.append(view[k])
    }
    // Scrolls the list to draft `idx` and marks it for a moment.
    function scrollToRow(idx) {
      for (var i = 0; i < cwRows.count; i++) {
        var r = cwRows.get(i)
        if (r.idx === idx || r.partner === idx) {
          cwList.positionViewAtIndex(i, ListView.Center)
          cashewWin.flashIdx = r.idx
          cwFlashTimer.restart()
          return
        }
      }
    }
    function revealRow(idx) {
      cashewWin.resultsOpen = false
      cashewWin.scrollToRow(idx)
    }
    // Ask-me flow: jump to the next row that has no category and open its picker.
    // `from` is the draft index just done (-1 = from the top). Ends when none is left.
    function askNext(from) {
      var order = []
      for (var i = 0; i < cwRows.count; i++) { var r = cwRows.get(i); order.push({ idx: r.idx, partner: r.partner }) }
      var idx = Model.cashewNextNeed(root.cashewDrafts, order, from)
      if (idx < 0 || idx === from) { cashewWin.askActive = false; return }
      cashewWin.resultsOpen = false
      cashewWin.scrollToRow(idx)
      cashewWin.openPicker("category", idx)
      cashewWin.askActive = true
    }
    function askStart() {
      if (root.cashewNeedCount === 0 || root.cashewLoading) return
      if (root.cashewGuessedOnly) root.cashewGuessedOnly = false   // would hide the rows to ask
      cashewWin.askNext(-1)
    }
    function openPicker(kind, idx) {
      var d = root.cashewDrafts[idx]
      if (!d) return
      cashewWin.pickIdx = idx
      cashewWin.pickRemember = true
      cashewWin.pickMain = d.category || ""
      cashewWin.pickKind = kind
    }
    // Reads the text first: closing the picker destroys the editor.
    function saveNote(text) {
      var idx = cashewWin.pickIdx
      var next = Model.cashewPatch(root.cashewDrafts, idx, { notes: String(text).replace(/\r/g, "").trim() })
      cashewWin.closePicker()
      root.cashewEdit(next, true)
    }
    function closePicker() {
      cashewWin.askActive = false
      cashewWin.pickKind = ""
      cashewCard.forceActiveFocus()
    }
    // Reads the draft first: the edit replaces the array the picker reads from.
    function pickCategory(category, sub) {
      var idx = cashewWin.pickIdx
      var d = root.cashewDrafts[idx]
      if (!d) return
      var key = d.groupKey
      var remember = cashewWin.pickRemember && d.kind !== "transfer" && category !== "Uncategorized"
      var next = Model.cashewApplyCategory(root.cashewDrafts, idx, category, sub, remember)
      var st = remember ? Model.cashewRememberCategory(root.cashewState, key, category, sub) : null
      // A category set on this row's own bill beats the payee-wide answer, so remember it on the row too.
      if (d.fromBill && category !== "Uncategorized") st = Model.cashewPinCategory(st || root.cashewState, d.id, category, sub)
      var again = cashewWin.askActive
      cashewWin.closePicker()
      root.cashewEdit(next)
      if (st) root.cashewSetState(st)
      if (again) Qt.callLater(function () { cashewWin.askNext(idx) })
    }
    function pickAccount(name) {
      var idx = cashewWin.pickIdx
      var d = root.cashewDrafts[idx]
      if (!d) return
      var spread = cashewWin.pickRemember
      var accountId = d.accountId
      var next = Model.cashewApplyAccount(root.cashewDrafts, idx, name, spread)
      var st = spread ? Model.cashewRememberAccount(root.cashewState, accountId, name) : null
      cashewWin.closePicker()
      root.cashewEdit(next)
      if (st) root.cashewSetState(st)
    }
    function markTracked() {
      var rows = Model.cashewIncluded(root.cashewDrafts, root.cashewShown)
      var st = store
      cashewWin.confirmMark = false
      st.setTrackedMany(rows, true)
      root.closeCashew()
    }

    Rectangle {
      visible: !cashewWin.compact
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)
      MouseArea { anchors.fill: parent; onClicked: root.closeCashew() }
    }

    // ---- minimised: what is left, the one action, and the model runs. Drag it anywhere.
    Item {
      id: cashewMini
      visible: cashewWin.compact
      width: Style.space(300)
      height: cwMiniCol.implicitHeight + Style.space(24)
      x: root.miniX >= 0 ? Math.max(0, Math.min(root.miniX, parent.width - width)) : parent.width - width - Style.space(24)
      y: root.miniY >= 0 ? Math.max(0, Math.min(root.miniY, parent.height - height)) : parent.height - height - Style.space(24)
      focus: cashewWin.compact
      Keys.onEscapePressed: function (event) { cashewWin.compact = false; event.accepted = true }

      BorderSurface {
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.none()
        radius: Style.cornerRadius
      }
      // Drag from anywhere on the card; the place is kept (also for the receipt card).
      DragHandler {
        id: cwMiniDrag
        target: null
        property real sx: 0
        property real sy: 0
        onActiveChanged: if (active) { sx = cashewMini.x; sy = cashewMini.y }
        onActiveTranslationChanged: if (active) root.saveMiniPos(sx + activeTranslation.x, sy + activeTranslation.y)
      }
      HoverHandler { cursorShape: cwMiniDrag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor }

      Column {
        id: cwMiniCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
        spacing: Style.space(8)

        Item {
          width: parent.width
          height: Style.space(24)
          Text {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            text: "⠿  Cashew"
            color: cashewWin.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: Style.space(4)
            PanelActionButton {
              size: Style.space(24)
              iconText: "󰖯"
              tooltipText: "Expand (Esc)"
              foreground: root.foreground
              onClicked: cashewWin.compact = false
            }
            PanelActionButton {
              size: Style.space(24)
              iconText: "x"
              tooltipText: "Close"
              foreground: root.foreground
              onClicked: root.closeCashew()
            }
          }
        }

        // The two numbers: rows waiting in the sync file, and rows waiting for a category.
        Row {
          spacing: Style.space(22)
          Repeater {
            model: [
              { n: Math.max(0, root.cashewSync.pending), what: root.cashewSync.pending === 1 ? "row to import" : "rows to import" },
              { n: Math.max(0, root.cashewSync.waitingCategory), what: "need a category" }
            ]
            delegate: Column {
              required property var modelData
              spacing: 0
              Text {
                textFormat: Text.PlainText
                text: String(modelData.n)
                color: modelData.n === 0 ? root.creditColor : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body + 10
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.what
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        LlmStatus { width: parent.width }

        CashewBtn {
          label: root.cashewSyncLabel
          primary: root.cashewSync.pending > 0
          onClicked: root.cashewSyncClick()
        }
      }
    }

    Item {
      id: cashewCard
      visible: !cashewWin.compact
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(1280))
      height: Math.min(parent.height - Style.space(80), Style.space(900))
      focus: !cashewWin.compact
      Keys.onPressed: function (event) {
        // N: categorise the next row. A text field takes the key first, so this
        // only runs when no field has the focus.
        if (event.key === Qt.Key_N && event.modifiers === Qt.NoModifier && cashewWin.pickKind === "") {
          cashewWin.askStart()
          event.accepted = true
        }
      }
      Keys.onEscapePressed: function (event) {
        cashewWin.askActive = false
        if (cashewWin.pickKind !== "") cashewWin.closePicker()
        else if (cashewWin.resultsOpen && root.cashewGuessedCount === 0) cashewWin.resultsOpen = false
        else root.closeCashew()
        event.accepted = true
      }

      MouseArea { anchors.fill: parent; onClicked: {} }

      BorderSurface {
        anchors.fill: parent
        color: Color.popups.background
        borderSpec: Border.none()
        radius: Style.cornerRadius
      }

      // ---- header
      Item {
        id: cwHeader
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Style.space(16) }
        height: Style.space(30)

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Cashew links"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.cashewGuessError !== "" ? root.cashewGuessError
              : (root.cashewSending || root.cashewSendPaused) ? root.cashewSendNote
              : root.cashewGuessing ? Model.cashewGuessProgressText(root.cashewGuessProgress, root.cashewGuessDone, root.cashewGuessTotal)
              : root.cashewGuessedCount > 0 ? "✦ " + root.cashewGuessedCount + " AI categories wait for your confirmation"
              : root.cashewGuessDoneLine !== "" ? root.cashewGuessDoneLine
              : root.cashewShown.length + " rows  ·  " + (root.cashewNeedCount > 0 ? root.cashewNeedCount + " need a category" : "all categorised")
            color: root.cashewGuessError !== "" ? root.debitColor : cashewWin.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // "Needs category" and the AI guess trigger moved down to the left
        // pane's title row, next to "Categorise next" — so the two ways to
        // categorise sit side by side instead of one living in the header
        // and the other in the list below (audit: disconnected flows). Only
        // one "Results" affordance is kept (was duplicated here and in
        // Options, with two different labels for the same panel).
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          CashewBtn {
            visible: root.cashewGuessLog.length > 0
            label: "Results  ·  " + root.cashewGuessCounts.guessed + " guessed / " + root.cashewGuessCounts.sent + " sent"
            active: cashewWin.resultsOpen
            onClicked: if (root.cashewGuessedCount === 0) cashewWin.resultsOpen = !cashewWin.resultsOpen
            else cashewWin.resultsOpen = true
          }
          CashewBtn {
            label: root.cashewSyncLabel
            primary: root.cashewSync.pending > 0
            onClicked: root.cashewSyncClick()
          }
          CashewBtn { label: cashewWin.optionsOpen ? "Options ▴" : "Options ▾"; active: cashewWin.optionsOpen; onClicked: cashewWin.optionsOpen = !cashewWin.optionsOpen }
          CashewBtn { label: "Minimise"; onClicked: { cashewWin.pickKind = ""; cashewWin.askActive = false; cashewWin.compact = true } }
          CashewBtn { label: "Close"; onClicked: root.closeCashew() }
        }
      }

      // ---- options (collapsed by default)
      Item {
        id: cwOptions
        visible: cashewWin.optionsOpen
        anchors { top: cwHeader.bottom; left: parent.left; right: cwRight.left; margins: Style.space(16) }
        anchors.topMargin: cashewWin.optionsOpen ? Style.space(10) : 0
        anchors.rightMargin: Style.space(12)
        height: cashewWin.optionsOpen ? cwOptionsRow.implicitHeight : 0

        Flow {
          id: cwOptionsRow
          width: parent.width
          spacing: Style.space(6)
          CashewBtn { label: "Oldest first"; active: cashewWin.oldestFirst; onClicked: cashewWin.oldestFirst = !cashewWin.oldestFirst }
          CashewBtn {
            label: root.cashewAutoTrack ? "After adding: mark as tracked" : "After adding: keep untracked"
            active: root.cashewAutoTrack
            onClicked: root.cashewSetState(Object.assign({}, root.cashewState, { autoTrack: !root.cashewAutoTrack }))
          }
          CashewBtn {
            // EXPERIMENTAL: txdb cashew-sync writes straight into Zen's storage while Zen is closed (backup first)
            label: root.cashewState.directSync === true ? "Write into Cashew while Zen is closed: on" : "Write into Cashew while Zen is closed: off"
            active: root.cashewState.directSync === true
            onClicked: {
              root.cashewSetState(Object.assign({}, root.cashewState, { directSync: root.cashewState.directSync !== true }))
              root.flushCashewSave()
              cashewSyncTimer.restart()
            }
          }
          CashewBtn {
            label: root.cashewAutoGuess ? "AI for remarks: on" : "AI for remarks: off"
            active: root.cashewAutoGuess
            onClicked: root.cashewSetState(Object.assign({}, root.cashewState, { autoGuess: !root.cashewAutoGuess }))
          }
          CashewBtn {
            label: "Guessed only"
            active: root.cashewGuessedOnly
            enabled: root.cashewGuessedOnly || root.cashewGuessedCount > 0
            onClicked: root.cashewGuessedOnly = !root.cashewGuessedOnly
          }
          CashewBtn {
            visible: root.cashewGuessedCount > 0
            label: "Accept guesses  ·  " + root.cashewGuessedCount
            onClicked: root.cashewAcceptGuesses()
          }
        }
      }

      // ---- the same filter bar as the main list (search, accounts, direction, month,
      // amount range, bill, pending, tracked). It is the SAME filter (root.filter), so what
      // is set here is what the main list shows, and the table below follows it.
      Item {
        id: cwFilterHost
        anchors { top: cwOptions.bottom; left: parent.left; right: cwRight.left; margins: Style.space(16) }
        anchors.topMargin: Style.space(10)
        anchors.rightMargin: Style.space(12)
        height: cwFilterBar.implicitHeight
        FilterBar {
          id: cwFilterBar
          width: parent.width
        }
      }

      // ---- three-step hint above the right pane (visual only)
      Row {
        id: cwHint
        visible: !cashewWin.linksCollapsed
        anchors { top: cwHeader.bottom; right: parent.right; rightMargin: Style.space(16); topMargin: Style.space(10) }
        height: cashewWin.linksCollapsed ? 0 : Style.space(18)
        spacing: Style.space(6)
        Repeater {
          model: ["1 Categorise (manual or AI)", "›", "2 Copy the links", "›", "3 Mark as tracked"]
          delegate: Text {
            required property string modelData
            required property int index
            textFormat: Text.PlainText
            text: modelData
            color: index === 0 && root.cashewNeedCount === 0 ? root.creditColor : cashewWin.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: index === 0 && root.cashewNeedCount === 0
          }
        }
      }

      // ---- right pane: links
      Rectangle {
        id: cwRight
        anchors { top: cwHint.bottom; bottom: parent.bottom; right: parent.right; margins: Style.space(16) }
        anchors.topMargin: Style.space(8)
        width: cashewWin.linksCollapsed ? Style.space(40) : Math.round((cashewCard.width - Style.space(48)) * 0.4)
        radius: Style.space(10)
        color: Util.alpha(root.foreground, 0.05)

        CashewBtn {
          id: cwChevron
          anchors { top: parent.top; right: parent.right; margins: Style.space(6) }
          label: cashewWin.linksCollapsed ? "‹" : "›"
          width: Style.space(28)
          onClicked: cashewWin.linksCollapsed = !cashewWin.linksCollapsed
        }

        Text {
          visible: !cashewWin.linksCollapsed
          anchors { top: parent.top; left: parent.left; margins: Style.space(14) }
          anchors.topMargin: Style.space(14)
          textFormat: Text.PlainText
          text: "LINKS"
          color: cashewWin.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        CashewBtn {
          id: cwBaseBtn
          visible: !cashewWin.linksCollapsed
          anchors { top: parent.top; right: cwChevron.left; topMargin: Style.space(6); rightMargin: Style.space(6) }
          label: root.cashewBase === "web" ? "Cashew: Web app" : "Cashew: App"
          active: root.cashewBase === "web"
          onClicked: {
            var next = Object.assign({}, root.cashewState, { base: root.cashewBase === "web" ? "app" : "web" })
            root.cashewSetState(next)
            root.cashewRebuildLinks()
          }
        }

        Flickable {
          id: cwLinksFlick
          visible: !cashewWin.linksCollapsed
          anchors { top: cwChevron.bottom; left: parent.left; right: parent.right; bottom: cwMarkRow.top }
          anchors.margins: Style.space(12)
          clip: true
          contentWidth: width
          contentHeight: cwLinksCol.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: cwLinksCol
            width: parent.width
            spacing: Style.space(10)


            Column {
              visible: root.cashewGuessedCount > 0
              width: parent.width
              spacing: Style.space(6)
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: "✦ " + root.cashewGuessedCount + " AI-guessed categor" + (root.cashewGuessedCount === 1 ? "y is" : "ies are")
                  + " not verified yet. Please check them before you import these links."
                color: root.pendingColor
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }
              Row {
                spacing: Style.space(6)
                CashewBtn {
                  label: "Review guessed"
                  primary: true
                  onClicked: root.cashewGuessedOnly = true
                }
                CashewBtn {
                  label: "I checked them · accept all"
                  onClicked: root.cashewAcceptGuesses()
                }
              }
            }

            Text {
              visible: root.cashewLinksError !== ""
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.cashewLinksError
              color: root.debitColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Column {
              visible: root.cashewWarnings.length > 0
              width: parent.width
              spacing: Style.space(3)
              Text {
                textFormat: Text.PlainText
                text: "Warnings · " + root.cashewWarnings.length
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Repeater {
                model: cashewWin.warnOpen ? root.cashewWarnings : root.cashewWarnings.slice(0, 5)
                delegate: Text {
                  required property string modelData
                  width: parent.width
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: "•  " + modelData
                  color: root.pendingColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              CashewBtn {
                visible: root.cashewWarnings.length > 5
                label: cashewWin.warnOpen ? "Show fewer" : "+" + (root.cashewWarnings.length - 5) + " more"
                onClicked: cashewWin.warnOpen = !cashewWin.warnOpen
              }
            }

            // Straight into Cashew: the ticked rows written into a copy of the Cashew database (txdb cashew-file).
            Column {
              visible: root.cashewLinks.length + root.cashewTransfers.length > 0 || root.cashewFixMessage !== ""
              width: parent.width
              spacing: Style.space(6)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "SAVE STRAIGHT INTO CASHEW"
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: "No browser window: the ticked rows (transfers as real linked transfers) go into a copy of your Cashew database. Import it in Cashew: Settings, Backup, Import. Import right away, in the only open Cashew tab."
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Row {
                spacing: Style.space(6)
                // the same file as the automatic sync (cashew-sync.sql), never a second one
                CashewBtn {
                  label: root.cashewSyncLabel
                  primary: root.cashewSync.pending > 0
                  onClicked: root.cashewSyncClick()
                }
                CashewBtn {
                  label: "Check now"
                  onClicked: root.cashewSyncNow()
                }
              }
              Text {
                visible: root.cashewFixMessage !== ""
                width: parent.width
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                text: root.cashewFixMessage + (root.cashewFixPath !== "" ? "  " + root.cashewFixPath : "")
                color: root.cashewFixPath !== "" ? root.creditColor : cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // What the linked refunds mean in Cashew (not warnings).
            Column {
              visible: root.cashewRefundNotes.length > 0
              width: parent.width
              spacing: Style.space(3)
              Repeater {
                model: root.cashewRefundNotes
                delegate: Text {
                  required property string modelData
                  width: parent.width
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: "↩  " + modelData
                  color: cashewWin.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: root.cashewLinks.length === 0 && root.cashewLinksError === "" && !root.cashewLoading
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.cashewIncludedCount === 0 ? "No row is included, so there is no link." : "Building the links…"
              color: cashewWin.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: []                      // links are not used any more (the sync file replaced them)
              delegate: Rectangle {
                id: lk
                required property var modelData
                required property int index
                property bool copied: false
                property bool showRaw: false
                property bool showLook: false
                // Stays set once Open is tapped, so a page of several links
                // keeps track of which ones are done after a scroll away.
                property bool opened: false
                width: cwLinksCol.width
                height: lkCol.implicitHeight + Style.space(20)
                radius: Style.space(8)
                color: Util.alpha(root.foreground, 0.06)
                border.width: lk.opened ? 1 : 0
                border.color: Util.alpha(root.creditColor, 0.5)
                Timer { id: lkCopiedTimer; interval: 1500; onTriggered: lk.copied = false }

                Column {
                  id: lkCol
                  anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(10) }
                  spacing: Style.space(8)

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    readonly property string sendState: cashewWin.rowStates[(lk.modelData.ids || [])[0]] || ""
                    text: Model.cashewLinkLabel(lk.index, root.cashewLinks.length, lk.modelData.count, lk.modelData.chars)
                      + (sendState === "added" ? "  ·  ✓ added" : (sendState === "adding" ? "  ·  adding…" : (lk.opened ? "  ·  opened" : "")))
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Item {
                    width: parent.width
                    height: Style.space(56)
                    clip: true
                    // A short preview only: laying out ~6,000 characters per card was slow.
                    // Copy and Open use the full URL.
                    Text {
                      width: parent.width
                      wrapMode: Text.WrapAnywhere
                      maximumLineCount: 3
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: Model.cashewPreview(lk.modelData.url, 140, 20)
                      color: cashewWin.muted
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    CashewBtn {
                      label: root.cashewVerifyArmed ? "Unverified AI · click again" : (lk.copied ? "Copied" : "Copy")
                      primary: true
                      onClicked: {
                        if (!root.cashewVerifyGate()) return
                        var url = lk.modelData.url
                        Quickshell.execDetached(["wl-copy", url])
                        lk.copied = true
                        lkCopiedTimer.restart()
                      }
                    }
                    CashewBtn {
                      label: root.cashewVerifyArmed ? "Unverified AI · click again" : "Open"
                      onClicked: {
                        if (!root.cashewVerifyGate()) return
                        Quickshell.execDetached(["xdg-open", lk.modelData.url])
                        lk.opened = true
                      }
                    }
                    CashewBtn {
                      label: "Look"
                      active: lk.showLook
                      onClicked: lk.showLook = !lk.showLook
                    }
                    CashewBtn {
                      label: "Raw JSON"
                      active: lk.showRaw
                      onClicked: lk.showRaw = !lk.showRaw
                    }
                  }

                  // Look: every entry of this link the way Cashew reads it (income or expense by the sign).
                  Flickable {
                    id: lkLookFlick
                    visible: lk.showLook
                    width: parent.width
                    height: lk.showLook ? Math.min(lkLookCol.implicitHeight, Style.space(220)) : 0
                    clip: true
                    contentWidth: width
                    contentHeight: lkLookCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                      id: lkLookCol
                      width: parent.width
                      spacing: Style.space(3)
                      Repeater {
                        model: lk.showLook ? Model.cashewLookEntries(lk.modelData.json) : []
                        delegate: Text {
                          required property var modelData
                          width: lkLookCol.width
                          wrapMode: Text.Wrap
                          textFormat: Text.PlainText
                          text: modelData.line
                          color: modelData.type === "income" ? root.creditColor : cashewWin.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                    ScrollWheelArea { anchors.fill: parent; target: lkLookFlick }
                  }

                  Flickable {
                    id: lkRawFlick
                    visible: lk.showRaw
                    width: parent.width
                    height: lk.showRaw ? Style.space(160) : 0
                    clip: true
                    contentWidth: width
                    contentHeight: lkRawText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    TextEdit {
                      id: lkRawText
                      width: parent.width
                      readOnly: true
                      selectByMouse: true
                      wrapMode: TextEdit.WrapAnywhere
                      textFormat: TextEdit.PlainText
                      text: lk.showRaw ? Model.cashewPrettyJson(lk.modelData.json) : ""
                      color: cashewWin.muted
                      selectionColor: Util.alpha(Color.accent, 0.4)
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                    }
                    ScrollWheelArea { anchors.fill: parent; target: lkRawFlick }
                  }
                }
              }
            }

            // Paired transfers: one Cashew transfer page each; Cashew cannot save them from a link.
            Column {
              visible: false                  // transfer pages are not used any more
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Transfers · " + root.cashewTransfers.length
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: "Cashew opens each transfer page; tap Save once per transfer."
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Repeater {
                model: root.cashewTransfers
                delegate: Rectangle {
                  id: tf
                  required property var modelData
                  property bool copied: false
                  property bool opened: false
                  width: cwLinksCol.width
                  height: tfCol.implicitHeight + Style.space(20)
                  radius: Style.space(8)
                  color: Util.alpha(root.foreground, 0.06)
                  border.width: tf.opened ? 1 : 0
                  border.color: Util.alpha(root.creditColor, 0.5)
                  Timer { id: tfCopiedTimer; interval: 1500; onTriggered: tf.copied = false }

                  Column {
                    id: tfCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(10) }
                    spacing: Style.space(6)
                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: tf.modelData.title + (tf.opened ? "  ·  opened" : "")
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: Model.cashewTransferLine(tf.modelData)
                      color: cashewWin.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Row {
                      spacing: Style.space(6)
                      CashewBtn {
                        label: root.cashewVerifyArmed ? "Unverified AI · click again" : (tf.copied ? "Copied" : "Copy")
                        primary: true
                        onClicked: {
                          if (!root.cashewVerifyGate()) return
                          var url = tf.modelData.url
                          Quickshell.execDetached(["wl-copy", url])
                          tf.copied = true
                          tfCopiedTimer.restart()
                        }
                      }
                      CashewBtn {
                        label: root.cashewVerifyArmed ? "Unverified AI · click again" : "Open"
                        onClicked: {
                          if (!root.cashewVerifyGate()) return
                          Quickshell.execDetached(["xdg-open", tf.modelData.url])
                          tf.opened = true
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          ScrollWheelArea { anchors.fill: parent; target: cwLinksFlick }
        }

        // Mark as tracked, asked twice and inline (no popup).
        Item {
          id: cwMarkRow
          visible: !cashewWin.linksCollapsed
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Style.space(12) }
          height: cashewWin.confirmMark ? cwConfirmCol.implicitHeight : Style.space(30)
          Timer { id: cwConfirmTimer; interval: 8000; running: cashewWin.confirmMark; onTriggered: cashewWin.confirmMark = false }

          CashewBtn {
            visible: !cashewWin.confirmMark
            label: "Mark " + root.cashewIncludedCount + " as tracked"
            primary: true
            enabled: root.cashewIncludedCount > 0
            onClicked: cashewWin.confirmMark = true
          }
          Column {
            id: cwConfirmCol
            visible: cashewWin.confirmMark
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: Model.cashewMarkQuestion(root.cashewIncludedCount, root.cashewTransfers.length)
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Row {
              spacing: Style.space(8)
              CashewBtn { label: "Yes"; primary: true; onClicked: cashewWin.markTracked() }
              CashewBtn { label: "No"; onClicked: cashewWin.confirmMark = false }
            }
          }
        }
      }

      // ---- guess results: what the model returned for each row sent
      Rectangle {
        id: cwResults
        visible: cashewWin.resultsOpen
        z: 20
        anchors { top: cwFilterHost.bottom; bottom: parent.bottom; left: parent.left; right: cwRight.left; margins: Style.space(16) }
        anchors.topMargin: Style.space(10)
        anchors.rightMargin: Style.space(12)
        radius: Style.space(12)
        color: Color.popups.background
        border.width: 1
        border.color: Util.alpha(root.foreground, 0.18)

        MouseArea { anchors.fill: parent; onClicked: {} }

        Row {
          id: cgTitleRow
          anchors { left: parent.left; top: parent.top; margins: Style.space(14) }
          height: Style.space(28)
          spacing: Style.space(12)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "GUESS RESULTS"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Model.cashewGuessSummary(root.cashewGuessCounts.sent, root.cashewGuessMeta.batches, root.cashewGuessing ? 0 : root.cashewGuessMeta.seconds, root.cashewGuessMeta.model)
            color: cashewWin.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Flow {
          id: cgButtons
          anchors { left: parent.left; right: parent.right; top: cgTitleRow.bottom; leftMargin: Style.space(14); rightMargin: Style.space(14); topMargin: Style.space(8) }
          spacing: Style.space(6)
          CashewBtn { label: "All"; active: cashewWin.resultsFilter === "all"; onClicked: cashewWin.resultsFilter = "all" }
          CashewBtn { label: "Guessed"; active: cashewWin.resultsFilter === "guessed"; onClicked: cashewWin.resultsFilter = "guessed" }
          CashewBtn { label: "No guess"; active: cashewWin.resultsFilter === "none"; onClicked: cashewWin.resultsFilter = "none" }
          CashewBtn {
            label: "Accept all"
            primary: true
            enabled: root.cashewGuessedCount > 0
            onClicked: root.cashewAcceptGuesses()
          }
          CashewBtn {
            label: "Revert all"
            enabled: root.cashewGuessedCount > 0
            onClicked: root.cashewRevertGuessRows(null)
          }
          CashewBtn { label: "Raw output"; active: cashewWin.resultsRaw; onClicked: cashewWin.resultsRaw = !cashewWin.resultsRaw }
          CashewBtn { visible: root.cashewGuessedCount === 0; label: "Close"; onClicked: cashewWin.resultsOpen = false }
        }

        ListView {
          id: cgList
          visible: !cashewWin.resultsRaw
          anchors { top: cgButtons.bottom; bottom: parent.bottom; left: parent.left; right: parent.right; margins: Style.space(14) }
          anchors.topMargin: Style.space(10)
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          model: cgRows
          reuseItems: false

          delegate: Rectangle {
            id: cgr
            required property string gid
            required property string rawId
            required property int idx
            required property string title
            required property string amount
            required property string st
            required property string beforeCat
            required property string beforeSub
            required property string guessCat
            required property string guessSub
            required property bool isGroup
            required property int count
            required property var members
            // Same-UPI-counterparty rows (isGroup) start collapsed - the
            // group card itself already says enough ("4 transactions · guess
            // · Apply to all 4"); this just lets a user drop into the list
            // of actual transactions to review or adjust one at a time.
            property bool expanded: false
            readonly property bool hasGuess: cgr.guessCat !== ""
            readonly property bool anyGuessed: cgr.isGroup
              ? cgr.members.some(function (mm) { return mm.st === "guessed" })
              : cgr.st === "guessed"
            readonly property var catInfo: cashewWin.catMap[cgr.hasGuess ? cgr.guessCat : cgr.beforeCat] || ({ icon: "❓", color: "#5A2A2E" })
            readonly property var beforeInfo: cashewWin.catMap[cgr.beforeCat] || ({ icon: "❓", color: "#5A2A2E" })
            readonly property bool isCredit: cgr.amount.charAt(0) !== "-"
            width: cgList.width
            height: Style.space(62) + (cgr.isGroup && cgr.expanded ? cgMembersCol.implicitHeight + Style.space(8) : 0)
            radius: Style.space(10)
            color: Util.alpha(root.foreground, cgHover.hovered ? 0.06 : 0)
            HoverHandler { id: cgHover }

            CashewIcon {
              id: cgIcon
              anchors { left: parent.left; leftMargin: Style.space(8); top: parent.top; topMargin: Style.space(13) }
              width: Style.space(36)
              icon: cgr.catInfo.icon
              fill: cgr.catInfo.color
            }
            Item {
              id: cgActions
              anchors { right: parent.right; rightMargin: Style.space(8); top: parent.top; topMargin: Style.space(4) }
              width: Style.space(215)
              height: Style.space(54)
              Rectangle {
                id: cgTag
                anchors { left: parent.left; top: parent.top }
                width: Style.space(84)
                height: Style.space(22)
                radius: height / 2
                color: cgr.st === "guessed" ? Util.alpha(Color.accent, 0.28)
                  : cgr.st === "accepted" ? Util.alpha(root.creditColor, 0.28)
                  : Util.alpha(root.foreground, 0.10)
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: cgr.st === "no-guess" ? "no guess" : cgr.st === "skipped-touched" ? "edited" : cgr.st
                  color: cgr.st === "guessed" ? Color.accent : cgr.st === "accepted" ? root.creditColor : cashewWin.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: cgr.st === "guessed" || cgr.st === "accepted"
                }
              }
              CashewBtn {
                id: cgExpand
                visible: cgr.isGroup
                anchors { left: cgTag.right; leftMargin: Style.space(6); top: parent.top }
                label: cgr.expanded ? "Hide" : "Members"
                onClicked: cgr.expanded = !cgr.expanded
              }
              CashewBtn {
                id: cgRevert
                anchors { right: parent.right; bottom: parent.bottom }
                label: cgr.isGroup ? "Revert all" : "Revert"
                visible: cgr.anyGuessed
                onClicked: {
                  var ids = cgr.isGroup ? cgr.members.map(function (mm) { return mm.rawId }) : [cgr.rawId]
                  root.cashewRevertGuessRows(ids)
                }
              }
              CashewBtn {
                id: cgAccept
                anchors { right: cgRevert.left; rightMargin: Style.space(6); bottom: parent.bottom }
                label: cgr.isGroup ? "Apply to all " + cgr.count : "Accept"
                primary: true
                visible: cgr.anyGuessed
                onClicked: {
                  var ids = cgr.isGroup ? cgr.members.map(function (mm) { return mm.rawId }) : [cgr.rawId]
                  root.cashewAcceptGuessRows(ids)
                }
              }
            }
            Text {
              id: cgAmount
              anchors { right: cgActions.left; rightMargin: Style.space(10); top: parent.top; topMargin: Style.space(8) }
              width: Style.space(100)
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Model.cashewMoney(cgr.amount)
              color: cgr.isCredit ? root.creditColor : root.debitColor
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              id: cgTitle
              anchors { left: cgIcon.right; leftMargin: Style.space(12); right: cgAmount.left; rightMargin: Style.space(10); top: parent.top; topMargin: Style.space(8) }
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: cgr.title + (cgr.isGroup ? "  ·  " + cgr.count + " transactions" : "")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.underline: cgTitleMouse.containsMouse
              MouseArea {
                id: cgTitleMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { var ri = cgr.idx; cashewWin.revealRow(ri) }
              }
            }
            Row {
              id: cgChipsRow
              anchors { left: cgTitle.left; top: parent.top; topMargin: Style.space(34) }
              spacing: Style.space(6)
              CashewChip {
                maxWidth: Style.space(220)
                tint: cgr.beforeInfo.color
                text: cgr.beforeCat + (cgr.beforeSub !== "" && cgr.beforeSub !== "Unknown" ? "  ›  " + cgr.beforeSub : "")
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "››"
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              CashewChip {
                visible: cgr.hasGuess
                maxWidth: Style.space(300)
                tint: cgr.catInfo.color
                text: "✦ " + cgr.guessCat + (cgr.guessSub !== "" ? "  ›  " + cgr.guessSub : "")
              }
              Text {
                visible: !cgr.hasGuess
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: cgr.st === "pending" ? "waiting for the model" : cgr.st === "skipped-touched" ? "you edited this row"
                  : cgr.st === "mixed" ? "mixed - open Members" : "no guess"
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // One line per actual transaction in the group - the per-row
            // accept/revert/view still work here, so dropping into a group
            // to handle one member differently never loses that ability.
            Column {
              id: cgMembersCol
              visible: cgr.isGroup && cgr.expanded
              anchors { left: cgIcon.right; leftMargin: Style.space(12); right: parent.right; rightMargin: Style.space(8); top: parent.top; topMargin: Style.space(62) }
              spacing: Style.space(4)
              Repeater {
                model: cgr.isGroup ? cgr.members : []
                delegate: Row {
                  id: cgMember
                  required property var modelData
                  width: cgMembersCol.width
                  height: Style.space(24)
                  spacing: Style.space(8)
                  Text {
                    width: Style.space(80)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Model.cashewMoney(cgMember.modelData.amount)
                    color: cgMember.modelData.amount.charAt(0) !== "-" ? root.creditColor : root.debitColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    width: Style.space(90)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: cgMember.modelData.st === "no-guess" ? "no guess" : cgMember.modelData.st === "skipped-touched" ? "edited" : cgMember.modelData.st
                    color: cgMember.modelData.st === "guessed" ? Color.accent : cgMember.modelData.st === "accepted" ? root.creditColor : cashewWin.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  TextAction {
                    label: "View"
                    onTriggered: cashewWin.revealRow(cgMember.modelData.idx)
                  }
                  CashewBtn {
                    label: "Accept"
                    primary: true
                    visible: cgMember.modelData.st === "guessed"
                    onClicked: { var rid = cgMember.modelData.rawId; root.cashewAcceptGuessRows([rid]) }
                  }
                  CashewBtn {
                    label: "Revert"
                    visible: cgMember.modelData.st === "guessed"
                    onClicked: { var rid = cgMember.modelData.rawId; root.cashewRevertGuessRows([rid]) }
                  }
                }
              }
            }
          }
        }

        Text {
          visible: !cashewWin.resultsRaw && cgRows.count === 0
          anchors.centerIn: cgList
          textFormat: Text.PlainText
          text: "No rows here."
          color: cashewWin.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Flickable {
          id: cgRawFlick
          visible: cashewWin.resultsRaw
          anchors.fill: cgList
          clip: true
          contentWidth: width
          contentHeight: cgRawText.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          Text {
            id: cgRawText
            width: cgRawFlick.width
            wrapMode: Text.WrapAnywhere
            textFormat: Text.PlainText
            text: root.cashewGuessRaw.length > 0 ? root.cashewGuessRaw.join("\n") : "No output yet."
            color: Qt.darker(root.foreground, 1.2)
            font.family: "monospace"
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---- left pane: the drafts
      Item {
        id: cwLeft
        anchors { top: cwFilterHost.bottom; bottom: parent.bottom; left: parent.left; right: cwRight.left; margins: Style.space(16) }
        anchors.topMargin: Style.space(10)
        anchors.rightMargin: Style.space(12)

        // Title + the categorisation toolbar: the "Needs category" filter,
        // the manual "Categorise next" stepper, and the AI "✦ AI categories"
        // guess trigger all sit here together, above the list they act on.
        // The audit found the AI guess button living only in the header
        // (small, same style as Options/Close, labelled just "✦ Guess") while
        // the manual flow lived down here with zero cross-reference — a user
        // could find one and never notice the other. Putting both categorise
        // paths in one row, in the pane that is the actual work area, fixes
        // both the "where is the AI feature" complaint and that disconnect.
        Item {
          id: cwLeftTitle
          width: parent.width
          height: cwLeftTitleCol.implicitHeight

          Column {
            id: cwLeftTitleCol
            width: parent.width
            spacing: Style.space(8)

            Text {
              visible: !root.cashewDedupe.ok || (root.cashewDedupe.unknownAccounts || []).length > 0
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: !root.cashewDedupe.ok
                ? "Cashew could not be read (" + (root.cashewDedupe.reason || "?") + "): rows already in Cashew cannot be found, so a send can add them twice."
                : "Not checked for duplicates (Cashew has no account named " + root.cashewDedupe.unknownAccounts.join(", ") + ")."
              color: root.pendingColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            // The select-all checkbox sits over the row checkboxes (same left inset) and acts on the rows the
            // list shows. Beside it: how many are selected and their income / expense totals.
            Row {
              leftPadding: Style.space(8)
              spacing: Style.space(10)
              CashewCheck {
                anchors.verticalCenter: parent.verticalCenter
                checked: cashewWin.selectState === "all"
                partial: cashewWin.selectState === "some"
                onToggled: root.cashewSetAll(cashewWin.selectState !== "all")
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: cashewWin.needOnly ? "ROWS WITH NO CATEGORY" : "TRANSACTIONS"
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: cashewWin.selection.text
                color: cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              CashewBtn {
                label: root.cashewNeedCount > 0 ? "Needs category  ·  " + root.cashewNeedCount : "All categorised"
                primary: root.cashewNeedCount > 0
                active: cashewWin.needOnly
                tint: root.cashewNeedCount > 0 ? "transparent" : root.creditColor
                enabled: root.cashewNeedCount > 0 || cashewWin.needOnly
                onClicked: cashewWin.needOnly = !cashewWin.needOnly
              }
              CashewBtn {
                visible: root.cashewInCashewRows.length > 0
                label: "Mark " + root.cashewInCashewRows.length + " already in Cashew as tracked"
                onClicked: {
                  store.setTrackedMany(root.cashewInCashewRows.map(function (d) { return { id: d.id } }), true)
                  cashewSendReloadTimer.restart()
                }
              }
              CashewBtn {
                visible: root.cashewNeedCount > 0
                label: "Categorise next  (N)"
                onClicked: cashewWin.askStart()
              }
              // One slot, three states: a run in progress (Stop), guesses waiting for the
              // user (Confirm + Review, no start button), or the start button.
              CashewBtn {
                visible: root.cashewGuessing
                big: true
                active: true
                label: root.cashewStopArmed ? "■ Click again to stop" : "■ Stop"
                onClicked: root.cashewStopClick()
              }
              CashewBtn {
                visible: !root.cashewGuessing && root.cashewGuessedCount > 0
                big: true
                primary: true
                label: "✓ Confirm " + root.cashewGuessedCount + " AI categories"
                onClicked: root.cashewAcceptGuesses()
              }
              CashewBtn {
                visible: !root.cashewGuessing && root.cashewGuessedCount > 0
                label: "Review"
                onClicked: {
                  if (root.cashewGuessLog.length === 0) { root.cashewGuessedOnly = true; return }
                  cashewWin.resultsFilter = "guessed"; cashewWin.resultsOpen = true
                }
              }
              CashewBtn {
                visible: !root.cashewGuessing && root.cashewGuessedCount === 0 && root.cashewGuessCount > 0
                big: true
                primary: true
                enabled: !root.cashewLoading
                label: "✦ AI categories  ·  " + root.cashewGuessCount
                onClicked: root.cashewGuessStart()
              }
            }
          }
        }

        Text {
          visible: root.cashewLoading || root.cashewError !== "" || (root.cashewShown.length === 0)
          anchors.centerIn: parent
          width: parent.width - Style.space(40)
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.cashewError !== "" ? root.cashewError : (root.cashewLoading ? "Reading…" : "Nothing to track here.")
          color: root.cashewError !== "" ? root.debitColor : cashewWin.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // ---- the send in progress: how much is left, a bar, the step, and "Left only"
        Item {
          id: cwProgress
          visible: false                      // the link send is gone; the sync file replaced it
          anchors { top: cwLeftTitle.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: visible ? Style.space(10) : 0
          height: visible ? cwProgCol.implicitHeight + Style.space(24) : 0
          Rectangle {
            anchors.fill: parent
            radius: Style.space(10)
            color: Util.alpha(root.foreground, 0.05)
          }
          Column {
            id: cwProgCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
            spacing: Style.space(8)
            Item {
              width: parent.width
              height: cwProgBig.implicitHeight
              Row {
                anchors { left: parent.left; bottom: parent.bottom }
                spacing: Style.space(8)
                Text {
                  id: cwProgBig
                  textFormat: Text.PlainText
                  // done: how many were added; else how many of this send are left
                  text: String(root.cashewSendPhase === "done" ? root.cashewSendProgress.doneRows : root.cashewSendProgress.rows)
                  color: root.cashewSendPhase === "done" ? root.creditColor : root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body + 12
                  font.bold: true
                }
                Text {
                  anchors.baseline: cwProgBig.baseline
                  textFormat: Text.PlainText
                  text: root.cashewSendPhase === "done"
                    ? (root.cashewSendProgress.doneRows === 1 ? "transaction added" : "transactions added")
                    : root.cashewSendPhase === "stopped"
                    ? "of " + root.cashewSendProgress.total + " not added (stopped)"
                    : "of " + root.cashewSendProgress.total + " transactions left"
                  color: cashewWin.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              Row {
                anchors { right: parent.right; bottom: parent.bottom }
                spacing: Style.space(6)
                CashewBtn {
                  label: "Left only"
                  active: cashewWin.leftOnly
                  onClicked: cashewWin.leftOnly = !cashewWin.leftOnly
                }
                CashewBtn {
                  visible: root.cashewSendPhase === "done" || root.cashewSendPhase === "stopped"
                  label: "Hide"
                  onClicked: root.cashewSendPhase = ""
                }
              }
            }
            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.foreground, 0.1)
              Rectangle {
                width: root.cashewSendProgress.total > 0 ? parent.width * root.cashewSendProgress.doneRows / root.cashewSendProgress.total : 0
                height: parent.height
                radius: parent.radius
                color: root.cashewSendPhase === "done" ? root.creditColor : (root.cashewSendPaused ? root.pendingColor : Color.accent)
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
              }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: {
                var lt = 0, tt = 0
                root.cashewSendItems.forEach(function (x) { if (x.kind === "transfers") tt += x.n || 0; else if (x.kind === "transfer") tt++; else lt++ })
                var l = root.cashewSendProgress
                return "Links " + (lt - l.links) + " of " + lt + (tt > 0 ? "  ·  transfers " + (tt - l.transfers) + " of " + tt : "")
              }
              color: cashewWin.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: root.cashewSendNote !== ""
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.cashewSendNote
              color: root.cashewSendPaused ? root.pendingColor : (root.cashewSending ? Color.accent : root.foreground)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        ListView {
          id: cwList
          anchors { top: cwProgress.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: Style.space(8)
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          model: cwRows
          reuseItems: false

          section.property: "day"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            id: cdHead
            required property string section
            width: cwList.width
            height: Style.space(40)
            readonly property var dayIdxs: Model.cashewDayIdxs(cashewWin.visRows, cdHead.section)
            // The day checkbox: same left inset as the row checkboxes; selects or clears the rows of this day.
            CashewCheck {
              id: cdCheck
              anchors { left: parent.left; leftMargin: Style.space(8); verticalCenter: cdDayLabel.verticalCenter }
              readonly property string state3: Model.cashewSelectState(root.cashewDrafts, cdHead.dayIdxs)
              checked: state3 === "all"
              partial: state3 === "some"
              onToggled: root.cashewEdit(Model.cashewSetInclude(root.cashewDrafts, cdHead.dayIdxs, state3 !== "all"))
            }
            Text {
              id: cdDayLabel
              // right of the day checkbox, over the row icons
              anchors { left: cdCheck.right; leftMargin: Style.space(10); bottom: parent.bottom; bottomMargin: Style.space(6) }
              textFormat: Text.PlainText
              text: Model.cashewDayLabel(cdHead.section)
              color: cashewWin.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              // ends where the row amounts end: row margin 10 + actions 52 + gap 10 + cell padding 4
              anchors { right: parent.right; rightMargin: Style.space(76); bottom: parent.bottom; bottomMargin: Style.space(6) }
              textFormat: Text.PlainText
              text: cashewWin.dayTotals[cdHead.section] || ""
              color: cashewWin.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          delegate: Rectangle {
            id: crow
            required property int idx
            required property int partner      // the in leg of a transfer pair shown as one card, else -1
            readonly property var d: root.cashewDrafts[crow.idx] || ({})
            readonly property var d2: crow.partner >= 0 ? (root.cashewDrafts[crow.partner] || ({})) : ({})
            readonly property bool isTransfer: crow.d.kind === "transfer"
            readonly property bool paired: crow.isTransfer && crow.partner >= 0
            readonly property bool warn: (crow.d.warn || "") !== "" || crow.d.category === "Uncategorized"
            readonly property bool needs: Model.cashewNeedsCategory(crow.d)
            readonly property bool isCredit: String(crow.d.amount || "").charAt(0) !== "-"
            readonly property var cat: cashewWin.catMap[crow.d.category] || ({ icon: "❓", color: "#5A2A2E" })
            readonly property color kindColor: crow.isCredit ? root.creditColor : root.debitColor
            readonly property string sendState: cashewWin.rowStates[crow.d.id] || ""
            opacity: crow.sendState === "added" || crow.d.inCashew === true ? 0.45 : 1
            width: cwList.width
            // The popup is wide: columns stay put (no sliding). With the links pane
            // open the list is narrow and the row falls back to two lines.
            property bool infoOpen: false
            readonly property bool wide: false      // one layout at every width: two lines per row
            readonly property var srcTxn: crow.infoOpen ? store.transactions.find(function (t) { return t.id === crow.d.id }) : null
            height: crow.isTransfer ? Style.space(68) : (crow.wide ? Style.space(60) : Style.space(68)) + (crow.infoOpen ? Style.space(40) : 0)
            radius: Style.space(12)
            color: crow.idx === cashewWin.flashIdx ? Util.alpha(Color.accent, 0.22) : Util.alpha(root.foreground, crowHover.hovered ? 0.06 : 0)
            HoverHandler { id: crowHover }
            Rectangle {
              visible: crow.sendState === "adding"
              anchors { left: parent.left; top: parent.top; bottom: parent.bottom; topMargin: Style.space(10); bottomMargin: Style.space(10) }
              width: Style.space(3)
              radius: width / 2
              color: Color.accent
            }

            Loader {
              anchors.fill: parent
              sourceComponent: crow.isTransfer ? cardBody : rowBody
            }

            // A plain transaction. Wide: check | icon | title | note | account | category | amount+date | actions.
            // Narrow: title and amount on line one; chips and note on line two.
            Component {
              id: rowBody
              Item {
                anchors { fill: parent; leftMargin: Style.space(8); rightMargin: Style.space(10) }
                opacity: crow.d.include ? 1 : 0.5

                Item {
                  id: mainArea
                  anchors { left: parent.left; right: parent.right; top: parent.top }
                  height: crow.wide ? Style.space(60) : Style.space(68)
                }

                CashewCheck {
                  id: crowCheck
                  anchors { left: parent.left; verticalCenter: mainArea.verticalCenter }
                  checked: !!crow.d.include
                  onToggled: root.cashewEdit(Model.cashewPatch(root.cashewDrafts, crow.idx, { include: !crow.d.include }))
                }
                CashewIcon {
                  id: crowIcon
                  anchors { left: crowCheck.right; leftMargin: Style.space(10); verticalCenter: mainArea.verticalCenter }
                  icon: crow.cat.icon
                  fill: crow.cat.color
                  warn: crow.warn
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: cashewWin.openPicker("category", crow.idx) }
                }

                // actions: always there, dim until the pointer is over the row
                Row {
                  id: cActions
                  anchors { right: parent.right; verticalCenter: mainArea.verticalCenter }
                  spacing: Style.space(4)
                  opacity: crowHover.hovered || crow.infoOpen ? 1.0 : 0.55
                  PanelActionButton {
                    size: Style.space(24)
                    iconText: "✎"
                    tooltipText: "Edit note"
                    foreground: root.foreground
                    bordered: false
                    focusable: false
                    onClicked: cashewWin.openPicker("note", crow.idx)
                  }
                  PanelActionButton {
                    size: Style.space(24)
                    iconText: "󰋽"
                    tooltipText: "Where this row came from"
                    foreground: crow.infoOpen ? Color.accent : root.foreground
                    bordered: false
                    focusable: false
                    onClicked: crow.infoOpen = !crow.infoOpen
                  }
                }

                // right column: amount, then the date
                CashewCell {
                  id: cAmount
                  anchors { right: cActions.left; rightMargin: Style.space(10); top: mainArea.top; topMargin: crow.wide ? Style.space(5) : Style.space(9) }
                  width: crow.wide ? Style.space(120) : Style.space(150)
                  implicitHeight: Style.space(26)
                  kind: "amount"
                  alignRight: true
                  bold: true
                  pixelSize: Style.font.body + 2
                  value: crow.d.amount || ""
                  display: (crow.isCredit ? "▴ " : "▾ ") + Model.cashewMoney(crow.d.amount)
                  color: crow.kindColor
                  onCommit: function (v) { root.cashewEdit(Model.cashewPatch(root.cashewDrafts, crow.idx, { amount: v }), true) }
                }
                CashewCell {
                  id: cDate
                  anchors { right: cAmount.right; top: cAmount.bottom; topMargin: crow.wide ? Style.space(1) : Style.space(5) }
                  width: Style.space(150)
                  alignRight: true
                  kind: "date"
                  value: crow.d.date || ""
                  color: cashewWin.muted
                  onCommit: function (v) {
                    root.cashewEdit(Model.cashewPatch(root.cashewDrafts, crow.idx, { date: v }), true)
                    Qt.callLater(cashewWin.syncRows)
                  }
                }

                // wide-mode column slots (the chips sit at their left edge)
                Item { id: catSlot; width: Style.space(215); height: 1; anchors { right: cAmount.left; rightMargin: Style.space(14); verticalCenter: mainArea.verticalCenter } }
                Item { id: acctSlot; width: Style.space(90); height: 1; anchors { right: catSlot.left; rightMargin: Style.space(10); verticalCenter: mainArea.verticalCenter } }

                // title, then the chips and the note
                CashewCell {
                  id: cTitle
                  anchors {
                    left: crowIcon.right; leftMargin: Style.space(14)
                    right: crow.wide ? acctSlot.left : cAmount.left
                    rightMargin: Style.space(12)
                    top: mainArea.top
                    topMargin: crow.wide ? (cNotes.has ? Style.space(7) : Style.space(17)) : Style.space(9)
                  }
                  implicitHeight: Style.space(26)
                  pixelSize: Style.font.body + 1
                  value: crow.d.title || ""
                  color: root.foreground
                  onCommit: function (v) { root.cashewEdit(Model.cashewPatch(root.cashewDrafts, crow.idx, { title: v }), true) }
                }
                CashewChip {
                  id: cAcct
                  anchors {
                    left: crow.wide ? acctSlot.left : cTitle.left
                    top: crow.wide ? undefined : cTitle.bottom
                    topMargin: Style.space(5)
                    verticalCenter: crow.wide ? mainArea.verticalCenter : undefined
                  }
                  maxWidth: crow.wide ? Style.space(90) : Style.space(120)
                  tint: "#455A64"
                  text: (crow.d.account || "") !== "" ? crow.d.account : "No account"
                  warn: (crow.d.account || "") === ""
                  onClicked: cashewWin.openPicker("account", crow.idx)
                }
                CashewChip {
                  id: cCat
                  anchors {
                    left: crow.wide ? catSlot.left : cAcct.right
                    leftMargin: crow.wide ? 0 : Style.space(6)
                    verticalCenter: crow.wide ? mainArea.verticalCenter : cAcct.verticalCenter
                  }
                  maxWidth: crow.wide ? Style.space(215) : Style.space(220)
                  tint: crow.cat.color
                  text: crow.needs ? "Choose category" : (crow.d.guessed ? "✦ " : "") + (crow.d.category || "—") + ((crow.d.subcategory || "") !== "" ? "  ›  " + crow.d.subcategory : "")
                  selected: crow.needs
                  warn: crow.warn && !crow.needs
                  onClicked: cashewWin.openPicker("category", crow.idx)
                }
                Item {
                  id: cStar
                  visible: crow.d.guessed === true
                  anchors { left: cCat.left; verticalCenter: cCat.verticalCenter }
                  width: Style.space(22)
                  height: cCat.height
                  HoverHandler { id: starHover }
                }
                Rectangle {
                  visible: crow.d.guessed === true && starHover.hovered
                  z: 5
                  anchors { left: cCat.left; bottom: cCat.top; bottomMargin: Style.space(2) }
                  width: guessTipText.implicitWidth + Style.space(16)
                  height: guessTipText.implicitHeight + Style.space(8)
                  radius: Style.space(6)
                  color: Color.popups.background
                  border.width: 1
                  border.color: Util.alpha(root.foreground, 0.25)
                  Text {
                    id: guessTipText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: "Guessed by the local model: check it"
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                // The note, partly shown: its first line. Wide: under the title. Narrow: after the chips.
                Item {
                  id: noteBox
                  height: Style.space(22)
                  anchors {
                    left: crow.wide ? cTitle.left : cCat.right
                    leftMargin: crow.wide ? 0 : Style.space(10)
                    right: crow.wide ? acctSlot.left : cAmount.left
                    rightMargin: Style.space(12)
                    top: crow.wide ? cTitle.bottom : undefined
                    verticalCenter: crow.wide ? undefined : cAcct.verticalCenter
                  }
                }
                CashewNote {
                  id: cNotes
                  hot: crowHover.hovered && !crow.wide
                  width: noteBox.width
                  anchors { left: noteBox.left; verticalCenter: noteBox.verticalCenter }
                  text: crow.d.notes || ""
                  onClicked: cashewWin.openPicker("note", crow.idx)
                }

                Text {
                  visible: crow.infoOpen
                  anchors { left: cTitle.left; right: parent.right; rightMargin: Style.space(70); bottom: parent.bottom; bottomMargin: Style.space(22) }
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: crow.srcTxn ? ("Raw: " + crow.srcTxn.merchant + "  ·  " + Model.formatFullDate(crow.srcTxn.date)) : "Source not in the current list"
                  color: cashewWin.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                // Look: what Cashew gets for this row, or why it gets nothing.
                Text {
                  visible: crow.infoOpen
                  anchors { left: cTitle.left; right: parent.right; rightMargin: Style.space(70); bottom: parent.bottom; bottomMargin: Style.space(4) }
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: Model.cashewLookLine(crow.d, cashewWin.fates[crow.d.id], root.cashewLinks.length)
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // A transfer: one row like any other. Line one: title and amount. Line two:
            // the two accounts as "out -> in", then the note. A pair is edited as one.
            Component {
              id: cardBody
              Item {
                id: tb
                anchors { fill: parent; leftMargin: Style.space(8); rightMargin: Style.space(10) }
                opacity: crow.d.include ? 1 : 0.5
                readonly property var legs: crow.paired ? [crow.idx, crow.partner] : [crow.idx]
                readonly property bool sameAmount: crow.paired && Math.abs(Number(String(crow.d.amount).replace(/,/g, ""))) === Math.abs(Number(String(crow.d2.amount).replace(/,/g, "")))
                readonly property string noteText: (crow.d.notes || "") !== "" ? crow.d.notes : (crow.paired ? (crow.d2.notes || "") : "")
                readonly property int noteIdx: (crow.d.notes || "") === "" && crow.paired && (crow.d2.notes || "") !== "" ? crow.partner : crow.idx

                Item {
                  id: tMain
                  anchors { left: parent.left; right: parent.right; top: parent.top }
                  height: Style.space(68)
                }
                CashewCheck {
                  id: cardCheck
                  anchors { left: parent.left; verticalCenter: tMain.verticalCenter }
                  checked: !!crow.d.include
                  onToggled: root.cashewEdit(Model.cashewPatchMany(root.cashewDrafts, tb.legs, { include: !crow.d.include }))
                }
                CashewIcon {
                  id: cardIcon
                  anchors { left: cardCheck.right; leftMargin: Style.space(10); verticalCenter: tMain.verticalCenter }
                  icon: crow.cat.icon
                  fill: crow.cat.color
                  warn: crow.warn
                }
                Row {
                  id: tActions
                  anchors { right: parent.right; verticalCenter: tMain.verticalCenter }
                  spacing: Style.space(4)
                  opacity: crowHover.hovered ? 1.0 : 0.55
                  PanelActionButton {
                    size: Style.space(24)
                    iconText: "✎"
                    tooltipText: "Edit note"
                    foreground: root.foreground
                    bordered: false
                    focusable: false
                    onClicked: cashewWin.openPicker("note", tb.noteIdx)
                  }
                  Item { width: Style.space(24); height: Style.space(24) }
                }
                // amount: one figure for the transfer (the out leg); legs that differ show the in figure under it
                CashewCell {
                  id: tAmount
                  anchors { right: tActions.left; rightMargin: Style.space(10); top: tMain.top; topMargin: Style.space(9) }
                  width: Style.space(150)
                  implicitHeight: Style.space(26)
                  kind: "amount"
                  alignRight: true
                  bold: true
                  pixelSize: Style.font.body + 2
                  value: crow.d.amount || ""
                  display: (crow.paired ? "⇄ " : (crow.isCredit ? "▴ " : "▾ ")) + Model.cashewMoney(crow.d.amount)
                  color: crow.paired ? root.foreground : crow.kindColor
                  onCommit: function (v) {
                    // the in leg keeps matching the out leg while the two were equal
                    var follow = tb.sameAmount && crow.partner >= 0
                    var patch = Model.cashewPatch(root.cashewDrafts, crow.idx, { amount: v })
                    if (follow) patch = Model.cashewPatch(patch, crow.partner, { amount: String(v).replace(/^-/, "") })
                    root.cashewEdit(patch, true)
                  }
                }
                CashewCell {
                  id: tDate
                  anchors { right: tAmount.right; top: tAmount.bottom; topMargin: Style.space(5) }
                  width: Style.space(110)
                  alignRight: true
                  kind: "date"
                  value: crow.d.date || ""
                  color: cashewWin.muted
                  onCommit: function (v) {
                    // the in leg follows unless it has a date of its own
                    var legs = (crow.paired && crow.d2.date === crow.d.date) ? [crow.idx, crow.partner] : [crow.idx]
                    root.cashewEdit(Model.cashewPatchMany(root.cashewDrafts, legs, { date: v }), true)
                    Qt.callLater(cashewWin.syncRows)
                  }
                }
                CashewCell {
                  id: tTitle
                  anchors { left: cardIcon.right; leftMargin: Style.space(14); right: tAmount.left; rightMargin: Style.space(12); top: tMain.top; topMargin: Style.space(9) }
                  implicitHeight: Style.space(26)
                  pixelSize: Style.font.body + 1
                  value: crow.d.title || ""
                  color: root.foreground
                  onCommit: function (v) { root.cashewEdit(Model.cashewPatchMany(root.cashewDrafts, tb.legs, { title: v }), true) }
                }
                CashewChip {
                  id: tFrom
                  anchors { left: tTitle.left; top: tTitle.bottom; topMargin: Style.space(5) }
                  maxWidth: Style.space(120)
                  tint: "#455A64"
                  text: (crow.d.account || "") !== "" ? crow.d.account : "No account"
                  warn: (crow.d.account || "") === ""
                  onClicked: cashewWin.openPicker("account", crow.idx)
                }
                Text {
                  id: tArrow
                  visible: crow.paired
                  anchors { left: tFrom.right; leftMargin: Style.space(8); verticalCenter: tFrom.verticalCenter }
                  textFormat: Text.PlainText
                  text: "→"
                  color: cashewWin.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                CashewChip {
                  id: tTo
                  visible: crow.paired
                  anchors { left: tArrow.right; leftMargin: Style.space(8); verticalCenter: tFrom.verticalCenter }
                  maxWidth: Style.space(120)
                  tint: "#455A64"
                  text: (crow.d2.account || "") !== "" ? crow.d2.account : "No account"
                  warn: (crow.d2.account || "") === ""
                  onClicked: cashewWin.openPicker("account", crow.partner)
                }
                Item {
                  id: tNoteBox
                  height: Style.space(22)
                  anchors { left: crow.paired ? tTo.right : tFrom.right; leftMargin: Style.space(10); right: tAmount.left; rightMargin: Style.space(12); verticalCenter: tFrom.verticalCenter }
                }
                CashewNote {
                  width: tNoteBox.width
                  anchors { left: tNoteBox.left; verticalCenter: tNoteBox.verticalCenter }
                  text: tb.noteText
                  hot: crowHover.hovered
                  onClicked: cashewWin.openPicker("note", tb.noteIdx)
                }
              }
            }
          }
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        }
        ScrollWheelArea { anchors.fill: cwList; target: cwList }

        // The day list itself can go empty from the filters (Needs category,
        // Guessed only) while cashewShown still has rows, which used to leave
        // a blank pane with no clue why. Say so, with a one-tap way out.
        Column {
          visible: !root.cashewLoading && root.cashewError === "" && root.cashewShown.length > 0 && cwRows.count === 0
          anchors.centerIn: cwList
          spacing: Style.space(10)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: cwLeft.width - Style.space(40)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: "No rows match the current filters."
            color: cashewWin.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          CashewBtn {
            anchors.horizontalCenter: parent.horizontalCenter
            label: "Clear filters"
            onClicked: {
              cashewWin.needOnly = false
              root.cashewGuessedOnly = false
            }
          }
        }
      }

      // ---- in-card picker (no popup)
      Item {
        id: cwPicker
        anchors.fill: parent
        visible: cashewWin.pickKind !== ""
        z: 20
        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: Qt.rgba(0, 0, 0, 0.5)
          MouseArea { anchors.fill: parent; onClicked: cashewWin.closePicker() }
        }
        Rectangle {
          id: cwPickBox
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(40), Style.space(560))
          height: Math.min(parent.height - Style.space(40), Style.space(440))
          radius: Style.space(12)
          color: Color.popups.background
          MouseArea { anchors.fill: parent; onClicked: {} }
          Rectangle { anchors.fill: parent; radius: parent.radius; color: Util.alpha(root.foreground, 0.07) }

          Text {
            id: cwPickTitle
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: Style.space(14) }
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: (cashewWin.pickKind === "category" ? "Category for " : (cashewWin.pickKind === "note" ? "Note for " : "Account for ")) + (cashewWin.pickDraft.title || "")
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // category: main column | subcategory column
          Row {
            visible: cashewWin.pickKind === "category"
            anchors { top: cwPickTitle.bottom; bottom: cwPickFoot.top; left: parent.left; right: parent.right; margins: Style.space(14) }
            spacing: Style.space(10)

            ListView {
              id: cwMainList
              width: (parent.width - parent.spacing) / 2
              height: parent.height
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds
              model: cashewWin.pickCats
              delegate: CashewPickRow {
                required property var modelData
                width: cwMainList.width
                text: modelData.name
                icon: (cashewWin.catMap[modelData.name] || ({})).icon || ""
                iconFill: (cashewWin.catMap[modelData.name] || ({})).color || "#37474F"
                selected: modelData.name === cashewWin.pickMain
                onPicked: {
                  var subs = modelData.subcategories || []
                  var name = modelData.name
                  if (subs.length === 0) cashewWin.pickCategory(name, "")
                  else cashewWin.pickMain = name
                }
              }
              ScrollWheelArea { anchors.fill: parent; target: cwMainList }
            }

            Flickable {
              id: cwSubFlick
              width: (parent.width - parent.spacing) / 2
              height: parent.height
              clip: true
              contentWidth: width
              contentHeight: cwSubFlow.height
              boundsBehavior: Flickable.StopAtBounds
              Flow {
                id: cwSubFlow
                width: parent.width
                spacing: Style.space(6)
                CashewChip {
                  visible: cashewWin.pickMain !== "" && cashewWin.pickSubs.length > 0
                  maxWidth: cwSubFlow.width
                  text: "No subcategory"
                  tint: "#455A64"
                  selected: cashewWin.pickMain === cashewWin.pickDraft.category && (cashewWin.pickDraft.subcategory || "") === ""
                  onClicked: cashewWin.pickCategory(cashewWin.pickMain, "")
                }
                Repeater {
                  model: cashewWin.pickSubs
                  delegate: CashewChip {
                    required property string modelData
                    maxWidth: cwSubFlow.width
                    text: modelData
                    tint: (cashewWin.catMap[cashewWin.pickMain] || ({})).color || "#455A64"
                    selected: modelData === cashewWin.pickDraft.subcategory && cashewWin.pickMain === cashewWin.pickDraft.category
                    onClicked: cashewWin.pickCategory(cashewWin.pickMain, modelData)
                  }
                }
              }
              ScrollWheelArea { anchors.fill: parent; target: cwSubFlick }
            }
          }

          // account list
          ListView {
            id: cwAcctList
            visible: cashewWin.pickKind === "account"
            anchors { top: cwPickTitle.bottom; bottom: cwPickFoot.top; left: parent.left; right: parent.right; margins: Style.space(14) }
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            model: cashewWin.pickKind === "account" ? root.cashewAccountNames : []
            delegate: CashewPickRow {
              required property string modelData
              width: cwAcctList.width
              text: modelData
              selected: modelData === cashewWin.pickDraft.account
              onPicked: cashewWin.pickAccount(modelData)
            }
            ScrollWheelArea { anchors.fill: parent; target: cwAcctList }
          }

          // note: multi-line editor, saved with the button or Ctrl+Enter
          Item {
            id: cwNoteBox
            visible: cashewWin.pickKind === "note"
            anchors { top: cwPickTitle.bottom; bottom: parent.bottom; left: parent.left; right: parent.right; margins: Style.space(14) }
            Rectangle {
              anchors { top: parent.top; bottom: cwNoteBtns.top; bottomMargin: Style.space(8); left: parent.left; right: parent.right }
              radius: Style.space(8)
              color: Util.alpha(root.foreground, 0.08)
              Loader {
                id: cwNoteLoader
                anchors { fill: parent; margins: Style.space(8) }
                active: cashewWin.pickKind === "note"
                sourceComponent: CashewNoteEditor {}
              }
            }
            Row {
              id: cwNoteBtns
              anchors { bottom: parent.bottom; left: parent.left }
              spacing: Style.space(8)
              CashewBtn { label: "Save"; primary: true; onClicked: cashewWin.saveNote(cwNoteLoader.item ? cwNoteLoader.item.text : "") }
              CashewBtn { label: "Cancel"; onClicked: cashewWin.closePicker() }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: cwNoteLoader.item ? cwNoteLoader.item.count + " / 500" : ""
                color: cwNoteLoader.item && cwNoteLoader.item.count > 500 ? root.debitColor : cashewWin.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            id: cwPickFoot
            visible: cashewWin.pickKind === "account" || (cashewWin.pickKind === "category" && cashewWin.pickDraft.kind !== "transfer")
            anchors { bottom: parent.bottom; left: parent.left; margins: Style.space(14) }
            height: Style.space(30)
            spacing: Style.space(8)
            CashewCheck {
              anchors.verticalCenter: parent.verticalCenter
              checked: cashewWin.pickRemember
              onToggled: cashewWin.pickRemember = !cashewWin.pickRemember
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: cashewWin.pickKind === "account"
                ? "Use for every ••" + (cashewWin.pickDraft.last4 || "") + " row"
                : "Remember for this merchant"
              color: cashewWin.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // Quiet tonal button, like the filter chips.
  component CashewBtn: BorderSurface {
    id: cb
    property string label: ""
    property bool primary: false
    property bool active: false
    // Visually prominent variant: taller, filled solid with the accent
    // colour, bordered, body-sized text. Used for the AI-guess trigger so it
    // reads as a distinct, important action rather than another small
    // header toggle like Options/Close (audit: not visually distinct).
    property bool big: false
    property color tint: "transparent"      // a set colour (e.g. green for "All categorised")
    signal clicked()
    readonly property bool _hot: cbMouse.containsMouse || cb.activeFocus
    height: cb.big ? Style.space(34) : Style.space(28)
    width: cbText.implicitWidth + (cb.big ? Style.space(30) : Style.space(22))
    radius: Style.space(8)
    opacity: !cb.enabled ? 0.4 : (cbMouse.pressed ? 0.7 : 1)
    color: cb.tint.a > 0 ? Util.alpha(cb.tint, cb._hot ? 0.34 : 0.26)
      : cb.big ? Util.alpha(Color.accent, cb._hot ? 0.58 : 0.44)
      : (cb.primary || cb.active) ? Util.alpha(Color.accent, cb._hot ? 0.28 : 0.20)
      : Util.alpha(root.foreground, cb._hot ? 0.13 : 0.06)
    borderSpec: cb.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent)
      : (cb.big ? Border.controlSpec("normal", Color.accent, Color.accent) : Border.none())
    activeFocusOnTab: cb.visible && cb.enabled
    Keys.onReturnPressed: if (cb.enabled) cb.clicked()
    Keys.onEnterPressed: if (cb.enabled) cb.clicked()
    Keys.onSpacePressed: if (cb.enabled) cb.clicked()
    Text {
      id: cbText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: cb.label
      color: cb.tint.a > 0 ? cb.tint
        : (cb.big || cb.primary || cb.active) ? Qt.tint(Color.accent, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75)) : root.foreground
      font.family: Style.font.family
      font.pixelSize: cb.big ? Style.font.body : Style.font.caption
      font.bold: cb.big || cb.primary || cb.active || cb.tint.a > 0
    }
    MouseArea {
      id: cbMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: cb.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: cb.clicked()
    }
  }

  // "Add all to Cashew": the button (Stop while it runs; Continue / Stop after a timeout) and the status line.
  component CashewSendControls: Column {
    id: csc
    property bool showNote: true
    spacing: Style.space(6)
    Flow {
      width: csc.width
      spacing: Style.space(6)
      CashewBtn {
        visible: !root.cashewSending && !root.cashewSendPaused
        primary: true
        enabled: root.cashewLinks.length > 0
        label: root.cashewVerifyArmed ? "Unverified AI · click again" : "Add all to Cashew"
        onClicked: root.cashewSendAll()
      }
      CashewBtn {
        visible: root.cashewSendPaused
        primary: true
        label: root.cashewSendDone + 1 < root.cashewSendItems.length ? "Continue" : "Finish"
        onClicked: root.cashewSendContinue()
      }
      CashewBtn {
        visible: root.cashewSending || root.cashewSendPaused
        active: root.cashewSending
        label: "■ Stop"
        onClicked: root.cashewSendStop()
      }
    }
    Text {
      visible: csc.showNote && root.cashewSendNote !== ""
      width: csc.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.cashewSendNote
      color: root.cashewSendPaused ? root.pendingColor : (root.cashewSending ? Color.accent : Qt.darker(root.foreground, 1.2))
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // The model runs in progress, one line each: "✦ AI categories · 12 of 40". Nothing when none runs.
  component LlmStatus: Column {
    id: ls
    visible: root.llmLines.length > 0
    spacing: Style.space(3)
    Repeater {
      model: root.llmLines
      delegate: Text {
        required property var modelData
        width: ls.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: "✦ " + modelData.label + "  ·  " + modelData.detail
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        SequentialAnimation on opacity {
          running: ls.visible
          loops: Animation.Infinite
          NumberAnimation { from: 1; to: 0.55; duration: 700 }
          NumberAnimation { from: 0.55; to: 1; duration: 700 }
        }
      }
    }
  }

  component CashewCheck: Rectangle {
    id: cc
    property bool checked: false
    property bool partial: false              // some, not all (the select-all checkbox): shows a dash
    signal toggled()
    width: Style.space(18)
    height: width
    radius: Style.space(5)
    color: cc.checked ? Util.alpha(Color.accent, 0.55) : Util.alpha(root.foreground, 0.14)
    activeFocusOnTab: cc.visible
    Keys.onSpacePressed: cc.toggled()
    Keys.onReturnPressed: cc.toggled()
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: "transparent"
      border.width: cc.activeFocus ? 2 : 0
      border.color: Color.accent
    }
    Text {
      anchors.centerIn: parent
      visible: cc.checked || cc.partial
      textFormat: Text.PlainText
      text: cc.checked ? "✓" : "–"
      color: root.foreground
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(4); cursorShape: Qt.PointingHandCursor; onClicked: cc.toggled() }
  }

  // Category, account or sub-category chip: a tonal pill, no border.
  component CashewChip: Rectangle {
    id: ch
    property string text: ""
    property bool warn: false
    property bool selected: false
    property color tint: "transparent"     // transparent = neutral
    property real maxWidth: 200
    signal clicked()
    readonly property bool _hot: chMouse.containsMouse || ch.activeFocus
    readonly property bool hovered: chMouse.containsMouse
    height: Style.space(24)
    width: Math.min(ch.maxWidth, chText.implicitWidth + Style.space(18))
    radius: height / 2
    color: ch.selected ? Util.alpha(Color.accent, ch._hot ? 0.40 : 0.32)
      : ch.warn ? Util.alpha(root.pendingColor, ch._hot ? 0.34 : 0.24)
      : ch.tint.a > 0 ? Util.alpha(ch.tint, ch._hot ? 0.80 : 0.62)
      : Util.alpha(root.foreground, ch._hot ? 0.18 : 0.10)
    activeFocusOnTab: ch.visible
    Keys.onReturnPressed: ch.clicked()
    Keys.onEnterPressed: ch.clicked()
    Keys.onSpacePressed: ch.clicked()
    Text {
      id: chText
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; right: parent.right; leftMargin: Style.space(9); rightMargin: Style.space(9) }
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: ch.text
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: ch.selected
    }
    MouseArea { id: chMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.clicked() }
  }

  // Round category icon: a flat colour with the emoji on it.
  component CashewIcon: Rectangle {
    id: ci
    property string icon: ""
    property color fill: "#37474F"
    property bool warn: false
    width: Style.space(44)
    height: width
    radius: width / 2
    // Border only: a ring and a thin glyph in one tone, lightened so the
    // category colours (dark on dark) stay readable.
    readonly property color tone: Qt.lighter(ci.fill, 1.9)
    color: "transparent"
    border.width: 1.5
    border.color: ci.tone
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ci.icon
      color: ci.tone
      font.family: "JetBrainsMono Nerd Font"
      font.pixelSize: Math.round(ci.width * 0.48)
    }
    Rectangle {
      visible: ci.warn
      anchors { right: parent.right; top: parent.top }
      width: Math.round(ci.width * 0.26)
      height: width
      radius: width / 2
      color: root.pendingColor
      border.width: 2
      border.color: Color.popups.background
    }
  }

  // One leg of a transfer card: [account chip] ---- [date] [note] ▾/▴ amount.
  component CashewLeg: Item {
    id: lg
    property int idx: -1
    property string cardDate: ""
    property bool hot: false
    readonly property var d: root.cashewDrafts[lg.idx] || ({})
    readonly property bool credit: String(lg.d.amount || "").charAt(0) !== "-"
    height: Style.space(26)

    CashewChip {
      id: lgAcct
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      maxWidth: Style.space(150)
      tint: "#455A64"
      text: (lg.d.account || "") !== "" ? lg.d.account : "No account"
      warn: (lg.d.account || "") === ""
      onClicked: cashewWin.openPicker("account", lg.idx)
    }
    // Same right edge as a plain row: the amount stops where a row's amount stops,
    // and the edit button sits where a row's buttons sit.
    PanelActionButton {
      id: lgEdit
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      size: Style.space(24)
      iconText: "✎"
      tooltipText: "Edit note"
      foreground: root.foreground
      bordered: false
      focusable: false
      opacity: lg.hot ? 1.0 : 0.55
      onClicked: cashewWin.openPicker("note", lg.idx)
    }
    CashewCell {
      id: lgAmount
      anchors { right: parent.right; rightMargin: Style.space(62); verticalCenter: parent.verticalCenter }
      width: Style.space(120)
      implicitHeight: Style.space(26)
      kind: "amount"
      alignRight: true
      bold: true
      pixelSize: Style.font.body + 1
      value: lg.d.amount || ""
      display: (lg.credit ? "▴ " : "▾ ") + Model.cashewMoney(lg.d.amount)
      color: lg.credit ? root.creditColor : root.debitColor
      onCommit: function (v) { root.cashewEdit(Model.cashewPatch(root.cashewDrafts, lg.idx, { amount: v }), true) }
    }
    CashewCell {
      id: lgDate
      visible: (lg.d.date || "") !== lg.cardDate        // only a leg dated differently shows its date
      anchors { right: lgAmount.left; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
      width: Style.space(96)
      alignRight: true
      kind: "date"
      value: lg.d.date || ""
      color: cashewWin.muted
      onCommit: function (v) { root.cashewEdit(Model.cashewPatch(root.cashewDrafts, lg.idx, { date: v }), true) }
    }
    // Between the account and the amount: the first line of the note, or a thin rule.
    Item {
      id: lgNoteBox
      height: Style.space(22)
      anchors { left: lgAcct.right; leftMargin: Style.space(10); right: lgDate.visible ? lgDate.left : lgAmount.left; rightMargin: Style.space(10); verticalCenter: parent.verticalCenter }
    }
    CashewNote {
      id: lgNote
      width: lgNoteBox.width
      anchors { left: lgNoteBox.left; verticalCenter: lgNoteBox.verticalCenter }
      text: lg.d.notes || ""
      hot: lg.hot
      onClicked: cashewWin.openPicker("note", lg.idx)
    }
    Rectangle {
      visible: !lgNote.has && !lg.hot
      anchors { left: lgNoteBox.left; right: lgNoteBox.right; verticalCenter: parent.verticalCenter }
      height: 1
      color: Util.alpha(root.foreground, 0.16)
    }
  }

  // The note of a draft: a small note icon (plus the first line when there is room)
  // only when a note exists; a muted "+ note" while the row is hovered otherwise.
  component CashewNote: Item {
    id: cn
    property string text: ""
    property bool hot: false
    property bool compact: false          // icon only
    signal clicked()
    readonly property bool has: cn.text !== ""
    implicitHeight: Style.space(24)
    implicitWidth: cn.has ? Style.space(26) : (cn.hot ? Style.space(52) : 0)
    width: cn.compact ? cn.implicitWidth : implicitWidth
    height: implicitHeight
    Rectangle {
      id: cnIcon
      visible: cn.has
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      width: Style.space(22)
      height: Style.space(20)
      radius: Style.space(6)
      color: Util.alpha("#5C7C9C", cnMouse.containsMouse ? 0.95 : 0.8)
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: "≡"
        color: "#EAF1F8"
        font.family: Style.font.family
        font.pixelSize: Style.font.caption + 2
        font.bold: true
      }
    }
    Text {
      visible: cn.has && !cn.compact
      anchors { left: cnIcon.right; leftMargin: Style.space(8); right: parent.right; verticalCenter: parent.verticalCenter }
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: cn.text.split("\n")[0] + (cn.text.indexOf("\n") >= 0 ? "  …" : "")
      color: cashewWin.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      visible: !cn.has && cn.hot
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      text: "+ note"
      color: Qt.darker(root.foreground, cnMouse.containsMouse ? 1.1 : 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: cnMouse
      anchors.fill: parent
      enabled: cn.has || cn.hot
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: cn.clicked()
    }
  }

  // Multi-line note editor, created only while the note picker is open.
  component CashewNoteEditor: Flickable {
    id: ne
    readonly property alias text: neArea.text
    readonly property int count: neArea.length
    clip: true
    contentWidth: width
    contentHeight: Math.max(height, neArea.implicitHeight)
    boundsBehavior: Flickable.StopAtBounds
    TextArea.flickable: TextArea {
      id: neArea
      wrapMode: TextEdit.Wrap
      selectByMouse: true
      color: root.foreground
      selectionColor: Util.alpha(Color.accent, 0.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      background: null
      Component.onCompleted: {
        neArea.text = cashewWin.pickDraft.notes || ""
        neArea.forceActiveFocus()
        neArea.cursorPosition = neArea.length
      }
      Keys.onEscapePressed: function (event) { event.accepted = true; cashewWin.closePicker() }
      Keys.onPressed: function (event) {
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
          event.accepted = true
          cashewWin.saveNote(neArea.text)
        }
      }
    }
  }

  component CashewPickRow: Rectangle {
    id: pr
    property string text: ""
    property bool selected: false
    property bool dim: false
    property string icon: ""
    property color iconFill: "#37474F"
    signal picked()
    height: pr.icon !== "" ? Style.space(34) : Style.space(28)
    radius: Style.space(8)
    color: pr.selected ? Util.alpha(pr.icon !== "" ? pr.iconFill : Color.accent, pr.icon !== "" ? 0.50 : 0.24) : Util.alpha(root.foreground, prMouse.containsMouse || pr.activeFocus ? 0.12 : 0.0)
    activeFocusOnTab: pr.visible
    Keys.onReturnPressed: pr.picked()
    Keys.onEnterPressed: pr.picked()
    Keys.onSpacePressed: pr.picked()
    CashewIcon {
      id: prIcon
      visible: pr.icon !== ""
      anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: Style.space(6) }
      width: Style.space(26)
      icon: pr.icon
      fill: pr.iconFill
    }
    Text {
      anchors { verticalCenter: parent.verticalCenter; left: pr.icon !== "" ? prIcon.right : parent.left; right: parent.right; leftMargin: Style.space(pr.icon !== "" ? 8 : 10); rightMargin: Style.space(10) }
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: pr.text
      color: pr.dim ? Qt.darker(root.foreground, 1.2) : root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: pr.selected
    }
    MouseArea { id: prMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pr.picked() }
  }

  // One editable value in a draft row. Click (or Enter) edits; Enter or
  // leaving the field commits, Esc aborts. Everything is read before the
  // editor is switched off, because switching it off destroys the TextField.
  component CashewCell: Item {
    id: cell
    property string value: ""
    property string kind: "text"          // text | date | amount
    property string placeholder: ""
    property bool alignRight: false
    property bool bold: false
    property int pixelSize: Style.font.caption
    property string display: ""           // shown instead of value when not editing
    property color color: root.foreground
    property bool editing: false
    property bool bad: false
    signal commit(string value)
    implicitHeight: Style.space(22)
    height: implicitHeight
    activeFocusOnTab: !cell.editing
    Keys.onReturnPressed: cell.startEditing()
    Keys.onEnterPressed: cell.startEditing()

    function startEditing() {
      cell.bad = false
      cell.editing = true
    }
    function normalised(typed) {
      if (cell.kind === "date") return Model.cashewValidDate(typed) ? typed.trim() : null
      if (cell.kind === "amount") return Model.cashewNormAmount(typed)
      return typed.trim()
    }
    function finish(refocus) {
      if (!cell.editing || !edLoader.item) return
      var typed = edLoader.item.text
      var next = cell.normalised(typed)
      if (next === null) { cell.bad = true; return }
      var changed = next !== cell.value
      cell.editing = false
      if (refocus) cashewCard.forceActiveFocus()
      if (changed) cell.commit(next)
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.space(5)
      color: Util.alpha(root.foreground, cell.activeFocus ? 0.12 : (cellMouse.containsMouse ? 0.07 : 0))
    }
    Text {
      visible: !cell.editing
      anchors { fill: parent; leftMargin: Style.space(4); rightMargin: Style.space(4) }
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: cell.alignRight ? Text.AlignRight : Text.AlignLeft
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: cell.value !== "" ? (cell.display !== "" ? cell.display : cell.value) : cell.placeholder
      color: cell.value !== "" ? cell.color : Qt.darker(root.foreground, 1.6)
      font.family: Style.font.family
      font.pixelSize: cell.pixelSize
      font.bold: cell.bold
    }
    MouseArea {
      id: cellMouse
      anchors.fill: parent
      hoverEnabled: true
      visible: !cell.editing
      cursorShape: Qt.IBeamCursor
      onClicked: cell.startEditing()
    }
    Loader {
      id: edLoader
      anchors.fill: parent
      active: cell.editing
      sourceComponent: TextField {
        text: cell.value
        horizontalAlignment: cell.alignRight ? TextInput.AlignRight : TextInput.AlignLeft
        color: cell.bad ? root.debitColor : root.foreground
        font.family: Style.font.family
        font.pixelSize: cell.pixelSize
        topPadding: 0
        bottomPadding: 0
        background: Rectangle {
          radius: Style.space(5)
          color: Util.alpha(Color.accent, 0.12)
          border.width: 1
          border.color: cell.bad ? root.debitColor : Util.alpha(Color.accent, 0.6)
        }
        Component.onCompleted: { forceActiveFocus(); selectAll() }
        onTextChanged: cell.bad = false
        onAccepted: cell.finish(true)
        onEditingFinished: cell.finish(false)
        Keys.onEscapePressed: function (event) {
          event.accepted = true
          cell.editing = false
          cashewCard.forceActiveFocus()
        }
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

  // Three small dots: how sure the match is (filled = accent, empty = faint).
  component PipMeter: Row {
    id: pm
    property int count: 0
    property int total: 3
    spacing: Style.space(3)
    Repeater {
      model: pm.total
      delegate: Rectangle {
        required property int index
        width: Style.space(6)
        height: width
        radius: width / 2
        color: index < pm.count ? Color.accent : Util.alpha(Color.accent, 0.25)
      }
    }
  }

  // A small rounded tag ("SAME REFERENCE", "NEW").
  component TagPill: Rectangle {
    id: tp
    property string label: ""
    property color tone: Color.accent
    property bool solid: false
    radius: Style.space(4)
    color: tp.solid ? tp.tone : Util.alpha(tp.tone, 0.22)
    implicitWidth: tpText.implicitWidth + Style.space(10)
    implicitHeight: tpText.implicitHeight + Style.space(4)
    Text {
      id: tpText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tp.label
      color: tp.solid ? Color.popups.background : tp.tone
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: Style.font.caption
    }
  }

  // A ring tile for the category picker: glyph on top, name under it.
  component CatTile: Rectangle {
    id: ct
    property string glyph: ""
    property string label: ""
    property color tint: Color.accent
    property bool selected: false
    property bool primary: false
    property bool marked: false          // the AI suggested this one
    signal clicked()
    height: Style.space(60)
    radius: Style.space(10)
    color: ctMouse.containsMouse ? Util.alpha(ct.tint, 0.16) : (ct.primary ? Util.alpha(ct.tint, 0.08) : "transparent")
    border.width: ct.selected ? 2 : 1
    border.color: ct.selected ? Color.accent : Util.alpha(ct.tint, ctMouse.containsMouse ? 0.9 : 0.5)
    Behavior on color { ColorAnimation { duration: 100 } }
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: Style.space(3)
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: ct.glyph
        color: ct.tint
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.font.title
      }
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: ct.label
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption - 1
      }
    }
    Text {
      visible: ct.marked
      anchors { top: parent.top; right: parent.right; topMargin: Style.space(3); rightMargin: Style.space(6) }
      textFormat: Text.PlainText
      text: "✦"
      color: Color.accent
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: ctMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ct.clicked()
    }
  }

  // A small text button for the transaction edit panel.
  component TxnBtn: BorderSurface {
    id: tb
    property string label: ""
    property bool primary: false
    signal clicked()
    height: Style.space(26)
    width: tbText.implicitWidth + Style.space(18)
    radius: Style.space(7)
    opacity: !tb.enabled ? 0.4 : (tbMouse.pressed ? 0.7 : 1)
    color: tb.primary ? Util.alpha(Color.accent, tbMouse.containsMouse ? 0.34 : 0.24)
      : Util.alpha(root.foreground, tbMouse.containsMouse ? 0.14 : 0.07)
    borderSpec: Border.none()
    Text {
      id: tbText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tb.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: tbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tb.clicked()
    }
  }

  // The "i" button at the far right of a card.
  component InfoButton: PanelActionButton {
    id: ib
    property bool infoShown: false
    size: Style.space(24)
    iconText: "󰋽"
    tooltipText: "Explain"
    foreground: ib.infoShown ? Color.accent : root.foreground
    bordered: false
    focusable: false
  }

  // An AcctPill in a frame; a side that is not in the data gets a dashed amber frame.
  component PillSlot: Item {
    id: ps
    required property var txn
    property real maxWidth: 100000
    implicitWidth: psPill.implicitWidth + Style.space(8)
    implicitHeight: psPill.implicitHeight + Style.space(6)
    width: implicitWidth
    height: implicitHeight
    Canvas {
      anchors.fill: parent
      visible: !!ps.txn.ghost
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onVisibleChanged: requestPaint()
      onPaint: {
        var g = getContext("2d")
        g.reset()
        g.strokeStyle = root.pendingColor
        g.lineWidth = 1
        g.setLineDash([3, 2])
        g.strokeRect(0.5, 0.5, width - 1, height - 1)
      }
    }
    AcctPill {
      id: psPill
      anchors.centerIn: parent
      txn: ps.txn
      maxWidth: ps.maxWidth - Style.space(8)
    }
  }

  // The "i" panel: a bordered box inside the card (never a Popup, which would
  // draw outside the widget). `info` comes from Model.transferExplain / txnExplain.
  component InfoSection: Item {
    id: inf
    property var info: null
    property bool open: false
    readonly property bool shown: inf.open && !!inf.info
    visible: inf.shown
    implicitHeight: inf.shown ? infBox.implicitHeight + Style.space(6) : 0
    height: implicitHeight

    Rectangle {
      id: infBox
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      radius: Style.space(6)
      color: Util.alpha(root.foreground, 0.06)
      border.width: 1
      border.color: Util.alpha(root.foreground, 0.18)
      implicitHeight: infCol.implicitHeight + Style.space(16)

      Column {
        id: infCol
        x: Style.space(8)
        y: Style.space(8)
        width: parent.width - Style.space(16)
        spacing: Style.space(4)

        Row {
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: inf.info ? inf.info.glyph : ""
            color: Color.accent
            font.pixelSize: Style.font.body
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: inf.info ? inf.info.title : ""
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!inf.info && inf.info.certainty !== ""
            textFormat: Text.PlainText
            text: inf.info ? "·  " + inf.info.certainty : ""
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: inf.info ? inf.info.rows : []
          delegate: Item {
            id: infRow
            required property var modelData
            width: infCol.width
            height: Math.max(infKey.implicitHeight, infVal.implicitHeight)
            Text {
              id: infKey
              width: Style.space(84)
              textFormat: Text.PlainText
              text: infRow.modelData.k
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              id: infVal
              anchors.left: infKey.right
              anchors.right: parent.right
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              text: infRow.modelData.v
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: !!inf.info && inf.info.why !== ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: inf.info ? "Why: " + inf.info.why : ""
          color: Qt.darker(root.foreground, 1.2)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: !!inf.info && inf.info.next !== ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: inf.info ? "Next step: " + inf.info.next : ""
          color: root.pendingColor
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // A bank logo + the account tag ("HDFC ••7367"), the way a transaction card
  // draws the account its row sits in.
  component AcctPill: Row {
    id: ap
    required property var txn
    // The most this chip (logo + tag) may take; the tag's text is elided to fit
    // rather than running under whatever sits beside it.
    property real maxWidth: 100000
    spacing: Style.space(6)
    readonly property bool isSavings: ap.txn.accountType === "checking" && (ap.txn.bank === "AXIS" || ap.txn.bank === "SBI")
    readonly property string accountName: ap.txn.ghost ? "" : Model.accountChipText(ap.txn, store.cardOverviews, store.accountNameOverrides)

    BrandMark {
      network: Model.cardNetwork(ap.txn, store.cardOverviews)
      markHeight: Style.spaceReal(9)
      anchors.verticalCenter: parent.verticalCenter
    }
    HdfcLogo {
      variant: "icon"
      visible: ap.txn.accountType === "checking" && ap.txn.bank === "HDFC"
      markSize: Style.spaceReal(9)
      anchors.verticalCenter: parent.verticalCenter
    }
    AxisLogo {
      visible: ap.txn.accountType === "checking" && ap.txn.bank === "AXIS"
      markSize: Style.spaceReal(9)
      anchors.verticalCenter: parent.verticalCenter
    }
    SbiLogo {
      visible: ap.txn.accountType === "checking" && ap.txn.bank === "SBI"
      markSize: Style.spaceReal(9)
      anchors.verticalCenter: parent.verticalCenter
    }
    Rectangle {
      radius: Style.space(4)
      color: Util.alpha(root.foreground, 0.12)
      implicitWidth: Math.min(apText.implicitWidth + Style.space(10), Math.max(Style.space(36), ap.maxWidth - Style.space(26)))
      implicitHeight: apText.implicitHeight + Style.space(4)
      Text {
        id: apText
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(5)
        anchors.rightMargin: Style.space(5)
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: ap.txn.ghost ? (ap.txn.bank || "Other account") : ap.accountName
        // A side that is not in your statements: the bank's name, dimmed and
        // in italics instead of a ••last4 (which is not known).
        color: ap.txn.ghost ? Qt.darker(root.foreground, 1.4) : root.foreground
        font.family: Style.font.family
        font.italic: !!ap.txn.ghost
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Money that moved between two of your own accounts, drawn as ONE card in
  // its own colour with a TRANSFER tag and "from -> to": both sides of it
  // (the debit in one bank, the credit in the other) are folded together by
  // txdb/transfers.py. Click to track both sides; open it (chevron, circle or
  // the arrow keys) to look at each side - its own statement text, date,
  // amount and balance - and, if the pairing is wrong, split it back into two
  // ordinary transactions.
  component TransferCard: BorderSurface {
    id: xc
    required property var transfer
    // This row's index in the virtualized RECENT ListView (txnList), -1
    // when not inside it (there is no other caller right now, but the
    // default keeps the component usable standalone). Lets Up/Down
    // force the neighbouring row to exist before walking the focus
    // chain onto it — see root.focusNextInList.
    property int rowIndex: -1
    property bool expanded: false
    readonly property var outLeg: xc.transfer.out
    readonly property var inLeg: xc.transfer.in
    readonly property color tone: Color.accent
    readonly property bool _hot: xHover.hovered || xc.activeFocus
    readonly property int collapsedHeight: Style.space(56)
    readonly property var amountLeg: xc.transfer.oneSided ? xc.transfer.real : xc.outLeg
    readonly property var legsList: xc.transfer.oneSided ? [xc.transfer.real] : [xc.outLeg, xc.inLeg]
    readonly property var meta: Model.transferMeta(Model.transferKind(xc.transfer))
    readonly property string infoId: "t:" + xc.transfer.id
    readonly property bool infoOpen: root.infoOpenId === xc.infoId
    function toggleInfo() { root.infoOpenId = xc.infoOpen ? "" : xc.infoId }

    implicitHeight: xc.collapsedHeight + xInfo.height + (xc.expanded ? xDetails.implicitHeight + Style.space(12) : 0)
    radius: Style.cornerRadius
    opacity: xMouse.pressed ? 0.75 : 1.0
    color: xc.transfer.tracked ? Util.alpha(xc.tone, 0.18)
      : (xc._hot ? Util.alpha(xc.tone, 0.14) : Util.alpha(xc.tone, 0.07))
    borderSpec: xc.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.flat(Util.alpha(xc.tone, 0.45), 1)

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on opacity { NumberAnimation { duration: 80 } }

    HoverHandler { id: xHover }

    function toggleTracked() { store.setTrackedMany(xc.legsList, !xc.transfer.tracked) }

    activeFocusOnTab: true
    Keys.onReturnPressed: xc.toggleTracked()
    Keys.onEnterPressed: xc.toggleTracked()
    Keys.onSpacePressed: xc.toggleTracked()
    Keys.onUpPressed: root.focusNextInList(xc, false)
    Keys.onDownPressed: root.focusNextInList(xc, true)
    Keys.onLeftPressed: xc.expanded = false
    Keys.onRightPressed: xc.expanded = true
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_I) { xc.toggleInfo(); event.accepted = true }
      else if (event.key === Qt.Key_Escape && xc.infoOpen) { root.infoOpenId = ""; event.accepted = true }
    }

    Item {
      id: xRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: xc.collapsedHeight

      MouseArea {
        id: xMouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: xc.toggleTracked()
      }

      Rectangle {
        id: xAvatar
        width: Style.space(36)
        height: width
        radius: width / 2
        color: Util.alpha(xc.tone, 0.28)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: xc.expanded = !xc.expanded
        }
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: xc.meta.glyph
          color: xc.tone
          font.pixelSize: Style.font.subtitle
        }
      }

      Column {
        anchors.left: xAvatar.right
        anchors.leftMargin: Style.space(10)
        anchors.right: xAmount.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Row {
          id: xTitle
          width: parent.width
          spacing: Style.space(8)
          clip: true
          Text {
            // Gives way (elides) before the tag, the dots or the NEW mark do.
            width: Math.max(0, Math.min(implicitWidth, xTitle.width - xTag.width - xPips.width - xNew.width
              - (xPips.visible ? xTitle.spacing : 0) - (xNew.visible ? xTitle.spacing : 0) - xTitle.spacing))
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: "Transfer"
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.subtitle
          }
          TagPill {
            id: xTag
            anchors.verticalCenter: parent.verticalCenter
            label: xc.meta.tag
            tone: root.toneColor(xc.meta.tone)
          }
          PipMeter {
            id: xPips
            visible: xc.meta.pips > 0
            anchors.verticalCenter: parent.verticalCenter
            count: xc.meta.pips
          }
          TagPill {
            id: xNew
            visible: !!xc.transfer.isNew
            anchors.verticalCenter: parent.verticalCenter
            label: "NEW"
            tone: Color.accent
            solid: true
          }
        }

        Row {
          id: xFlow
          width: parent.width
          spacing: Style.space(6)
          clip: true
          PillSlot { txn: xc.outLeg; maxWidth: (xFlow.width - xArrow.width - 2 * xFlow.spacing) / 2; anchors.verticalCenter: parent.verticalCenter }
          Text {
            id: xArrow
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "→"
            color: xc.tone
            font.bold: true
            font.pixelSize: Style.font.body
          }
          PillSlot { txn: xc.inLeg; maxWidth: (xFlow.width - xArrow.width - 2 * xFlow.spacing) / 2; anchors.verticalCenter: parent.verticalCenter }
        }
      }

      InfoButton {
        id: xInfoBtn
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        infoShown: xc.infoOpen
        onClicked: xc.toggleInfo()
      }

      Column {
        id: xAmount
        anchors.right: xInfoBtn.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          // Neutral: money that only moved between your own accounts has no +/-.
          text: Model.currencySymbol(xc.amountLeg.currency) + Model.formatGrouped(Math.abs(xc.amountLeg.amount))
          color: root.foreground
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }
      }
    }

    InfoSection {
      id: xInfo
      anchors.top: xRow.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      open: xc.infoOpen
      info: xc.infoOpen ? Model.transferExplain(xc.transfer, { lastFetched: store.lastFetched }) : null
    }

    Column {
      id: xDetails
      visible: xc.expanded
      anchors.top: xInfo.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(46)
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(6)

      Rectangle { width: parent.width; height: Style.spacing.hairline; color: Util.alpha(xc.tone, 0.5) }

      Repeater {
        model: [
          { role: "OUT", leg: xc.outLeg, color: root.debitColor },
          { role: "IN", leg: xc.inLeg, color: root.creditColor },
        ]
        delegate: Column {
          id: legCol
          required property var modelData
          width: parent.width
          spacing: Style.space(3)

          Row {
            spacing: Style.space(8)
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.space(4)
              color: Util.alpha(legCol.modelData.color, 0.22)
              implicitWidth: legTag.implicitWidth + Style.space(10)
              implicitHeight: legTag.implicitHeight + Style.space(4)
              Text {
                id: legTag
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: legCol.modelData.role
                color: legCol.modelData.color
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: Style.font.caption
              }
            }
            AcctPill { txn: legCol.modelData.leg; anchors.verticalCenter: parent.verticalCenter }
            Text {
              visible: !legCol.modelData.leg.ghost
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.formatAmount(legCol.modelData.leg)
              color: legCol.modelData.color
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            visible: !!legCol.modelData.leg.ghost
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "This side is not in your statements - it is older than what is fetched, or another account. "
              + "The amount is the same."
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !legCol.modelData.leg.ghost
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            text: Model.formatFullDate(legCol.modelData.leg.date) + "  ·  " + legCol.modelData.leg.merchant
            color: Qt.darker(root.foreground, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !legCol.modelData.leg.ghost && legCol.modelData.leg.balance !== null && legCol.modelData.leg.balance !== undefined
            textFormat: Text.PlainText
            text: "balance after: " + Model.currencySymbol(legCol.modelData.leg.currency)
              + Model.formatGrouped(legCol.modelData.leg.balance)
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Not counted as spending or income."
        color: Qt.darker(root.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Flow {
        width: parent.width
        spacing: Style.space(10)
        TextAction {
          label: xc.transfer.oneSided ? (xc.transfer.tracked ? "Untrack" : "Track") : (xc.transfer.tracked ? "Untrack both" : "Track both")
          onTriggered: xc.toggleTracked()
        }
        TextAction {
          label: "Not a transfer"
          onTriggered: root.txdb(["transfer-split"].concat(xc.legsList.map(function (l) { return l.id })))
        }
      }
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
    // See TransferCard.rowIndex above — same purpose.
    property int rowIndex: -1

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
    readonly property string accountName: Model.accountChipText(txn, store.cardOverviews, store.accountNameOverrides)
    readonly property string note: Model.transactionNote(txn)
    readonly property string userNote: store.txnNotes[card.txn.id] || ""
    // The note of this payment: the one written in the widget, else the UPI remark ("BATMINTON"). It is the
    // note everywhere (the row, the "i" card, the editor, Cashew), before and after the AI looks at it.
    readonly property string effectiveNote: card.userNote !== "" ? card.userNote : card.note
    // The note mark opens a peek: the note alone as a sticky note, or stuck to its bill. Not the editor.
    property bool peekOpen: false
    onEditingChanged: if (card.editing) card.peekOpen = false
    // Content slides left by this much while the pointer is over the row, which
    // reveals the "i" and edit buttons at the right edge.
    property real slide: (card._hot || card.infoOpen) && !card.editing ? Style.space(62) : 0
    Behavior on slide { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    // The edit panel is a Loader that unloads when editing ends, so a callLater closure written
    // inside it would run after its own context is gone ("card is not defined"). This one lives on the card.
    function refocus() { Qt.callLater(function () { card.forceActiveFocus() }) }
    function saveEdit() {
      store.setTransactionName(card.groupKey, (editFieldLoader.item ? editFieldLoader.item.text : ""))
      // noteArea lives inside the lazily built edit panel, so it is read through the Loader.
      var noteText = editLoader.item ? editLoader.item.noteText : card.effectiveNote
      // Saved only when it differs from what is shown: an untouched remark stays the remark.
      if (noteText.trim() !== card.effectiveNote.trim()) store.setTxnNote(card.txn.id, noteText)
      card.editing = false
      card.refocus()
    }
    // The bill filed against this transaction, if any - its note icon opens it.
    readonly property var linkedReceipt: Model.linkedReceiptForTransaction(txn, store.receipts)
    readonly property bool isDebit: txn.amount < 0
    // A credit linked to the purchase it refunds (refundOf is "" when that purchase is not in the data).
    readonly property bool isRefundCredit: card.txn.refundOf !== undefined
    readonly property color directionColor: root.directionColor(txn)
    readonly property bool _hot: rowHover.hovered || card.activeFocus
    readonly property int collapsedHeight: Style.space(52)
    readonly property string infoId: "x:" + card.txn.id
    readonly property bool infoOpen: root.infoOpenId === card.infoId && !card.editing
    function toggleInfo() { root.infoOpenId = root.infoOpenId === card.infoId ? "" : card.infoId }

    implicitHeight: card.collapsedHeight + cInfo.height + (card.peekOpen ? peekLoader.height + Style.space(10) : 0) + (card.editing ? editLoader.implicitHeight + Style.space(10) : 0) + (card.showDetails ? detailsLoader.implicitHeight + Style.space(10) : 0)
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
      else if (event.key === Qt.Key_I) { card.toggleInfo(); event.accepted = true }
      else if (event.key === Qt.Key_Escape && card.infoOpen) { root.infoOpenId = ""; event.accepted = true }
    }
    Keys.onUpPressed: if (!card.editing) root.focusNextInList(card, false)
    Keys.onDownPressed: if (!card.editing) root.focusNextInList(card, true)
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
        // Border only: a ring in the direction colour, nothing filled.
        color: "transparent"
        border.width: 1.5
        border.color: Util.alpha(card.directionColor, 0.85)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX + (card.selectable && root.selectionMode ? Style.space(24) : 0)
        anchors.verticalCenter: parent.verticalCenter

        // The circle carries the category: its icon inside, the first three
        // letters of the subcategory in a badge on the lower-right edge. The
        // colour still says out / in / transfer. A transfer keeps its own
        // mark; a row with no category shows its direction arrow, dimmed.
        readonly property bool hasCategory: !root.isTransferLeg(card.txn) && !!card.txn.category
        readonly property string categoryIcon: avatar.hasCategory ? Model.categoryIcon(card.txn.category, store.receiptCategories) : ""
        readonly property string subIcon: avatar.hasCategory ? Model.subcategoryIcon(card.txn.category, card.txn.subcategory, store.receiptCategories) : ""

        // Clicking the circle expands or collapses the details below.
        MouseArea {
          id: avatarMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          enabled: !card.editing
          cursorShape: Qt.PointingHandCursor
          onClicked: card.expanded = !card.expanded
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.isTransferLeg(card.txn) ? "⇄" : (avatar.categoryIcon !== "" ? avatar.categoryIcon : (card.isDebit ? "↓" : "↑"))
          color: card.directionColor
          opacity: root.isTransferLeg(card.txn) || avatar.hasCategory ? 1.0 : 0.6
          font.family: avatar.categoryIcon !== "" ? "JetBrainsMono Nerd Font" : Style.font.family
          font.bold: avatar.categoryIcon === ""
          font.pixelSize: avatar.categoryIcon !== "" ? Style.font.title : Style.font.subtitle
        }

        // The subcategory's symbol, in a small ring on the lower-right edge.
        Rectangle {
          id: subBadgeRect
          visible: avatar.subIcon !== ""
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: -Style.space(5)
          anchors.bottomMargin: -Style.space(4)
          width: Style.space(16)
          height: width
          radius: width / 2
          color: Color.background
          border.width: 1.5
          border.color: Util.alpha(card.directionColor, 0.85)

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: avatar.subIcon
            color: card.directionColor
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: Style.space(10)
          }
        }

        ToolTip.visible: avatarMouse.containsMouse && avatar.hasCategory
        ToolTip.text: card.txn.category + (card.txn.subcategory ? "  ›  " + card.txn.subcategory : "")
        ToolTip.delay: 300
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

        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: Math.min(implicitWidth, parent.width - (noteIconSlot.visible ? noteIconSlot.width + parent.spacing : 0) - (refundSlot.visible ? refundSlot.width + parent.spacing : 0)
              - (inCashewSlot.visible ? inCashewSlot.width + parent.spacing : 0))
            textFormat: Text.PlainText
            text: card.displayMerchant
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
          }
          // Cashew already has this payment (same amount and account, the date up to 4 days off)
          Item {
            id: inCashewSlot
            visible: card.txn.inCashew === true
            width: Style.space(16)
            height: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            readonly property var mark: Model.cashewMark(card.txn, !!root.cashewEditedIds[card.txn.id])
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: inCashewSlot.mark.glyph
              color: Util.alpha(inCashewSlot.mark.tone === "pending" ? root.pendingColor : root.creditColor, inCashewHover.hovered ? 1 : 0.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            HoverHandler { id: inCashewHover }
            ToolTip.visible: inCashewHover.hovered
            ToolTip.text: inCashewSlot.mark.tooltip
            ToolTip.delay: 300
          }
          Item {
            id: noteIconSlot
            // A bill, a note, or both: one mark each (TxnMark.qml, icons/*.svg).
            readonly property bool hasBill: !!card.linkedReceipt
            readonly property bool hasNote: card.effectiveNote !== ""
            visible: hasBill || hasNote
            width: Style.space(20)
            height: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
              anchors.fill: parent
              radius: Style.space(5)
              color: noteMouse.containsMouse ? Util.alpha(root.foreground, 0.14) : Util.alpha(root.foreground, 0.06)
              TxnMark {
                anchors.centerIn: parent
                markSize: Style.space(16)
                kind: noteIconSlot.hasBill && noteIconSlot.hasNote ? "both" : (noteIconSlot.hasBill ? "bill" : "note")
                billColor: root.creditColor
                noteColor: Color.accent
              }
              MouseArea {
                id: noteMouse
                anchors.fill: parent
                anchors.margins: -Style.space(3)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                preventStealing: true
                // The peek shows the note, the bill, or both (see peekLoader).
                onClicked: card.peekOpen = !card.peekOpen     // note, bill, or both: the peek; "Open bill" opens the window
              }
              ToolTip.visible: noteMouse.containsMouse
              ToolTip.text: (noteIconSlot.hasBill ? "Bill: " + Model.receiptTitle(card.linkedReceipt || {}) + " — open" : "")
                + (noteIconSlot.hasBill && noteIconSlot.hasNote ? "\n" : "")
                + (noteIconSlot.hasNote ? "Note: " + card.effectiveNote : "")
              ToolTip.delay: 300
            }
          }
          // A refund: this credit gives back an earlier purchase, or this purchase has been (or is
          // waiting to be) refunded. Click opens the row, where the link is shown and changed.
          Item {
            id: refundSlot
            readonly property bool hasRefund: card.isRefundCredit || card.txn.refundState !== undefined
            visible: hasRefund
            width: Style.space(20)
            height: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
              anchors.fill: parent
              radius: Style.space(5)
              color: refundMouse.containsMouse ? Util.alpha(root.foreground, 0.14) : Util.alpha(root.foreground, 0.06)
              TxnMark {
                anchors.centerIn: parent
                markSize: Style.space(16)
                kind: "refund"
              }
              MouseArea {
                id: refundMouse
                anchors.fill: parent
                anchors.margins: -Style.space(3)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                preventStealing: true
                onClicked: card.expanded = !card.expanded
              }
              ToolTip.visible: refundMouse.containsMouse
              ToolTip.text: card.isRefundCredit ? Model.refundOfText(card.txn, root.transactionById) : Model.refundedChip(card.txn)
              ToolTip.delay: 300
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          clip: true          // never runs under the amount / balance on the right

          BrandMark {
            network: Model.cardNetwork(card.txn, store.cardOverviews)
            markHeight: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          // Bank logos: only the one that applies is built (these were four
          // always-instantiated vector logos per row, ~225 ms over 489 rows).
          Loader {
            active: card.txn.accountType === "checking" && card.txn.bank === "HDFC"
            visible: active
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: HdfcLogo { variant: "icon"; markSize: Style.spaceReal(9) }
          }

          Loader {
            active: card.txn.accountType === "checking" && card.txn.bank === "AXIS"
            visible: active
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: AxisLogo { markSize: Style.spaceReal(9) }
          }

          Loader {
            active: card.isSbiSavings
            visible: active
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: SbiLogo { markSize: Style.spaceReal(9) }
          }

          // One side of a transfer between your own accounts whose other side is
          // not in this view (an account filter, a search): it says so instead of
          // passing for an ordinary credit. The "i" panel names the other bank.
          TagPill {
            visible: !!card.txn.transferId
            anchors.verticalCenter: parent.verticalCenter
            label: Model.transferMeta("lone").tag
            tone: root.toneColor("dim")
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
              text: card.accountName
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
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX + card.slide
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          id: amountText
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: root.isTransferLeg(card.txn)
            ? Model.currencySymbol(card.txn.currency) + Model.formatGrouped(Math.abs(card.txn.amount))
            : Model.formatAmount(card.txn)
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

      InfoButton {
        id: cInfoBtn
        visible: !card.editing && (card._hot || card.infoOpen)
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        infoShown: card.infoOpen
        onClicked: card.toggleInfo()
      }

      // Revealed when the row slides left (hover or keyboard focus). Opens the edit
      // panel: name, note, and the two bill actions.
      PanelActionButton {
        id: editBtn
        visible: !card.editing && (card._hot || card.infoOpen)
        anchors.right: cInfoBtn.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        size: Style.space(24)
        iconText: "✎"
        tooltipText: "Edit name, add a note or a bill"
        foreground: root.foreground
        bordered: false
        focusable: false
        onClicked: card.editing = true
      }

      // Built only while renaming: a TextField per idle row was wasted work.
      Loader {
        id: editFieldLoader
        active: card.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: TextField {
        id: editField
        text: card.displayMerchant
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        Component.onCompleted: { text = card.displayMerchant; selectAll(); forceActiveFocus() }
        onAccepted: card.saveEdit()
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
        Keys.onEscapePressed: {
          card.editing = false
          card.refocus()
        }
        }
      }
    }

    // Expanded detail panel: raw (pre-rename) merchant text, full date +
    // full account name, and an explicit tracked checkbox — separate from
    // the row-click/Enter/Space toggle above, so expanding never changes
    // tracked state by itself.
    InfoSection {
      id: cInfo
      anchors.top: collapsedRow.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      open: card.infoOpen
      info: !card.infoOpen ? null
        : (card.txn.transferId
          ? Model.transferExplain(card.txn, { accountTag: card.accountName })
          : Model.txnExplain(card.txn, { accountTag: card.accountName, userNote: card.effectiveNote,
              receiptMerchant: card.linkedReceipt ? (card.linkedReceipt.merchant || Model.receiptTitle(card.linkedReceipt)) : "" }))
    }

    // Edit panel: shows while editing. Name is the field in the row above.
    // It is either a Note or a Bill (typed here, item by item), never both.
    // ---- the peek: the note and / or the bill, dark and quiet. A note card (an amber hairline on the left),
    // then the bill as a slip (perforated top, monospace lines, a dashed rule over the total). They stack and
    // never overlap; the panel is too narrow to put them side by side.
    Loader {
      id: peekLoader
      active: card.peekOpen
      anchors.top: cInfo.bottom
      anchors.topMargin: card.peekOpen ? Style.space(6) : 0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(46)
      anchors.rightMargin: Style.spacing.rowPaddingX
      height: card.peekOpen && item ? item.implicitHeight : 0
      sourceComponent: Component {
        Column {
          id: peek
          readonly property bool withBill: !!card.linkedReceipt
          readonly property bool withNote: card.effectiveNote !== ""
          readonly property var bill: peek.withBill ? Model.billPeek(card.linkedReceipt, 4) : null
          readonly property color hair: Util.alpha(root.foreground, 0.10)
          readonly property color quiet: Qt.darker(root.foreground, 1.45)
          readonly property color amber: root.pendingColor
          spacing: Style.space(6)
          // a short fade and rise when it opens
          opacity: 0
          transform: Translate { id: peekRise; y: Style.space(6) }
          Component.onCompleted: { peekIn.start() }
          ParallelAnimation {
            id: peekIn
            NumberAnimation { target: peek; property: "opacity"; to: 1; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { target: peekRise; property: "y"; to: 0; duration: 260; easing.type: Easing.OutCubic }
          }

          // the note
          Rectangle {
            visible: peek.withNote
            width: peek.width
            height: noteCol.implicitHeight + Style.space(20)
            radius: Style.space(8)
            color: Util.alpha(peek.amber, 0.07)
            border.width: 1
            border.color: Util.alpha(peek.amber, 0.18)
            Rectangle {
              anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: Style.space(8) }
              width: Style.space(2)
              radius: 1
              color: peek.amber
            }
            Column {
              id: noteCol
              anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: Style.space(20); rightMargin: Style.space(12); topMargin: Style.space(10) }
              spacing: Style.space(4)
              Text {
                textFormat: Text.PlainText
                text: Model.peekNoteLabel(card.userNote, card.note)
                color: Util.alpha(peek.amber, 0.85)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
                font.letterSpacing: 1.2
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 6
                elide: Text.ElideRight
                lineHeight: 1.25
                textFormat: Text.PlainText
                text: card.effectiveNote
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }

          // the bill
          Rectangle {
            visible: peek.withBill
            width: peek.width
            height: billCol.implicitHeight + Style.space(24)
            radius: Style.space(8)
            color: Util.alpha(root.foreground, 0.04)
            border.width: 1
            border.color: peek.hair
            Row {   // perforation
              anchors { top: parent.top; topMargin: Style.space(6); horizontalCenter: parent.horizontalCenter }
              spacing: Style.space(6)
              Repeater {
                model: Math.max(0, Math.floor((peek.width - Style.space(24)) / Style.space(10)))
                delegate: Rectangle { width: Style.space(4); height: width; radius: width / 2; color: Util.alpha(root.foreground, 0.12) }
              }
            }
            Column {
              id: billCol
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(14); topMargin: Style.space(18) }
              spacing: Style.space(3)
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: peek.bill ? peek.bill.title : ""
                color: root.foreground
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.4
              }
              Text {
                visible: !!(peek.bill && peek.bill.sub)
                textFormat: Text.PlainText
                text: peek.bill ? peek.bill.sub : ""
                color: peek.quiet
                font.family: "monospace"
                font.pixelSize: Style.font.caption - 1
              }
              Item { width: 1; height: Style.space(4) }
              Repeater {
                model: peek.bill ? peek.bill.lines : []
                delegate: Item {
                  required property var modelData
                  width: billCol.width
                  height: Style.space(17)
                  Text {
                    anchors { left: parent.left; right: billAmt.left; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: modelData.text
                    color: Qt.darker(root.foreground, 1.15)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 1
                  }
                  Text {
                    id: billAmt
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    textFormat: Text.PlainText
                    text: modelData.amount
                    color: Qt.darker(root.foreground, 1.15)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption - 1
                  }
                }
              }
              Text {
                visible: !!(peek.bill && peek.bill.more > 0)
                textFormat: Text.PlainText
                text: peek.bill ? "+ " + peek.bill.more + " more" : ""
                color: peek.quiet
                font.family: "monospace"
                font.pixelSize: Style.font.caption - 1
              }
              Item { width: 1; height: Style.space(2) }
              Row {   // dashed rule
                spacing: Style.space(4)
                Repeater {
                  model: Math.max(0, Math.floor(billCol.width / Style.space(8)))
                  delegate: Rectangle { width: Style.space(4); height: 1; color: Util.alpha(root.foreground, 0.22) }
                }
              }
              Item {
                width: parent.width
                height: Style.space(20)
                Text {
                  anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                  textFormat: Text.PlainText
                  text: "TOTAL"
                  color: peek.quiet
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption - 1
                  font.bold: true
                  font.letterSpacing: 1.2
                }
                Text {
                  anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                  textFormat: Text.PlainText
                  text: peek.bill ? peek.bill.total : ""
                  color: root.foreground
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption + 1
                  font.bold: true
                }
              }
            }
          }

          // quiet actions
          Row {
            spacing: Style.space(16)
            height: Style.space(20)
            Repeater {
              model: (peek.withBill ? [{ id: "bill", label: "Open bill" }] : [])
                .concat([{ id: "edit", label: peek.withNote ? "Edit note" : "Add note" }])
              delegate: Text {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.label
                color: peekActMouse.containsMouse ? Color.accent : peek.quiet
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.underline: peekActMouse.containsMouse
                MouseArea {
                  id: peekActMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (modelData.id === "bill") root.openReceiptDetail(card.linkedReceipt)
                    else card.editing = true
                  }
                }
              }
            }
          }
        }
      }
    }

    Loader {
      id: editLoader
      active: card.editing
      anchors.top: peekLoader.bottom
      anchors.topMargin: Style.space(2)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      // Built only while editing: ~490 idle rows used to each carry this whole panel.
      sourceComponent: Component { Column {
      id: editPanel
      width: parent.width
      readonly property string noteText: noteArea.text
      spacing: Style.space(6)
      property bool billMode: false
      property bool picking: false
      property var billItems: [{ d: "", q: "", p: "" }]
      readonly property real billSum: {
        var t = 0
        for (var i = 0; i < billItems.length; i++) t += parseFloat(String(billItems[i].p).replace(/,/g, "")) || 0
        return t
      }
      readonly property bool billValid: {
        for (var i = 0; i < billItems.length; i++) if (String(billItems[i].d).trim() !== "") return true
        return false
      }
      onVisibleChanged: if (visible) { billMode = false; picking = false; catPicking = false; catMain = ""; aiSuggest = null; aiMsg = ""; billItems = [{ d: "", q: "", p: "" }] }
      function setItem(i, key, val) {
        var next = billItems.slice()
        next[i] = Object.assign({}, next[i]); next[i][key] = val
        billItems = next
      }
      function saveBill() {
        var lines = []
        for (var i = 0; i < billItems.length; i++) {
          var d = String(billItems[i].d).trim().replace(/\s+/g, " ")
          var pr = String(billItems[i].p).trim().replace(/,/g, "")
          if (d === "") continue
          var q = String(billItems[i].q).trim().replace(/,/g, "")
          lines.push(d.replace(/\|/g, " ") + " | " + (q !== "" && !isNaN(parseFloat(q)) ? parseFloat(q) : "")
            + " | " + (pr !== "" && !isNaN(parseFloat(pr)) ? parseFloat(pr) : ""))
        }
        store.setTransactionName(card.groupKey, (editFieldLoader.item ? editFieldLoader.item.text : ""))
        store.noteBill(card.txn.id, lines.join("\n"))
        card.editing = false
      }

      // CATEGORY: pick it here, or let the local model suggest one. A transfer between
      // your own accounts is always "Balance Correction" in Cashew, so it has no picker.
      readonly property bool canCategorise: !root.isTransferLeg(card.txn)
      property bool catPicking: false
      property string catMain: ""
      property bool catAll: true
      property bool aiBusy: false
      property int aiSeconds: 0
      property var aiSuggest: null
      property string aiMsg: ""
      readonly property var catChoices: Model.cashewCategoriesFor(store.receiptCategories, Number(card.txn.amount) < 0 ? "-1" : "1")
      readonly property var catMainDef: {
        for (var k = 0; k < catChoices.length; k++) if (catChoices[k].name === catMain) return catChoices[k]
        return null
      }
      function startAi() {
        if (editPanel.aiBusy || root.cashewGuessing) return
        editPanel.aiSuggest = null
        editPanel.aiMsg = ""
        editPanel.aiSeconds = 0
        aiInput = JSON.stringify({ rows: [{
          id: card.txn.id, amount: Number(card.txn.amount).toFixed(2), title: card.displayMerchant,
          merchant: card.txn.merchant, notes: card.userNote || card.note || "",
          bank: card.txn.bank, accountType: card.txn.accountType }], taught: Model.cashewTaught(root.cashewState) }) + "\n"
        editPanel.aiBusy = true
        rowGuess.running = true
      }
      property string aiInput: ""
      Process {
        id: rowGuess
        command: ["python3", root.txdbBin, "cashew-guess", "-", "--workers", "1", "--batch", "1"]
        stdinEnabled: true
        stdout: SplitParser {
          splitMarker: "\n"
          onRead: function (line) {
            var m
            try { m = JSON.parse(line) } catch (e) { return }
            if (m.error) editPanel.aiMsg = String(m.error)
            if (m.results && m.results.length && m.results[0].category) editPanel.aiSuggest = m.results[0]
          }
        }
        stderr: StdioCollector { id: rowGuessErr }
        onRunningChanged: if (rowGuess.running && editPanel.aiInput !== "") {
          rowGuess.write(editPanel.aiInput)
          editPanel.aiInput = ""
        }
        onExited: function (exitCode) {
          editPanel.aiBusy = false
          if (!editPanel.aiSuggest && editPanel.aiMsg === "")
            editPanel.aiMsg = exitCode === 0 ? "The model gave no category." : "AI failed (" + exitCode + ")"
        }
      }
      Timer { interval: 1000; repeat: true; running: editPanel.aiBusy; onTriggered: editPanel.aiSeconds++ }

      Flow {
        visible: editPanel.canCategorise
        width: parent.width
        spacing: Style.space(6)
        TxnBtn {
          label: card.txn.category ? ("Category: " + card.txn.category + (card.txn.subcategory ? "  ›  " + card.txn.subcategory : "")) : "Choose category"
          primary: editPanel.catPicking
          onClicked: { editPanel.catPicking = !editPanel.catPicking; editPanel.catMain = "" }
        }
        TxnBtn {
          label: editPanel.aiBusy ? ("Stop  " + editPanel.aiSeconds + "s") : "✦ AI"
          enabled: editPanel.aiBusy || !root.cashewGuessing
          onClicked: if (editPanel.aiBusy) rowGuess.running = false; else editPanel.startAi()
        }
        TxnBtn {
          label: editPanel.catAll ? "☑ All from this payee" : "☐ This one only"
          onClicked: editPanel.catAll = !editPanel.catAll
        }
        TxnBtn {
          visible: !!card.txn.category
          label: "Clear"
          onClicked: store.setTxnCategory(card.txn.id, "", "", !editPanel.catAll)
        }
      }

      // the model's suggestion: nothing changes until you accept
      Flow {
        visible: editPanel.canCategorise && (!!editPanel.aiSuggest || editPanel.aiMsg !== "")
        width: parent.width
        spacing: Style.space(6)
        Text {
          width: Math.min(implicitWidth, parent.width)
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: editPanel.aiSuggest ? ("AI suggests: " + editPanel.aiSuggest.category + (editPanel.aiSuggest.subcategory ? "  ›  " + editPanel.aiSuggest.subcategory : "")) : editPanel.aiMsg
          color: editPanel.aiSuggest ? root.foreground : Qt.darker(root.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TxnBtn {
          visible: !!editPanel.aiSuggest
          label: "Accept"
          primary: true
          onClicked: {
            store.setTxnCategory(card.txn.id, editPanel.aiSuggest.category, editPanel.aiSuggest.subcategory, !editPanel.catAll)
            editPanel.aiSuggest = null
          }
        }
        TxnBtn { visible: !!editPanel.aiSuggest || editPanel.aiMsg !== ""; label: "Discard"; onClicked: { editPanel.aiSuggest = null; editPanel.aiMsg = "" } }
      }

      // Step 1: the main categories as a grid of ring tiles.
      Grid {
        id: catGrid
        visible: editPanel.catPicking && editPanel.catMain === ""
        columns: 4
        spacing: Style.space(6)
        readonly property real tileW: (editPanel.width - 3 * spacing) / 4
        Repeater {
          model: editPanel.catPicking ? editPanel.catChoices : []
          delegate: CatTile {
            required property var modelData
            width: catGrid.tileW
            glyph: modelData.icon || ""
            label: modelData.name
            tint: modelData.color || Color.accent
            selected: card.txn.category === modelData.name
            marked: !!editPanel.aiSuggest && editPanel.aiSuggest.category === modelData.name
            onClicked: editPanel.catMain = modelData.name
          }
        }
      }

      // Step 2: the sub-categories of the chosen one, in the same place.
      Column {
        visible: editPanel.catPicking && editPanel.catMain !== ""
        width: parent.width
        spacing: Style.space(6)
        Row {
          spacing: Style.space(8)
          TxnBtn { label: "‹ Back"; onClicked: editPanel.catMain = "" }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: (editPanel.catMainDef ? (editPanel.catMainDef.icon || "") + "  " : "") + editPanel.catMain
            color: editPanel.catMainDef && editPanel.catMainDef.color ? editPanel.catMainDef.color : root.foreground
            font.family: "JetBrainsMono Nerd Font"
            font.bold: true
            font.pixelSize: Style.font.subtitle
          }
        }
        Grid {
          id: subGrid
          columns: 3
          spacing: Style.space(6)
          readonly property real tileW: (editPanel.width - 2 * spacing) / 3
          CatTile {
            width: subGrid.tileW
            glyph: "󰄬"
            label: "Just " + editPanel.catMain
            tint: editPanel.catMainDef && editPanel.catMainDef.color ? editPanel.catMainDef.color : Color.accent
            primary: true
            selected: card.txn.category === editPanel.catMain && !card.txn.subcategory
            onClicked: { store.setTxnCategory(card.txn.id, editPanel.catMain, "", !editPanel.catAll); editPanel.catPicking = false }
          }
          Repeater {
            model: editPanel.catMainDef ? editPanel.catMainDef.subcategories : []
            delegate: CatTile {
              required property string modelData
              width: subGrid.tileW
              glyph: (editPanel.catMainDef.subIcons || {})[modelData] || ""
              label: modelData
              tint: editPanel.catMainDef.color || Color.accent
              selected: card.txn.category === editPanel.catMain && card.txn.subcategory === modelData
              marked: !!editPanel.aiSuggest && editPanel.aiSuggest.category === editPanel.catMain && editPanel.aiSuggest.subcategory === modelData
              onClicked: { store.setTxnCategory(card.txn.id, editPanel.catMain, modelData, !editPanel.catAll); editPanel.catPicking = false }
            }
          }
        }
      }

      Row {
        spacing: Style.space(6)
        visible: !card.linkedReceipt
        TxnBtn { label: "Note"; primary: !editPanel.billMode; onClicked: editPanel.billMode = false }
        TxnBtn { label: "Bill"; primary: editPanel.billMode; onClicked: editPanel.billMode = true }
        TxnBtn { label: editPanel.picking ? "Hide bills" : "Link a bill"; onClicked: editPanel.picking = !editPanel.picking }
      }

      // NOTE
      Rectangle {
        visible: !editPanel.billMode
        width: parent.width
        height: Style.space(72)
        radius: Style.space(6)
        color: Util.alpha(root.foreground, 0.06)
        border.width: 1
        border.color: noteArea.activeFocus ? Color.accent : Util.alpha(root.foreground, 0.2)
        TextArea {
          id: noteArea
          anchors.fill: parent
          anchors.margins: Style.space(4)
          wrapMode: TextArea.Wrap
          placeholderText: "Note"
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          background: null
          onVisibleChanged: if (visible) text = card.effectiveNote
          Component.onCompleted: text = card.effectiveNote
          Keys.onEscapePressed: { card.editing = false; card.refocus() }
        }
      }

      // BILL: one row per item, right here in the widget.
      Column {
        visible: editPanel.billMode && !card.linkedReceipt
        width: parent.width
        spacing: Style.space(4)
        Repeater {
          model: editPanel.billItems.length
          delegate: Row {
            id: itemRow
            required property int index
            width: parent.width
            spacing: Style.space(4)
            TextField {
              width: parent.width - Style.space(96) - Style.space(56) - Style.space(28) - parent.spacing * 3
              placeholderText: "Item"
              text: editPanel.billItems[itemRow.index] ? editPanel.billItems[itemRow.index].d : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onTextEdited: editPanel.setItem(itemRow.index, "d", text)
            }
            TextField {
              width: Style.space(56)
              placeholderText: "Qty"
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              horizontalAlignment: Text.AlignRight
              text: editPanel.billItems[itemRow.index] ? editPanel.billItems[itemRow.index].q : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onTextEdited: editPanel.setItem(itemRow.index, "q", text)
            }
            TextField {
              width: Style.space(96)
              placeholderText: "Price"
              inputMethodHints: Qt.ImhFormattedNumbersOnly
              horizontalAlignment: Text.AlignRight
              text: editPanel.billItems[itemRow.index] ? editPanel.billItems[itemRow.index].p : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onTextEdited: editPanel.setItem(itemRow.index, "p", text)
            }
            PanelActionButton {
              size: Style.space(28)
              iconText: "×"
              tooltipText: "Remove item"
              foreground: root.foreground
              bordered: false
              focusable: false
              enabled: editPanel.billItems.length > 1
              onClicked: {
                var next = editPanel.billItems.slice()
                next.splice(itemRow.index, 1)
                editPanel.billItems = next
              }
            }
          }
        }
        Text {
          textFormat: Text.PlainText
          color: Math.abs(editPanel.billSum - Math.abs(card.txn.amount)) < 0.5 ? root.creditColor : Qt.darker(root.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: "Items " + Model.currencySymbol(card.txn.currency) + Model.formatGrouped(editPanel.billSum)
            + "  ·  transaction " + Model.currencySymbol(card.txn.currency) + Model.formatGrouped(Math.abs(card.txn.amount))
        }
      }

      // REFUND: a credit is linked to the purchase it gives back; a purchase can wait for its refund.
      // Not optimistic: a link changes the month totals and the Cashew category, so the snapshot reloads.
      Column {
        id: refundBox
        readonly property bool isCredit: card.txn.amount > 0 && !root.isTransferLeg(card.txn)
        readonly property bool isPurchase: card.txn.amount < 0 && !root.isTransferLeg(card.txn)
        property bool picking: false
        property bool showAll: false
        property bool noOriginal: false
        visible: refundBox.isCredit || refundBox.isPurchase
        width: parent.width
        spacing: Style.space(6)

        Text {
          visible: card.isRefundCredit
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: Model.refundOfText(card.txn, root.transactionById)
          color: Qt.darker(root.foreground, 1.1)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        // The bill of the purchase this refund gives back, when there is one.
        Row {
          id: refundBillRow
          readonly property var bill: card.isRefundCredit && card.txn.refundOf
            ? Model.linkedReceiptForTransaction(root.transactionById[card.txn.refundOf] || ({}), store.receipts) : null
          visible: !!bill
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Bill of that purchase: " + (refundBillRow.bill ? Model.receiptTitle(refundBillRow.bill) : "")
            color: Qt.darker(root.foreground, 1.1)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          TxnBtn { label: "Open bill"; onClicked: { card.editing = false; root.openReceiptDetail(refundBillRow.bill) } }
        }
        // How the Cashew export treats the pair (txdb/refunds.py, Model.cashewBuildLinks).
        Row {
          visible: card.isRefundCredit
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "In Cashew:"
            color: Qt.darker(root.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          // Links carry categoryPolarity=false, so "same category" is the purchase's own category with a positive
          // amount (income). Or net it into the purchase.
          TxnBtn { label: "Income: same category"; primary: card.txn.refundMode === "income"; onClicked: store.setRefundMode(card.txn.id, "income") }
          TxnBtn { label: "Net against purchase"; primary: card.txn.refundMode === "skip"; onClicked: store.setRefundMode(card.txn.id, "skip") }
          TxnBtn { label: "Lent (manual)"; primary: card.txn.refundMode === "lent"; onClicked: store.setRefundMode(card.txn.id, "lent") }
        }
        Text {
          visible: card.isRefundCredit && card.txn.refundMode === "lent"
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Cashew links cannot create a Lent. Send the purchase as usual, then in Cashew edit it, set its type to Lent and tap collect when the money is back."
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: refundBox.isPurchase && card.txn.refundState !== undefined
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: Model.refundedChip(card.txn)
          color: Qt.darker(root.foreground, 1.1)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          TxnBtn {
            visible: refundBox.isCredit && !card.isRefundCredit
            label: refundBox.picking ? "Hide purchases" : "Link to purchase"
            onClicked: { refundBox.picking = !refundBox.picking; refundBox.noOriginal = false }
          }
          TxnBtn {
            visible: refundBox.isCredit && !card.isRefundCredit
            label: "Original not in my data"
            primary: refundBox.noOriginal
            onClicked: { refundBox.noOriginal = !refundBox.noOriginal; refundBox.picking = false }
          }
          TxnBtn {
            visible: refundBox.isCredit && !card.isRefundCredit && !card.txn.refundNot
            label: "Not a refund"
            onClicked: { store.markNotRefund(card.txn.id); card.editing = false }
          }
          TxnBtn {
            visible: refundBox.isCredit && !card.isRefundCredit && !!card.txn.refundNot
            label: "Allow as a refund"
            onClicked: store.allowRefund(card.txn.id)
          }
          TxnBtn {
            visible: card.isRefundCredit
            label: "Unlink refund"
            onClicked: { store.unlinkRefund(card.txn.id); card.editing = false }
          }
          TxnBtn {
            visible: refundBox.isPurchase && card.txn.refundState !== "pending" && card.txn.refundState === undefined
            label: "Return pending"
            onClicked: store.expectRefund(card.txn.id)
          }
          TxnBtn {
            visible: refundBox.isPurchase && card.txn.refundState === "pending"
            label: "Clear pending"
            onClicked: store.unexpectRefund(card.txn.id)
          }
        }

        // The purchases this credit may give back, best match first.
        Flow {
          visible: refundBox.picking
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: refundBox.picking ? Model.refundCandidates(card.txn, store.transactions, { all: refundBox.showAll }) : []
            delegate: TxnBtn {
              required property var modelData
              // A purchase that has a bill says so, with what the bill is: that is often the quickest way to
              // see which purchase a refund belongs to.
              readonly property var bill: Model.linkedReceiptForTransaction(modelData.txn, store.receipts)
              label: Model.formatDate(modelData.txn.date) + "  " + modelData.txn.merchant + "  "
                + Model.currencySymbol(modelData.txn.currency) + Model.formatGrouped(Math.abs(modelData.txn.amount))
                + (modelData.score > 0 ? "  ·  " + modelData.score + "%" : "")
                + (bill ? "  ·  bill: " + Model.receiptTitle(bill) : "")
              primary: modelData.score >= 100
              onClicked: { store.linkRefund(card.txn.id, modelData.txn.id, ""); refundBox.picking = false; card.editing = false }
            }
          }
          TxnBtn {
            visible: refundBox.picking && !refundBox.showAll
            label: "Show every purchase of the last 90 days"
            onClicked: refundBox.showAll = true
          }
        }
        Text {
          visible: refundBox.picking && Model.refundCandidates(card.txn, store.transactions, { all: false }).length === 0 && !refundBox.showAll
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "No purchase looks like the one this credit gives back."
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // A refund whose purchase is not in the data: say what it was.
        Row {
          visible: refundBox.noOriginal
          spacing: Style.space(6)
          TextField {
            id: refundNoteField
            width: Style.space(260)
            placeholderText: "What was it? (optional)"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            Keys.onReturnPressed: { store.linkRefund(card.txn.id, "", text); refundBox.noOriginal = false; card.editing = false }
          }
          TxnBtn {
            label: "Link"
            primary: true
            onClicked: { store.linkRefund(card.txn.id, "", refundNoteField.text); refundBox.noOriginal = false; card.editing = false }
          }
        }
      }

      Row {
        spacing: Style.space(6)
        TxnBtn {
          label: editPanel.billMode && !card.linkedReceipt ? "Save bill" : "Save"
          primary: true
          enabled: !(editPanel.billMode && !card.linkedReceipt) || editPanel.billValid
          onClicked: editPanel.billMode && !card.linkedReceipt ? editPanel.saveBill() : card.saveEdit()
        }
        TxnBtn {
          label: "+ Item"
          visible: editPanel.billMode && !card.linkedReceipt
          onClicked: editPanel.billItems = editPanel.billItems.concat([{ d: "", q: "", p: "" }])
        }
        TxnBtn { label: "Cancel"; onClicked: { card.editing = false; card.refocus() } }
        TxnBtn {
          label: "Open bill"
          visible: !!card.linkedReceipt
          onClicked: { card.editing = false; root.openReceiptDetail(card.linkedReceipt) }
        }
      }

      // Bills not yet filed against any transaction.
      Flow {
        visible: editPanel.picking && !card.linkedReceipt
        width: parent.width
        spacing: Style.space(6)
        Repeater {
          model: editPanel.picking ? store.receipts.filter(function (r) { return r.state === "unmatched" }).slice(0, 12) : []
          delegate: TxnBtn {
            required property var modelData
            label: Model.receiptTitle(modelData) + (modelData.total != null ? "  " + Model.currencySymbol(modelData.currency) + Model.formatGrouped(modelData.total) : "")
            onClicked: { store.linkReceipt(modelData.id, card.txn.id); card.editing = false }
          }
        }
      }
    } }  // Column, Component
    }  // Loader

    Loader {
      id: detailsLoader
      active: card.showDetails
      anchors.top: peekLoader.bottom
      anchors.topMargin: Style.space(6)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(46)
      anchors.rightMargin: Style.spacing.rowPaddingX
      sourceComponent: Component { Column {
      id: detailsPanel
      width: parent.width
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
        visible: card.effectiveNote !== ""
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Note: " + card.effectiveNote
        color: Qt.darker(root.foreground, 1.1)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // The other side of a refund link, in the expanded view.
      Text {
        visible: card.isRefundCredit || card.txn.refundState !== undefined
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: card.isRefundCredit ? Model.refundOfText(card.txn, root.transactionById) : Model.refundedChip(card.txn)
        color: Qt.darker(root.foreground, 1.1)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        // The remark only when a note of its own replaced it (else the remark IS the note, shown above).
        visible: card.userNote !== "" && card.note !== "" && card.note.trim() !== card.userNote.trim()
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

      // A pair that was split ("Not a transfer"): bring it back.
      Row {
        visible: !!card.txn.transferSplitId || !!card.txn.transferSelfSplit
        spacing: Style.space(8)
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Looks like one side of a transfer."
          color: Qt.darker(root.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextAction {
          label: "Treat as a transfer"
          onTriggered: root.txdb(["transfer-restore"].concat(card.txn.transferSplitId
            ? card.txn.transferSplitId.split(">") : [card.txn.id]))
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
    } }  // Column, Component
    }  // Loader
  }
}
