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
// An "Archive tracked" button moves every currently-tracked row out of the
// RECENT list into an archive; a "Show archived" toggle reveals them again.
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property var transactions: store.transactions
  readonly property var archivedList: store.archivedList
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked }).length
  readonly property int pendingTrackedCount: transactions.filter(function (t) { return t.tracked }).length
  readonly property int archivedCount: archivedList.length
  property bool showArchived: false

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
  readonly property var filteredTransactions: root.transactions
    .filter(function (t) { return root.accountFilters.length === 0 || root.accountFilters.indexOf(Model.accountKey(t)) !== -1 })
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

  // Credit/debit colors — single source of truth; TransactionCard and
  // ArchivedRow both derive their direction color from these rather than
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
  // Shared right inset for every row's amount, so BILLS, RECENT and ARCHIVED
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
    archiveFile.reload()
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
    property var archivedList: []
    property var rawTransactions: []
    property var transactions: []
    property var cardOverviews: ({})   // map: last4 -> overview entry
    property var accountBalances: []   // list of {bank, accountType, last4, balance, currency}
    property var billOverrides: ({})   // map: last4 -> { markedPaid, notifiedDate }
    property var accountNameOverrides: ({})   // map: last4 -> user-set display name
    property var transactionNameOverrides: ({})   // map: Model.transactionGroupKey(t) -> user-set merchant name

    // Rebuilds `transactions` from the real fetched rows, minus anything
    // archived, with any locally-toggled tracked state applied on top.
    function recompute() {
      var archivedIds = {}
      for (var i = 0; i < archivedList.length; i++) archivedIds[archivedList[i].id] = true
      var base = rawTransactions
      var list = []
      for (var j = 0; j < base.length; j++) {
        var row = base[j]
        if (archivedIds[row.id]) continue
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

    function setArchivedList(list) {
      archivedList = list || []
      recompute()
    }

    function setRealTransactions(list) {
      rawTransactions = list || []
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

    // Moves every currently-tracked row out of `transactions` and into the
    // archive, persisting both files.
    function archiveTracked() {
      var toArchive = transactions.filter(function (t) { return t.tracked })
      if (toArchive.length === 0) return
      archivedList = archivedList.concat(toArchive)
      recompute()
      writeTrackedFile()
      writeArchiveFile()
    }

    function writeTrackedFile() {
      trackedFile.setText(JSON.stringify(trackedOverrides, null, 2) + "\n")
    }

    function writeArchiveFile() {
      archiveFile.setText(JSON.stringify(archivedList, null, 2) + "\n")
    }

    // Moves one row back out of the archive (the archive used to be a
    // one-way trip — this fixes that). Re-applies whatever tracked
    // override still exists for its id, same as any other row.
    function unarchive(id) {
      archivedList = archivedList.filter(function (t) { return t.id !== id })
      recompute()
      writeArchiveFile()
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

    function setAccountBalances(list) {
      accountBalances = list || []
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
    id: archiveFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-archive.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setArchivedList(JSON.parse(text() || "[]"))
    onLoadFailed: store.setArchivedList([])
    onFileChanged: reload()
  }

  FileView {
    id: realTransactionsFile
    path: root.fetcherOutputDir + "/hdfc_transactions.json"
    watchChanges: true
    printErrors: false
    onLoaded: store.setRealTransactions(JSON.parse(text() || "[]"))
    onLoadFailed: store.setRealTransactions([])
    onFileChanged: reload()
  }

  property bool fetchCancelled: false

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
    onLoaded: store.setAccountBalances(JSON.parse(text() || "[]"))
    onLoadFailed: store.setAccountBalances([])
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

          // Account balances (checking/savings — see hdfc-statement-
          // fetcher's hdfc_account_balances.json) replacing the old "Top
          // spenders" line. A Flow, not one elided Text: only one account
          // exists today, but this needs to hold 4-5 once more
          // accounts/banks are added to the fetcher, wrapping to further
          // lines rather than truncating.
          Item {
            width: parent.width
            height: Math.max(balanceFlow.implicitHeight, fetchButton.size)

            Text {
              visible: root.accountBalances.length === 0
              anchors.left: parent.left
              anchors.right: fetchProc.running ? cancelButton.left : fetchButton.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "No balances yet — press ⟳ to fetch"
              color: Qt.darker(root.foreground, 1.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.italic: true
              elide: Text.ElideRight
            }

            HdfcMark {
              id: balanceBankMark
              bank: root.accountBalances.length > 0 ? root.accountBalances[0].bank : ""
              markHeight: Style.spaceReal(11)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Flow {
              id: balanceFlow
              visible: root.accountBalances.length > 0
              anchors.left: balanceBankMark.visible ? balanceBankMark.right : parent.left
              anchors.leftMargin: balanceBankMark.visible ? Style.spacing.xs : 0
              anchors.right: fetchProc.running ? cancelButton.left : fetchButton.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              Repeater {
                model: root.accountBalances
                delegate: Text {
                  required property var modelData
                  required property int index
                  textFormat: Text.PlainText
                  text: Model.formatAccountBalance(modelData, store.accountNameOverrides, store.cardOverviews)
                    + (index < root.accountBalances.length - 1 ? "  ·" : "")
                  color: Qt.darker(root.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Runs the HDFC fetcher in a visible browser window (a QR scan
            // on your phone is needed every run). Its log goes to
            // output/widget-fetch.log; the button is disabled while running.
            PanelActionButton {
              id: fetchButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              size: Style.space(28)
              fontSize: Style.font.bodySmall
              iconText: "⟳"
              tooltipText: fetchProc.running ? "Fetching HDFC data…" : "Fetch HDFC data (opens browser, scan QR)"
              foreground: root.foreground
              hoverColor: Color.accent
              bordered: true
              focusable: true
              enabled: !fetchProc.running
              visible: !fetchProc.running
              onClicked: {
                fetchProc.running = true
              }
            }

            Rectangle {
              id: cancelButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: cancelLabel.implicitWidth + Style.space(20)
              height: Style.space(28)
              radius: Style.cornerRadius
              color: cancelHover.hovered ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.25) : "transparent"
              border.width: 1
              border.color: Color.urgent
              visible: fetchProc.running

              HoverHandler {
                id: cancelHover
              }

              Text {
                id: cancelLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Cancel"
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.fetchCancelled = true
                  cancelProc.running = true
                  fetchProc.running = false
                }
              }
            }
          }

          Text {
            // Only while a fetch is running. The last message stays in
            // output/fetch-status.json, but it isn't shown once its run is over.
            visible: fetchProc.running && (root.fetchStatus.message || "") !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.fetchStatus.message || ""
            color: root.fetchStatus.stage === "error" ? Color.urgent : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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

        PanelSeparator { visible: root.showArchived; foreground: root.foreground }

        Column {
          visible: root.showArchived
          width: parent.width
          spacing: Style.spacing.lg

          PanelSectionHeader { text: "ARCHIVED"; foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            Repeater {
              model: root.archivedList
              delegate: ArchivedRow {
                required property var modelData
                width: parent.width
                txn: modelData
              }
            }

            Text {
              visible: root.archivedList.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: "Nothing archived yet."
              color: Qt.darker(root.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

      }
    }
  }

  // Full-width clickable row used for the "Archive tracked" action. Same
  // hover/border language as Toggle.qml, without the switch.
  component ActionRow: BorderSurface {
    id: actionRow
    property string label: ""
    property bool rowEnabled: true
    signal clicked()

    readonly property bool _hot: rowEnabled && (mouse.containsMouse || actionRow.activeFocus)

    implicitHeight: Style.space(44)
    implicitWidth: Style.space(240)
    radius: Style.cornerRadius
    // Accent-toned so the action stands out from the plain rows above/below.
    color: rowEnabled ? Style.controlFill(actionRow.activeFocus, _hot, Color.accent, Color.accent) : "transparent"
    borderSpec: Border.controlSpec(actionRow.activeFocus ? "focus" : (_hot ? "hover-cursor" : "normal"), Color.accent, Color.accent)

    activeFocusOnTab: actionRow.rowEnabled
    Keys.onReturnPressed: if (actionRow.rowEnabled) actionRow.clicked()
    Keys.onEnterPressed: if (actionRow.rowEnabled) actionRow.clicked()
    Keys.onSpacePressed: if (actionRow.rowEnabled) actionRow.clicked()
    Keys.onUpPressed: root.focusNext(actionRow, false)
    Keys.onDownPressed: root.focusNext(actionRow, true)

    Behavior on color { ColorAnimation { duration: 100 } }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: actionRow.label
      color: actionRow.rowEnabled ? Color.accent : Qt.darker(root.foreground, 2.0)
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      enabled: actionRow.rowEnabled
      hoverEnabled: true
      cursorShape: actionRow.rowEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: actionRow.clicked()
    }
  }

  // Card for an archived transaction, matching TransactionCard's visual
  // language (dimmed, to read as "inert") but read-only otherwise, except
  // for one action: hover OR keyboard focus reveals a "↩" to restore it
  // back to RECENT (Enter/Space also restores) — archiving used to be a
  // one-way trip with no keyboard path back at all, this fixes both.
  component ArchivedRow: BorderSurface {
    id: archivedRow
    property var txn: null
    readonly property bool _hot: archiveHover.hovered || archivedRow.activeFocus

    implicitHeight: Style.space(52)
    radius: Style.cornerRadius
    color: "transparent"
    opacity: 0.6
    borderSpec: archivedRow.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()

    Behavior on opacity { NumberAnimation { duration: 100 } }

    activeFocusOnTab: true
    Keys.onReturnPressed: store.unarchive(archivedRow.txn.id)
    Keys.onEnterPressed: store.unarchive(archivedRow.txn.id)
    Keys.onSpacePressed: store.unarchive(archivedRow.txn.id)
    Keys.onUpPressed: root.focusNext(archivedRow, false)
    Keys.onDownPressed: root.focusNext(archivedRow, true)

    HoverHandler {
      id: archiveHover
    }

    Rectangle {
      id: avatar
      width: Style.space(36)
      height: width
      radius: width / 2
      color: archivedRow.txn ? Util.alpha(root.directionColor(archivedRow.txn), 0.22) : "transparent"
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: archivedRow.txn && archivedRow.txn.amount < 0 ? "↓" : "↑"
        color: archivedRow.txn ? root.directionColor(archivedRow.txn) : root.foreground
        font.bold: true
        font.pixelSize: Style.font.subtitle
      }
    }

    Column {
      anchors.left: avatar.right
      anchors.leftMargin: Style.space(10)
      anchors.right: amountText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: archivedRow.txn ? Model.transactionDisplayName(archivedRow.txn, store.transactionNameOverrides) : ""
        color: root.foreground
        font.family: Style.font.family
        font.bold: true
        font.pixelSize: Style.font.subtitle
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: archivedRow.txn ? (Model.formatRelativeDate(archivedRow.txn.date) + "  ·  " + Model.formatAccount(archivedRow.txn, store.accountNameOverrides, store.cardOverviews)) : ""
        color: Qt.darker(root.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: amountText
      visible: !archivedRow._hot
      textFormat: Text.PlainText
      text: archivedRow.txn ? Model.formatAmount(archivedRow.txn) : ""
      color: archivedRow.txn ? root.directionColor(archivedRow.txn) : root.foreground
      font.family: Style.font.family
      font.bold: true
      font.pixelSize: Style.font.subtitle
      anchors.right: parent.right
      anchors.rightMargin: root.amountInset
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      visible: archivedRow._hot
      textFormat: Text.PlainText
      text: "↩ restore"
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: store.unarchive(archivedRow.txn.id)
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
      // TransactionCard's editBtn/expandBtn overriding cardMouse beneath.
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
  // FilterChip Flow and the standalone "Show archived" Toggle row — both
  // just narrow what RECENT shows, so they're folded into one popover that
  // costs a single small row while closed AND while open (a popover floats
  // over the content below instead of pushing it down, unlike an inline
  // disclosure). The accent dot shows at a glance whether any non-default
  // filter is active without opening it.
  component FilterMenuButton: BorderSurface {
    id: filterButton
    readonly property bool filterActive: root.accountFilters.length > 0 || root.showArchived
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
            label: modelData.label
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

        // Stays open on click, like the account rows above — a boolean
        // toggle, not an account pick.
        Toggle {
          width: parent.width
          label: "Show archived"
          description: root.archivedCount + " archived"
          checked: root.showArchived
          foreground: root.foreground
          onClicked: root.showArchived = !root.showArchived
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: Qt.darker(root.foreground, 1.8)
        }

        // One-shot data action (not a view filter), but still lives here
        // rather than its own always-visible row — same reasoning as
        // folding "Show archived" in: closes the popover on click, same
        // as the account rows above.
        ActionRow {
          width: parent.width
          label: root.pendingTrackedCount > 0 ? ("Archive tracked (" + root.pendingTrackedCount + ")") : "Archive tracked"
          rowEnabled: root.pendingTrackedCount > 0
          onClicked: { store.archiveTracked(); filterPopup.close() }
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

    HdfcMark {
      id: rowBankMark
      bank: menuRow.bank
      markHeight: Style.spaceReal(9)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    BrandMark {
      id: rowMark
      network: menuRow.network
      markHeight: Style.spaceReal(9)
      anchors.left: rowBankMark.visible ? rowBankMark.right : parent.left
      anchors.leftMargin: rowBankMark.visible ? Style.space(4) : Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      anchors.left: rowMark.visible ? rowMark.right : (rowBankMark.visible ? rowBankMark.right : parent.left)
      anchors.leftMargin: Style.space(6)
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

  // One RECENT row, card-style: a circular direction icon, merchant name +
  // account pill, amount on the right — clicking the row toggles "tracked"
  // (shown as a tinted background instead of a switch), and hovering
  // reveals an edit pencil that swaps the row for an inline TextField to
  // rename this UPI counterparty's displayed merchant (the raw scraped
  // text is often an ugly UPI string). The rename is keyed by
  // Model.transactionGroupKey — not the transaction's own id — so it
  // applies to every past AND future transaction from the same
  // counterparty, not just this one row. Shown wherever a matching
  // transaction appears (RECENT, archived) — it never changes the
  // underlying data, only the display.
  component TransactionCard: BorderSurface {
    id: card
    required property var txn

    property bool editing: false
    // Expanded detail panel (raw merchant text, full date, full account,
    // explicit tracked state) below the collapsed row — separate from the
    // row-click/Enter/Space "toggle tracked" action so neither takes over
    // the other: click/Enter/Space still toggles tracked same as always,
    // the chevron (or Left/Right) is the only way to expand.
    property bool expanded: false
    readonly property bool showDetails: card.expanded && !card.editing
    readonly property string groupKey: Model.transactionGroupKey(txn)
    readonly property string displayMerchant: Model.transactionDisplayName(txn, store.transactionNameOverrides)
    readonly property string accountName: Model.cardBrandParts(Model.formatAccount(txn, store.accountNameOverrides, store.cardOverviews).split(" ••")[0]).label + " ••" + txn.last4
    readonly property string note: Model.transactionNote(txn)
    readonly property bool isDebit: txn.amount < 0
    readonly property color directionColor: root.directionColor(txn)
    readonly property bool _hot: rowHover.hovered || card.activeFocus
    readonly property int collapsedHeight: Style.space(52)

    implicitHeight: card.collapsedHeight + (card.showDetails ? detailsPanel.implicitHeight + Style.space(10) : 0)
    radius: Style.cornerRadius
    opacity: cardMouse.pressed ? 0.75 : 1.0
    color: card.txn.tracked ? root.rowBg(card.txn) : (card._hot ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent")
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
    Keys.onPressed: if (!card.editing && event.key === Qt.Key_F2) { card.editing = true; event.accepted = true }
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
        id: avatar
        visible: !card.editing
        width: Style.space(36)
        height: width
        radius: width / 2
        color: Util.alpha(card.directionColor, 0.22)
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter

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

          Rectangle {
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.12)
            implicitWidth: pillText.implicitWidth + Style.space(10)
            implicitHeight: pillText.implicitHeight + Style.space(4)

            Text {
              id: pillText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: card.accountName
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
        anchors.right: parent.right
        anchors.rightMargin: root.amountInset
        anchors.verticalCenter: parent.verticalCenter
      }

      // Reveals on hover OR keyboard focus (so Tab-only users can still
      // reach rename — hover alone would leave them unreachable).
      Text {
        id: editBtn
        visible: !card.editing && card._hot
        anchors.right: expandBtn.left
        anchors.rightMargin: Style.space(6)
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

      // Expand/collapse the detail panel below — always visible (not
      // hover-gated like the rename pencil), since "more detail on click"
      // is a primary feature here, not a rare secondary one. Its own
      // MouseArea consumes the click before it reaches cardMouse behind
      // it, same precedent as editBtn.
      Text {
        id: expandBtn
        visible: !card.editing
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: card.expanded ? "▴" : "▾"
        color: card._hot ? root.foreground : Qt.darker(root.foreground, 1.4)
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: card.expanded = !card.expanded
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
