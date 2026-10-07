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
  // message, and the QR screenshot path while stage == "qr-ready".
  property var fetchStatus: ({})
  function hexOf(c) {
    var h = String(c).replace("#", "")
    return h.length === 8 ? h.slice(2) : h.slice(0, 6)
  }
  readonly property bool showQr: fetchStatus.stage === "qr-ready" && !!fetchStatus.qr
  readonly property string fetcherOutputDir: fetcherDir + "/output"
  // Second source: the Axis fetcher writes the same shapes into its output/
  // folder (balances, transactions) and its own status file.
  readonly property string axisDir: "/home/pc/Work/axis-statement-fetcher"
  readonly property string axisOutputDir: axisDir + "/output"
  property var axisFetchStatus: ({})
  readonly property bool axisOtpNeeded: axisFetchProc.running && axisFetchStatus.stage === "otp-needed"
  readonly property string activeStatusText: fetchProc.running
    ? ((fetchStatus.message || "") !== "" ? "HDFC: " + fetchStatus.message : "")
    : (axisFetchProc.running && (axisFetchStatus.message || "") !== "" ? "Axis: " + axisFetchStatus.message : "")
  readonly property color activeStatusColor: (fetchProc.running ? fetchStatus.stage : axisFetchStatus.stage) === "error"
    ? Color.urgent : Color.accent
  function parseList(text) {
    try { return JSON.parse(text || "[]") } catch (e) { return [] }
  }

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

  readonly property var cardOverviewList: Object.values(store.cardOverviews)
  readonly property bool billDue: store.anyBillDue()

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
  readonly property int amountInset: Style.spacing.rowPaddingX + Style.space(40)
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
      if (next.activeFocusOnTab) { next.forceActiveFocus(); return }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    trackedFile.reload()
    realTransactionsFile.reload()
    cardOverviewFile.reload()
    accountBalancesFile.reload()
    billsFile.reload()
    accountNamesFile.reload()
    transactionNamesFile.reload()
  }

  QtObject {
    id: store
    property var trackedOverrides: ({})
    property var rawTransactions: []
    property var sourceTransactions: ({})   // map: source name -> rows
    property var sourceBalances: ({})       // map: source name -> balance rows
    property var transactions: []
    property var cardOverviews: ({})   // map: last4 -> overview entry
    property var accountBalances: []   // list of {bank, accountType, last4, balance, currency}
    property var billOverrides: ({})   // map: last4 -> { markedPaid, notifiedDate }
    property var accountNameOverrides: ({})   // map: last4 -> user-set display name
    property var transactionNameOverrides: ({})   // map: Model.transactionGroupKey(t) -> user-set merchant name

    // Rebuilds `transactions` from the real fetched rows, minus anything
    // with any locally-toggled tracked state applied on top.
    function recompute() {
      var base = rawTransactions
      var list = []
      for (var j = 0; j < base.length; j++) {
        var row = base[j]
        if (Object.prototype.hasOwnProperty.call(trackedOverrides, row.id)) {
          row = Object.assign({}, row, { tracked: !!trackedOverrides[row.id] })
        }
        list.push(row)
      }
      transactions = list
    }

    function setTrackedOverrides(overrides) {
      trackedOverrides = overrides || {}
      recompute()
    }


    // One list per source ("hdfc", "axis"); the merged list feeds RECENT.
    function setSourceTransactions(source, list) {
      var map = Object.assign({}, sourceTransactions)
      map[source] = list || []
      sourceTransactions = map
      rawTransactions = [].concat(map.hdfc || [], map.axis || [])
      recompute()
    }

    function setTracked(id, value) {
      var overrides = Object.assign({}, trackedOverrides)
      if (value) overrides[id] = true
      else delete overrides[id]
      trackedOverrides = overrides
      recompute()
      writeTrackedFile()
    }

    // Sets the tracked state of several rows at once (Track / Untrack selected).
    function setTrackedMany(rows, value) {
      if (!rows || rows.length === 0) return
      var overrides = Object.assign({}, trackedOverrides)
      for (var i = 0; i < rows.length; i++) {
        if (value) overrides[rows[i].id] = true
        else delete overrides[rows[i].id]
      }
      trackedOverrides = overrides
      recompute()
      writeTrackedFile()
    }

    function writeTrackedFile() {
      trackedFile.setText(JSON.stringify(trackedOverrides, null, 2) + "\n")
    }

    // --- Bills ---

    function setCardOverviews(list) {
      var map = {}
      for (var i = 0; i < (list || []).length; i++) {
        var entry = list[i]
        if (entry && entry.last4) map[entry.last4] = entry
      }
      cardOverviews = map
      checkBillReminders()
    }

    function setSourceBalances(source, list) {
      var map = Object.assign({}, sourceBalances)
      map[source] = list || []
      sourceBalances = map
      accountBalances = [].concat(map.hdfc || [], map.axis || [])
    }

    function setBillOverrides(overrides) {
      billOverrides = overrides || {}
    }

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
      writeBillsFile()
    }

    function writeBillsFile() {
      billsFile.setText(JSON.stringify(billOverrides, null, 2) + "\n")
    }

    // --- Account renaming ---

    function setAccountNameOverrides(overrides) {
      accountNameOverrides = overrides || {}
    }

    function setAccountName(last4, name) {
      var overrides = Object.assign({}, accountNameOverrides)
      var trimmed = String(name || "").trim()
      if (trimmed) overrides[last4] = trimmed
      else delete overrides[last4]
      accountNameOverrides = overrides
      accountNamesFile.setText(JSON.stringify(accountNameOverrides, null, 2) + "\n")
    }

    // --- Transaction renaming ---

    function setTransactionNameOverrides(overrides) {
      transactionNameOverrides = overrides || {}
    }

    function setTransactionName(groupKey, name) {
      var overrides = Object.assign({}, transactionNameOverrides)
      var trimmed = String(name || "").trim()
      if (trimmed) overrides[groupKey] = trimmed
      else delete overrides[groupKey]
      transactionNameOverrides = overrides
      transactionNamesFile.setText(JSON.stringify(transactionNameOverrides, null, 2) + "\n")
    }

    // Fires a desktop notification for each unpaid card, at most once per
    // card per calendar day. Called from cardOverviewFile's onLoaded so
    // "what counts as a reminder" lives in one place, not in the FileView.
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
          "••" + last4 + "  ·  " + entry.upcoming_payment_due + "  ·  " + entry.payment_status
        ])

        overrides[last4] = Object.assign({}, override, { notifiedDate: today })
        changed = true
      }
      if (changed) {
        billOverrides = overrides
        writeBillsFile()
      }
    }
  }

  FileView {
    id: trackedFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-tracked.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setTrackedOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.setTrackedOverrides({})
    onFileChanged: reload()
  }


  FileView {
    id: realTransactionsFile
    path: root.fetcherOutputDir + "/hdfc_transactions.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setSourceTransactions("hdfc", root.parseList(text()))
    onLoadFailed: store.setSourceTransactions("hdfc", [])
    onFileChanged: reload()
  }

  FileView {
    id: axisTransactionsFile
    path: root.axisOutputDir + "/axis_transactions.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setSourceTransactions("axis", root.parseList(text()))
    onLoadFailed: store.setSourceTransactions("axis", [])
    onFileChanged: reload()
  }

  property bool fetchCancelled: false

  function startFetch(bank) {
    if (bank === "axis") axisFetchProc.running = true
    else fetchProc.running = true
  }

  function cancelFetch(bank) {
    if (bank === "axis") {
      axisFetchCancelled = true
      axisCancelProc.running = true
      axisFetchProc.running = false
    } else {
      fetchCancelled = true
      cancelProc.running = true
      fetchProc.running = false
    }
  }

  // The balance text for one bank's accounts ("HDFC" or "AXIS"), joined.
  function balanceTextFor(bank) {
    return root.accountBalances
      .filter(function (b) { return b.bank === bank })
      .map(function (b) { return Model.formatAccountBalance(b, store.accountNameOverrides, store.cardOverviews) })
      .join("  ·  ")
  }

  // Stops the running fetch: signals its whole process group, removes the
  // login QR, and records the cancelled stage for the widget.
  Process {
    id: cancelProc
    command: ["bash", "-c", "cd '" + root.fetcherDir + "' && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && kill -TERM -- -$PID 2>/dev/null; rm -f output/qr.png; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/fetch-status.json"]
  }

  // Runs the fetcher. Its output goes to output/widget-fetch.log, so a
  // failed run is readable without opening the popup.
  Process {
    id: fetchProc
    // QR colours are passed as hex so the fetcher can redraw the login QR in
    // this theme (only #rrggbb values, see login._hex_or).
    // setsid makes this run its own process group, so Cancel can stop the
    // fetcher and its browser together (see cancelProc).
    command: ["setsid", "bash", "-c", "cd '" + root.fetcherDir + "' && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.fetchCancelled) { root.fetchCancelled = false; return }
      Quickshell.execDetached([
        Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
        "--app-name", "home.transactions",
        exitCode === 0 ? "HDFC fetch finished" : "HDFC fetch failed",
        exitCode === 0 ? "Data refreshed" : "See output/widget-fetch.log"
      ])
    }
  }

  property bool axisFetchCancelled: false

  Process {
    id: axisCancelProc
    command: ["bash", "-c", "cd '" + root.axisDir + "' && mkdir -p output && PID=$(cat output/fetch.pid 2>/dev/null); [ -n \"$PID\" ] && kill -TERM -- -$PID 2>/dev/null; printf '%s' '{\"stage\": \"cancelled\", \"message\": \"Fetch cancelled.\", \"qr\": \"\", \"card\": \"\", \"step\": \"\", \"updated\": \"\"}' > output/axis-fetch-status.json"]
  }

  // Runs the Axis fetcher. stdinEnabled keeps its stdin open: the OTP the
  // user types goes down that pipe (see otpRow), never into a file.
  Process {
    id: axisFetchProc
    stdinEnabled: true
    command: ["setsid", "bash", "-c", "cd '" + root.axisDir + "' && mkdir -p output && echo $$ > output/fetch.pid && exec .venv/bin/python -m src.main > output/widget-fetch.log 2>&1"]
    onExited: function (exitCode) {
      if (root.axisFetchCancelled) { root.axisFetchCancelled = false; return }
      Quickshell.execDetached([
        Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send",
        "--app-name", "home.transactions",
        exitCode === 0 ? "Axis fetch finished" : "Axis fetch failed",
        exitCode === 0 ? "Data refreshed" : "See output/widget-fetch.log in axis-statement-fetcher"
      ])
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

  FileView {
    id: cardOverviewFile
    path: root.fetcherOutputDir + "/hdfc_creditcard_overview.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setCardOverviews(JSON.parse(text() || "[]"))
    onLoadFailed: store.setCardOverviews([])
    onFileChanged: reload()
  }

  FileView {
    id: accountBalancesFile
    path: root.fetcherOutputDir + "/hdfc_account_balances.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setSourceBalances("hdfc", root.parseList(text()))
    onLoadFailed: store.setSourceBalances("hdfc", [])
    onFileChanged: reload()
  }

  FileView {
    id: axisBalancesFile
    path: root.axisOutputDir + "/axis_account_balances.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setSourceBalances("axis", root.parseList(text()))
    onLoadFailed: store.setSourceBalances("axis", [])
    onFileChanged: reload()
  }

  FileView {
    id: billsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-bills.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setBillOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.setBillOverrides({})
    onFileChanged: reload()
  }

  FileView {
    id: accountNamesFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-account-names.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setAccountNameOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.setAccountNameOverrides({})
    onFileChanged: reload()
  }

  FileView {
    id: transactionNamesFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-custom-names.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setTransactionNameOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.setTransactionNameOverrides({})
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

          // One chip per bank: the bank's logo (click it to reload that bank)
          // then its balance. A Flow, so the chips wrap rather than truncate.
          Flow {
            width: parent.width
            spacing: Style.spacing.md

            BankBalance {
              bank: "hdfc"
              tooltip: "Fetch HDFC data (opens browser, scan QR)"
              balanceText: root.balanceTextFor("HDFC")
            }

            BankBalance {
              bank: "axis"
              tooltip: "Fetch Axis data (asks for the OTP here)"
              balanceText: root.balanceTextFor("AXIS")
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

          // Axis OTP: one box per digit, like the bank's own screen. Typing
          // moves on to the next box, Backspace on an empty box goes back, and
          // a pasted code fills the row. The code goes down the fetcher's
          // stdin once every box is filled (or on Enter, for an empty or short
          // try, which the fetcher answers by asking again). Never stored.
          Item {
            id: otpRow
            visible: root.axisOtpNeeded
            width: parent.width
            height: Style.space(34)
            readonly property int digitCount: root.axisFetchStatus.digits || 6

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
              if (!axisFetchProc.running) return
              var code = ""
              for (var i = 0; i < digitCount; i++) code += boxAt(i).text
              axisFetchProc.write(code + "\n")
              for (var j = 0; j < digitCount; j++) boxAt(j).text = ""
              boxAt(0).forceActiveFocus()
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
            imageSource: root.showQr ? ("file://" + root.fetchStatus.qr + "?" + root.fetchStatus.updated) : ""
          }
        }

        PanelSectionHeader {
          text: "BILLS" + (root.cardOverviewList.length > 0 && !root.billDue ? "  ·  all paid" : "")
          visible: root.cardOverviewList.length > 0
          foreground: root.foreground
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
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              iconText: "⌕"
              tooltipText: root.searchVisible ? "Hide search" : "Search (/)"
              foreground: root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              onClicked: {
                root.searchVisible = !root.searchVisible
                if (root.searchVisible) Qt.callLater(function () { searchField.forceActiveFocus() })
                else { root.searchQuery = ""; searchField.focus = false }
              }
            }

            PanelActionButton {
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              iconText: "󰄹"
              tooltipText: root.selectionMode ? "Done selecting" : "Select transactions"
              foreground: root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              onClicked: root.setSelectionMode(!root.selectionMode)
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
            visible: root.selectedCount > 0
            label: "Track (" + root.selectedCount + ")"
            onTriggered: root.trackSelected(true)
          }

          TextAction {
            visible: root.selectedCount > 0
            label: "Untrack (" + root.selectedCount + ")"
            onTriggered: root.trackSelected(false)
          }

          TextAction {
            visible: root.filteredTransactions.length > 0
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

  // Compact BILLS row — status-colored avatar (✓ paid / ! due) + card name
  // + outstanding amount, matching TransactionCard's density instead of
  // the old Toggle+description row (switch control plus a full text line
  // just to say "Due ₹0.00 · FULLY PAID"). Click or Enter/Space toggles
  // the manual "mark as paid" override.
  component BillRow: BorderSurface {
    id: billRow
    required property var overview
    property bool expanded: false
    readonly property bool paid: store.isPaid(billRow.overview.last4)
    readonly property string cardName: Model.accountDisplayName(billRow.overview.name, billRow.overview.last4, store.accountNameOverrides)
    readonly property var brand: Model.cardBrandParts(billRow.cardName)
    readonly property real outstandingSigned: Model.parseCurrencyString(billRow.overview.total_outstanding)
    readonly property real upcomingDueSigned: Model.parseCurrencyString(billRow.overview.upcoming_payment_due)
    readonly property real currentAmount: Math.abs(billRow.outstandingSigned)
    // Three states, purely numeric — deliberately NOT keyed off `paid`
    // (the scrape's own "FULLY PAID"/"NO DUES" status, or the manual
    // override): that status can be true while total_outstanding is
    // still positive (last statement was paid off, but this cycle's new
    // spend hasn't been billed yet), which made a plain paid/unpaid
    // color lie about money still owed.
    //   "settled" — outstanding is zero or negative (bank owes the
    //     cardholder) — green ✓.
    //   "pending" — there's a positive outstanding/unbilled amount, but
    //     upcoming_payment_due is still ₹0 — nothing has actually come
    //     due yet, just spend sitting unbilled — amber ●.
    //   "due" — a positive amount has actually come due — red !.
    // `paid` (the manual override) still exists and still drives the
    // bill-due reminder/badge (see store.isPaid/anyBillDue) — it just no
    // longer overrides this row's own color or glyph.
    readonly property string billState: billRow.outstandingSigned <= 0
      ? "settled"
      : (billRow.upcomingDueSigned > 0 ? "due" : "pending")
    readonly property bool displayPaid: billRow.billState === "settled"
    readonly property color statusColor: billRow.billState === "settled"
      ? root.creditColor
      : (billRow.billState === "due" ? root.debitColor : root.pendingColor)
    readonly property string statusGlyph: billRow.billState === "settled"
      ? "✓"
      : (billRow.billState === "due" ? "!" : "●")
    readonly property bool _hot: rowHover.hovered || billRow.activeFocus
    readonly property int collapsedHeight: Style.space(52)

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
    // mouse-only on the avatar now, same precedent as TransactionCard's
    // rename pencil not being in the main Tab/Enter flow either.
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

      // Covers the collapsed row — clicking anywhere on it now expands
      // the full detail panel below. The avatar's own MouseArea (below)
      // sits on top of this one (declared later = higher z) and claims
      // just that icon for "mark as paid" instead, same precedent as
      // TransactionCard's editBtn overriding cardMouse beneath.
      MouseArea {
        id: rowMouse
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: billRow.expanded = !billRow.expanded
      }

      Rectangle {
        id: avatar
        width: Style.space(36)
        height: width
        radius: width / 2
        color: Util.alpha(billRow.statusColor, 0.22)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: billRow.statusGlyph
          color: billRow.statusColor
          font.bold: true
          font.pixelSize: Style.font.subtitle
        }

        // The one place "mark as paid" still lives — click just the
        // status icon to flip the manual override (it still drives the
        // bill-due reminder/badge, see store.isPaid/anyBillDue), without
        // it also being the row's main "show details" action anymore.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: store.setBillPaid(billRow.overview.last4, !billRow.paid)
        }
      }

      Column {
        id: titleCol
        anchors.left: avatar.right
        anchors.leftMargin: Style.space(10)
        anchors.right: amountText.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Row {
          width: parent.width
          spacing: Style.space(6)

          BrandMark {
            id: billBrandMark
            network: billRow.brand.network
            markHeight: Style.spaceReal(9)
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: parent.width - (billBrandMark.visible ? billBrandMark.width + Style.space(6) : 0)
            textFormat: Text.PlainText
            text: billRow.brand.label + " ••" + billRow.overview.last4
            color: root.foreground
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: Model.billPaidLine(billRow.overview)
          color: Qt.darker(root.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: expandChevron
        textFormat: Text.PlainText
        text: billRow.expanded ? "▴" : "▾"
        color: billRow._hot ? root.foreground : Qt.darker(root.foreground, 1.4)
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: amountText
        textFormat: Text.PlainText
        text: Model.currencySymbol("INR") + Model.formatGrouped(billRow.currentAmount)
        color: billRow.statusColor
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle
        anchors.right: parent.right
        anchors.rightMargin: root.amountInset
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Expanded detail panel: every field the billing-overview scrape
    // gives us for this card, neatly laid out — not just the one number
    // the collapsed row has room for.
    Column {
      id: detailsPanel
      visible: billRow.expanded
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

      Repeater {
        model: [
          { label: "Unbilled", value: billRow.overview.unbilled_amount },
          { label: "Total outstanding", value: billRow.overview.total_outstanding },
          { label: "Upcoming due", value: billRow.overview.upcoming_payment_due },
          { label: "Spent this cycle", value: billRow.overview.spent_this_cycle },
          { label: "Credited this cycle", value: billRow.overview.credited_this_cycle },
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

    Behavior on color { ColorAnimation { duration: 100 } }

    Row {
      id: triggerRow
      anchors.centerIn: parent
      spacing: Style.space(5)

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

        Keys.onEscapePressed: function (event) { filterPopup.close(); event.accepted = true }

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
            // Axis savings: the logo stands in for the name, so just the number.
            label: modelData.bank === "AXIS" ? "••" + modelData.last4 : modelData.label
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

    // Whichever bank mark this row shows (none for cards and "All accounts").
    readonly property bool hasBankMark: menuRow.bank === "HDFC" || menuRow.bank === "AXIS"
    readonly property Item bankMark: menuRow.bank === "AXIS" ? rowAxisMark : rowBankMark

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
      // Axis rows show only "••NNNN" after the logo, so give it more room.
      anchors.leftMargin: menuRow.bank === "AXIS" ? Style.space(12) : Style.space(6)
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
    readonly property bool isAxis: chip.bank === "axis"
    readonly property bool running: chip.isAxis ? axisFetchProc.running : fetchProc.running
    readonly property bool allowed: chip.isAxis ? !fetchProc.running : !axisFetchProc.running

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
      onFetch: root.startFetch(chip.bank)
      onCancel: root.cancelFetch(chip.bank)
    }

    Text {
      id: balanceLabel
      anchors.left: control.right
      anchors.leftMargin: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter
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

    activeFocusOnTab: true
    Keys.onReturnPressed: action.triggered()
    Keys.onEnterPressed: action.triggered()
    Keys.onSpacePressed: action.triggered()

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
    readonly property string accountName: Model.cardBrandParts(Model.formatAccount(txn, store.accountNameOverrides, store.cardOverviews).split(" ••")[0]).label + " ••" + txn.last4
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
    Keys.onSpacePressed: if (!card.editing) store.setTracked(card.txn.id, !card.txn.tracked)
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
          onClicked: root.toggleSelected(card.txn.id)
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
        anchors.right: amountText.left
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

          Rectangle {
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.12)
            implicitWidth: pillText.implicitWidth + Style.space(10)
            implicitHeight: pillText.implicitHeight + Style.space(4)

            Text {
              id: pillText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              // Axis savings show the Axis logo beside the number, not the name.
              text: card.isAxisSavings ? "••" + card.txn.last4 : card.accountName
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // The raw UPI remark (e.g. "FOR CC BILLS", "MF AND FD") shown as
          // a note beneath the merchant heading — skipped when it's just
          // boilerplate ("NO REMARK"/"UPI", see Model.transactionNote).
          Text {
            visible: card.note !== ""
            width: Math.max(0, parent.width - pillText.implicitWidth - Style.space(16))
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: card.note
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Text {
        id: amountText
        visible: !card.editing
        textFormat: Text.PlainText
        text: Model.formatAmount(card.txn)
        color: card.directionColor
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle
        // Sits just left of the rename pencil's slot (which is reserved even
        // while the pencil is hidden), so the amount stays clear of it.
        anchors.right: editBtn.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
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
        onEditingFinished: { store.setTransactionName(card.groupKey, text); card.editing = false }
        Keys.onEscapePressed: card.editing = false
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
