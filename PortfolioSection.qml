import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Portfolio.js" as Portfolio

// The PORTFOLIO tab: net worth, allocation, holdings and the activity
// worked out from consecutive snapshots.
//
// A file of its own because Panel.qml is already 2900 lines. The cost of
// that is the plumbing below: a separate file cannot see Panel's `root`
// or `store`, so everything it needs arrives as a property and everything
// it changes leaves as a signal — the same arrangement FetchControl.qml
// documents. The delegates stay inline components here, where they can
// reach this file's root, rather than becoming four more files each
// needing the same plumbing again.
//
// Data comes from `txdb snapshot` (txdb/portfolio.py); the maths and the
// grouping are in Portfolio.js, which node can test without a shell.
Column {
  id: section

  // --- what Panel.qml passes in ---
  property var portfolio: ({})
  property var holdings: []
  property var allocation: []
  property var activity: []
  property var history: []
  property color foreground: Color.foreground
  property color creditColor: "#3ea34d"
  property color debitColor: Color.urgent
  property color pendingColor: "#D9A441"
  // Panel owns the Flickable and the focus chain, so these are its
  // functions, called rather than reimplemented.
  property var focusNext: function (item, forward) {}
  property var scrollIntoView: function (item) {}
  // The popup's one search box, shared with the BANK tab.
  property string searchQuery: ""
  property bool fetchRunning: false
  property bool fetchAllowed: true
  property string fetchStatusText: ""

  signal fetch()
  signal cancel()
  // Marking an investment "already recorded elsewhere" reuses the bank
  // side's `tracked` table, so this is the same toggle, by row id.
  signal toggleTracked(string id, bool value)

  spacing: Style.spacing.lg

  // --- derived ---
  readonly property var summary: Portfolio.summary(section.portfolio, section.holdings)
  property var kindFilters: []
  property var brokerFilters: []
  readonly property var visibleHoldings: Portfolio.filterHoldings(
    section.holdings, section.kindFilters, section.brokerFilters, section.searchQuery)
  readonly property var groups: Portfolio.groupByKind(section.visibleHoldings)
  readonly property var alloc: Portfolio.allocationSegments(section.allocation, section.holdings)
  readonly property var spark: Portfolio.sparkline(section.history)
  readonly property var concentration: Portfolio.concentration(section.holdings, 5)
  readonly property var overlaps: Portfolio.categoryOverlap(section.holdings)
  readonly property var flows: Portfolio.netInvested(section.activity)
  readonly property var drawdown: Portfolio.drawdown(section.history)
  readonly property bool empty: section.holdings.length === 0
  // The fetch stopped because the session expired. Worth its own state:
  // the fix is one command, and saying so beats a red line that only
  // says something failed.
  readonly property bool needsSignIn: (section.portfolio.lastMessage || "").indexOf("indmoney-login") !== -1
  readonly property var activityGroups: Model.groupByDate(section.activity.map(function (a) {
    // groupByDate wants an amount and a currency; an investment row's
    // amount is signed the way a bank row's is, so a SIP reads as money
    // out and a sale as money in, and the day totals mean one thing
    // across both tabs.
    // `amount` feeds the day total, `shown` feeds the row. They differ
    // for an opening position, which is real money but was not moved on
    // the day it was first seen — see Portfolio.activityMoved.
    return Object.assign({}, a, {
      amount: !Portfolio.activityMoved(a.kind) ? 0
        : (Portfolio.activityIsOutflow(a.kind) ? -Math.abs(a.amount || 0) : Math.abs(a.amount || 0)),
      shown: Math.abs(a.amount || 0),
      currency: "INR"
    })
  }))

  // Fixed columns, so every holding row gives the name the same budget
  // and the figures line up down the popup — the same reasoning as the
  // BILLS row's billStatusWidth / billFigureWidth.
  readonly property int holdingFigureWidth: Style.space(96)
  readonly property int holdingAvatarWidth: Style.space(30)
  readonly property int contentLeft: Style.spacing.rowPaddingX + holdingAvatarWidth + Style.spacing.md

  // Thousands separators above a unit, significant figures below one --
  // see Portfolio.formatUnits for why a fractional share needs them.
  function unitText(units) {
    var n = Math.abs(Number(units) || 0)
    return n && n < 1 ? Portfolio.formatUnits(units) : Model.formatGrouped(units)
  }

  function pnlColor(amount) {
    return amount < 0 ? section.debitColor : section.creditColor
  }

  function money(amount) {
    return Model.currencySymbol("INR") + Model.formatGrouped(amount)
  }

  function signedMoney(amount) {
    return (amount < 0 ? "-" : "+") + section.money(Math.abs(amount))
  }

  function signedPercent(percent) {
    return (percent < 0 ? "" : "+") + percent.toFixed(1) + "%"
  }

  // ---------------------------------------------------------------------
  // Net worth block. Mirrors the BANK tab's month summary: no header and
  // no separator of its own, because the tab strip above already said
  // what this is.
  // ---------------------------------------------------------------------
  Column {
    width: parent.width
    spacing: Style.spacing.xs

    Item {
      width: parent.width
      height: Math.max(netWorthText.implicitHeight, headerSpark.height, indChip.height)

      Text {
        id: netWorthText
        anchors.left: parent.left
        anchors.top: parent.top
        textFormat: Text.PlainText
        text: section.empty ? "No portfolio yet"
          : section.money(section.summary.netWorth)
        color: section.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        anchors.left: netWorthText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.baseline: netWorthText.baseline
        visible: !section.empty
        textFormat: Text.PlainText
        text: "net worth"
        color: Qt.darker(section.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // The value line. Only drawn once there are two snapshots to join;
      // one fetch is not a history (see Portfolio.sparkline).
      Sparkline {
        id: headerSpark
        anchors.right: indChip.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: netWorthText.verticalCenter
        width: Style.space(96)
        height: Style.space(22)
        visible: !!section.spark
        filled: true
        points: section.spark ? section.spark.points : []
        lineColor: section.spark && section.spark.change < 0 ? section.debitColor : section.creditColor
      }

      // The reload chip, with INDmoney's mark as the button — the same
      // control the four bank chips use.
      FetchControl {
        id: indChip
        anchors.right: parent.right
        anchors.verticalCenter: netWorthText.verticalCenter
        bank: "indmoney"
        running: section.fetchRunning
        allowed: section.fetchAllowed
        foreground: section.foreground
        idleTooltip: section.needsSignIn
          ? "Sign in again: bin/indmoney-login"
          : "Refresh the INDmoney portfolio"
        scrollIntoView: section.scrollIntoView
        onFetch: section.fetch()
        onCancel: section.cancel()
      }
    }

    // invested → value, and what that came to.
    Flow {
      width: parent.width
      spacing: Style.spacing.md
      visible: !section.empty

      Text {
        textFormat: Text.PlainText
        text: "invested " + section.money(section.summary.invested)
          + "  →  " + section.money(section.summary.value)
        color: Qt.darker(section.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: section.signedMoney(section.summary.pnl)
          + "  (" + section.signedPercent(section.summary.pnlPct) + ")"
        color: section.pnlColor(section.summary.pnl)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        visible: section.summary.dayChange !== 0
        textFormat: Text.PlainText
        text: "today " + section.signedMoney(section.summary.dayChange)
          + " (" + section.signedPercent(section.summary.dayChangePct) + ")"
        color: section.pnlColor(section.summary.dayChange)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: section.summary.xirr !== null && section.summary.xirr !== undefined
        textFormat: Text.PlainText
        text: "XIRR " + (section.summary.xirr || 0).toFixed(1) + "%"
        color: Qt.darker(section.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // How old the figures are, said plainly. Amber once they are a day
    // behind, red when the session has expired — a number that looks
    // current but is not is the failure worth avoiding.
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: section.needsSignIn
        ? "INDmoney wants a fresh sign-in — run bin/indmoney-login"
        : (section.empty
            ? "Nothing fetched yet. Sign in with bin/indmoney-login, then press the chip above."
            : "as of " + Model.formatShortDate(section.summary.asOf, false)
              + "  ·  " + Portfolio.ageLabel(section.summary.asOf)
              + (section.summary.count ? "  ·  " + section.summary.count + " holdings" : ""))
      color: section.needsSignIn ? Color.urgent
        : (section.summary.stale ? section.pendingColor : Qt.darker(section.foreground, 1.5))
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // The server's own total disagreeing with the rows it sent is worth
    // saying out loud rather than quietly preferring one of them.
    Text {
      width: parent.width
      visible: section.summary.disagrees
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: "INDmoney's total (" + section.money(section.portfolio.value || 0)
        + ") disagrees with its own holdings (" + section.money(section.summary.value)
        + "). The rows are shown."
      color: section.pendingColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: section.fetchStatusText !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: section.fetchStatusText
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------------------------------------------------------------
  // ALLOCATION — one bar, a key under it, and the per-bucket strips on
  // click. Lifted from the credit-limit bar in the BANK tab, which had
  // already solved the segmented-track-plus-legend problem.
  // ---------------------------------------------------------------------
  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: !section.empty && section.alloc.segments.length > 0

    Item {
      width: parent.width
      height: allocHeader.implicitHeight

      PanelSectionHeader {
        id: allocHeader
        anchors.left: parent.left
        text: "ALLOCATION"
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: allocHeader.verticalCenter
        textFormat: Text.PlainText
        text: section.money(section.alloc.total)
        color: Qt.darker(section.foreground, 1.3)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    BorderSurface {
      id: allocBar
      width: parent.width
      property bool expanded: false
      readonly property bool _hot: allocHover.hovered || allocBar.activeFocus
      implicitHeight: allocTrack.height + Style.space(10)
      radius: Style.cornerRadius
      color: allocBar._hot ? Style.controlFill(false, true, section.foreground, Color.accent) : "transparent"
      borderSpec: allocBar.activeFocus
        ? Border.controlSpec("focus", section.foreground, Color.accent) : Border.none()

      activeFocusOnTab: true
      Keys.onReturnPressed: allocBar.expanded = !allocBar.expanded
      Keys.onEnterPressed: allocBar.expanded = !allocBar.expanded
      Keys.onSpacePressed: allocBar.expanded = !allocBar.expanded
      Keys.onLeftPressed: allocBar.expanded = false
      Keys.onRightPressed: allocBar.expanded = true
      Keys.onUpPressed: section.focusNext(allocBar, false)
      Keys.onDownPressed: section.focusNext(allocBar, true)

      HoverHandler { id: allocHover }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { allocBar.forceActiveFocus(); allocBar.expanded = !allocBar.expanded }
      }

      Item {
        id: allocTrack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(8)

        Rectangle {
          anchors.fill: parent
          radius: height / 2
          color: Qt.darker(section.foreground, 3.0)
        }

        Row {
          anchors.left: parent.left
          height: parent.height
          spacing: 0

          Repeater {
            model: section.alloc.segments
            delegate: Rectangle {
              required property var modelData
              required property int index
              height: allocTrack.height
              // At least a pixel: a 0.3% bucket that renders as nothing
              // reads as a missing bucket, not a small one.
              width: Math.max(1, allocTrack.width * Math.min(1, Math.max(0, modelData.fraction)))
              radius: height / 2
              color: index % 2 === 0 ? Color.accent : Util.alpha(Color.accent, 0.55)
              Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            }
          }
        }
      }
    }

    // The key, and the per-bucket detail underneath it once opened.
    Flow {
      width: parent.width
      spacing: Style.spacing.md

      Repeater {
        model: section.alloc.segments
        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          text: modelData.bucket + " " + section.money(modelData.value)
            + "  " + modelData.percent.toFixed(0) + "%"
          color: Qt.darker(section.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // The lines worth reading that no single figure says. Each one is
  // suppressed unless it has something to report, so the block is empty
  // on a simple portfolio rather than padded with zeros.
  // ---------------------------------------------------------------------
  Column {
    width: parent.width
    spacing: Style.spacing.xxs
    visible: !section.empty && insightRepeater.count > 0

    Repeater {
      id: insightRepeater
      model: [
        section.concentration && section.concentration.percent >= 50
          ? "Top " + section.concentration.count + " hold " + section.concentration.percent.toFixed(0)
            + "% — " + section.concentration.largest + " alone is "
            + section.concentration.largestPercent.toFixed(0) + "%"
          : "",
        section.overlaps.length > 0
          ? section.overlaps[0].count + " " + section.overlaps[0].category + " funds, "
            + section.overlaps[0].percent.toFixed(0) + "% of the portfolio"
          : "",
        section.flows.invested > 0 || section.flows.withdrawn > 0
          ? "This month: " + section.money(section.flows.invested) + " in"
            + (section.flows.sip > 0 ? " (" + section.money(section.flows.sip) + " by SIP)" : "")
            + (section.flows.withdrawn > 0 ? ", " + section.money(section.flows.withdrawn) + " out" : "")
          : "",
        section.drawdown && section.drawdown.percent >= 5
          ? section.drawdown.percent.toFixed(1) + "% below its peak of "
            + section.money(section.drawdown.peak)
          : ""
      ].filter(function (line) { return line !== "" })
      delegate: Text {
        required property var modelData
        width: section.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "· " + modelData
        color: Qt.darker(section.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  PanelSeparator { visible: !section.empty }

  // ---------------------------------------------------------------------
  // HOLDINGS — one sub-group per asset kind, each carrying its own value
  // and P&L, the same shape RECENT's per-day headers have.
  // ---------------------------------------------------------------------
  Column {
    width: parent.width
    spacing: Style.spacing.md
    visible: !section.empty

    Item {
      width: parent.width
      height: holdingsHeader.implicitHeight

      PanelSectionHeader {
        id: holdingsHeader
        anchors.left: parent.left
        text: "HOLDINGS"
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: holdingsHeader.verticalCenter
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: "value " + section.money(section.summary.value)
          color: Qt.darker(section.foreground, 1.3)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          text: section.signedMoney(section.summary.pnl)
          color: section.pnlColor(section.summary.pnl)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Repeater {
      model: section.groups
      delegate: Column {
        required property var modelData
        width: parent.width
        spacing: Style.spacing.xs

        Item {
          width: parent.width
          height: groupLabel.implicitHeight

          Text {
            id: groupLabel
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: modelData.label
            color: Qt.darker(section.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: groupLabel.verticalCenter
            textFormat: Text.PlainText
            text: section.money(modelData.value)
              + (modelData.costKnown
                  ? "   " + section.signedPercent(modelData.pnlPct) : "")
            color: modelData.costKnown
              ? section.pnlColor(modelData.pnl) : Qt.darker(section.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xxs

          Repeater {
            model: modelData.rows
            delegate: HoldingRow {
              required property var modelData
              width: parent.width
              holding: modelData
            }
          }
        }
      }
    }

    Text {
      visible: section.visibleHoldings.length === 0
      width: parent.width
      textFormat: Text.PlainText
      text: section.searchQuery !== "" ? "No holdings match the search."
        : "No holdings for the selected filters."
      color: Qt.darker(section.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  PanelSeparator { visible: section.activity.length > 0 }

  // ---------------------------------------------------------------------
  // ACTIVITY — the buys and sells worked out by diffing snapshots. Every
  // row says so, because no statement was ever read.
  // ---------------------------------------------------------------------
  Column {
    width: parent.width
    spacing: Style.spacing.md
    visible: section.activity.length > 0

    Column {
      width: parent.width
      spacing: Style.spacing.xxs

      PanelSectionHeader { text: "ACTIVITY" }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Worked out by comparing daily snapshots — INDmoney has no "
          + "transaction history to read."
        color: Qt.darker(section.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Repeater {
      model: section.activityGroups
      delegate: Column {
        required property var modelData
        width: parent.width
        spacing: Style.spacing.xs

        Item {
          width: parent.width
          height: dayLabel.implicitHeight

          Text {
            id: dayLabel
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: modelData.label
            color: Qt.darker(section.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: dayLabel.verticalCenter
            textFormat: Text.PlainText
            visible: modelData.total !== 0
            text: Model.formatAmount({ amount: modelData.total, currency: modelData.currency })
            color: section.pnlColor(modelData.total)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xxs

          Repeater {
            model: modelData.rows
            delegate: ActivityRow {
              required property var modelData
              width: parent.width
              entry: modelData
            }
          }
        }
      }
    }
  }

  // =====================================================================
  // Delegates. Inline components, so they can reach `section` directly
  // instead of taking the whole plumbing above a second time.
  // =====================================================================

  component HoldingRow: BorderSurface {
    id: holdingRow
    required property var holding
    property bool expanded: false
    readonly property bool _hot: holdingHover.hovered || holdingRow.activeFocus
    readonly property int collapsedHeight: Style.space(46)
    readonly property real pnl: holdingRow.holding.pnl || 0
    readonly property bool costKnown: Portfolio.costKnown(holdingRow.holding)

    implicitHeight: holdingRow.collapsedHeight
      + (holdingRow.expanded ? holdingDetails.implicitHeight + Style.space(10) : 0)
    radius: Style.cornerRadius
    color: holdingRow._hot
      ? Style.controlFill(false, true, section.foreground, Color.accent) : "transparent"
    borderSpec: holdingRow.activeFocus
      ? Border.controlSpec("focus", section.foreground, Color.accent) : Border.none()

    Behavior on implicitHeight { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }

    HoverHandler { id: holdingHover }

    activeFocusOnTab: true
    Keys.onReturnPressed: holdingRow.expanded = !holdingRow.expanded
    Keys.onEnterPressed: holdingRow.expanded = !holdingRow.expanded
    Keys.onSpacePressed: holdingRow.expanded = !holdingRow.expanded
    Keys.onLeftPressed: holdingRow.expanded = false
    Keys.onRightPressed: holdingRow.expanded = true
    Keys.onUpPressed: section.focusNext(holdingRow, false)
    Keys.onDownPressed: section.focusNext(holdingRow, true)

    Item {
      id: holdingCollapsed
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: holdingRow.collapsedHeight

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          holdingRow.forceActiveFocus()
          holdingRow.expanded = !holdingRow.expanded
        }
      }

      // The fund house's or the exchange's initial, in a disc. No logos:
      // there are forty AMCs and the four bank marks took a day each.
      Rectangle {
        id: holdingAvatar
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: section.holdingAvatarWidth
        height: width
        radius: width / 2
        color: Util.alpha(Color.accent, 0.18)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: (holdingRow.holding.amc || holdingRow.holding.symbol
                 || holdingRow.holding.name || "?").charAt(0).toUpperCase()
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Column {
        anchors.left: holdingAvatar.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: holdingFigures.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.hairline

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: holdingRow.holding.name
          elide: Text.ElideRight
          color: section.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          spacing: Style.spacing.xs

          // A weight bar rather than a number: at a glance the row says
          // how much of the portfolio it is, and the exact figure is in
          // the detail panel for when it matters.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(28)
            height: Style.space(3)
            radius: height / 2
            color: Qt.darker(section.foreground, 3.0)

            Rectangle {
              width: parent.width * Math.min(1, (holdingRow.holding.weight || 0) / 100)
              height: parent.height
              radius: height / 2
              color: Color.accent
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            textFormat: Text.PlainText
            text: [holdingRow.holding.category, holdingRow.holding.broker]
              .filter(function (part) { return !!part }).join(" · ")
            color: Qt.darker(section.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Column {
        id: holdingFigures
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        width: section.holdingFigureWidth
        spacing: Style.spacing.hairline

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: section.money(holdingRow.holding.value || 0)
          color: section.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: holdingRow.costKnown
            ? section.signedMoney(holdingRow.pnl)
              + " (" + section.signedPercent(holdingRow.holding.pnlPct || 0) + ")"
            : "cost not known"
          color: holdingRow.costKnown
            ? section.pnlColor(holdingRow.pnl) : Qt.darker(section.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      id: holdingDetails
      anchors.top: holdingCollapsed.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: section.contentLeft
      anchors.rightMargin: Style.spacing.rowPaddingX
      visible: holdingRow.expanded
      opacity: holdingRow.expanded ? 1 : 0
      spacing: Style.spacing.xxs

      Behavior on opacity { NumberAnimation { duration: 120 } }

      Repeater {
        model: [
          { label: "Units", value: holdingRow.holding.units
              ? section.unitText(holdingRow.holding.units) : "" },
          { label: holdingRow.holding.kind === "mf" ? "Average NAV" : "Average price",
            value: holdingRow.holding.avgCost ? section.money(holdingRow.holding.avgCost) : "" },
          { label: holdingRow.holding.kind === "mf" ? "Current NAV" : "Last price",
            value: holdingRow.holding.price ? section.money(holdingRow.holding.price) : "" },
          { label: "Invested", value: holdingRow.holding.invested
              ? section.money(holdingRow.holding.invested) : "" },
          { label: "Current value", value: holdingRow.holding.value
              ? section.money(holdingRow.holding.value) : "" },
          { label: "Profit / loss", value: holdingRow.pnl
              ? section.signedMoney(holdingRow.pnl) + "  ("
                + section.signedPercent(holdingRow.holding.pnlPct || 0) + ")" : "" },
          { label: "XIRR", value: holdingRow.holding.xirr
              ? holdingRow.holding.xirr.toFixed(2) + "%" : "" },
          { label: "Today", value: holdingRow.holding.dayChange
              ? section.signedMoney(holdingRow.holding.dayChange) : "" },
          { label: "Share of portfolio", value: holdingRow.holding.weight
              ? holdingRow.holding.weight.toFixed(2) + "%" : "" },
          { label: "Category", value: holdingRow.holding.category || "" },
          { label: holdingRow.holding.kind === "mf" ? "Fund house" : "Exchange",
            value: holdingRow.holding.amc || "" },
          { label: "Held at", value: holdingRow.holding.broker || "" },
          { label: "Symbol", value: holdingRow.holding.symbol || "" },
          { label: "ISIN", value: holdingRow.holding.isin || "" },
          { label: "First seen", value: holdingRow.holding.firstHeld
              ? Model.formatShortDate(holdingRow.holding.firstHeld, true)
                + (Portfolio.daysHeld(holdingRow.holding) !== null
                    ? "  ·  " + Portfolio.daysHeld(holdingRow.holding) + " days" : "")
              : "" }
        ].filter(function (row) { return row.value })
        delegate: Item {
          required property var modelData
          width: parent.width
          height: Math.max(holdingLabel.implicitHeight, holdingValue.implicitHeight)

          Text {
            id: holdingLabel
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: modelData.label
            color: Qt.darker(section.foreground, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            id: holdingValue
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: modelData.value
            color: section.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }

  component ActivityRow: BorderSurface {
    id: activityRow
    required property var entry
    readonly property bool outflow: Portfolio.activityIsOutflow(activityRow.entry.kind)
    // A position that was simply there the first time we looked, and units
    // from a bonus or split, moved no money. Painting those as an outflow
    // claims a purchase that never happened, and contradicts the day total,
    // which already leaves them out -- see Portfolio.activityMoved.
    readonly property bool moved: Portfolio.activityMoved(activityRow.entry.kind)
    readonly property color markColor: !activityRow.moved
      ? Qt.darker(section.foreground, 1.5)
      : (activityRow.outflow ? section.debitColor : section.creditColor)
    readonly property bool _hot: activityHover.hovered || activityRow.activeFocus
    readonly property int collapsedHeight: Style.space(40)

    implicitHeight: activityRow.collapsedHeight
    radius: Style.cornerRadius
    // Tracked rows get a tinted background rather than a switch — the
    // same treatment, and the same meaning, as a tracked bank row.
    color: activityRow.entry.tracked
      ? Util.alpha(Color.accent, 0.12)
      : (activityRow._hot ? Style.controlFill(false, true, section.foreground, Color.accent) : "transparent")
    borderSpec: activityRow.activeFocus
      ? Border.controlSpec("focus", section.foreground, Color.accent) : Border.none()

    Behavior on color { ColorAnimation { duration: 100 } }

    HoverHandler { id: activityHover }

    activeFocusOnTab: true
    Keys.onReturnPressed: section.toggleTracked(activityRow.entry.id, !activityRow.entry.tracked)
    Keys.onEnterPressed: section.toggleTracked(activityRow.entry.id, !activityRow.entry.tracked)
    Keys.onSpacePressed: section.toggleTracked(activityRow.entry.id, !activityRow.entry.tracked)
    Keys.onUpPressed: section.focusNext(activityRow, false)
    Keys.onDownPressed: section.focusNext(activityRow, true)

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        activityRow.forceActiveFocus()
        section.toggleTracked(activityRow.entry.id, !activityRow.entry.tracked)
      }
    }

    Rectangle {
      id: activityAvatar
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(24)
      height: width
      radius: width / 2
      color: Util.alpha(activityRow.markColor, 0.20)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: !activityRow.moved ? "•" : (activityRow.outflow ? "↓" : "↑")
        color: activityRow.markColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Column {
      anchors.left: activityAvatar.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: activityAmount.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.hairline

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: activityRow.entry.name
        elide: Text.ElideRight
        color: section.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: Portfolio.activityLabel(activityRow.entry.kind)
          + (activityRow.entry.units
              ? "  ·  " + section.unitText(activityRow.entry.units) + " units" : "")
          + (activityRow.entry.price
              ? " @ " + section.money(activityRow.entry.price) : "")
          // Said on every row, not once in the header: a figure nobody
          // read off a statement should carry that with it.
          + (activityRow.entry.inferred ? "  ·  worked out, not read" : "")
        color: Qt.darker(section.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: activityAmount
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.money(activityRow.entry.shown || 0)
      color: activityRow.markColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }
}
