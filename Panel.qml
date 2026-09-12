import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Transactions widget: bar icon + click-to-open popup listing recent
// transactions, each with a toggle for "already recorded elsewhere".
// An "Archive tracked" button moves every currently-tracked row out of the
// RECENT list into an archive; a "Show archived" toggle reveals them again.
//
// Phase 1: dummy data (Model.dummyTransactions()) + tracked/archived state
// persisted to local JSON files. Phase 2 will swap the backing store for a
// real bank-scrape + DB pipeline without changing this UI — see README.md.
Panel {
  id: root
  moduleName: "home.transactions"
  ipcTarget: "home.transactions"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property var transactions: store.transactions
  readonly property var archivedList: store.archivedList
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked }).length
  readonly property int pendingTrackedCount: transactions.filter(function (t) { return t.tracked }).length
  readonly property int archivedCount: archivedList.length
  property bool showArchived: false

  // Row background tint: green for income, red (theme's urgent tone) for spend.
  readonly property color creditBg: Util.alpha("#3ea34d", 0.20)
  readonly property color debitBg: Util.alpha(Color.urgent, 0.20)
  function rowBg(t) { return t.amount < 0 ? root.debitBg : root.creditBg }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { trackedFile.reload(); archiveFile.reload() }

  QtObject {
    id: store
    property var trackedOverrides: ({})
    property var archivedList: []
    property var transactions: []

    // Rebuilds `transactions` from the dummy base, minus anything archived,
    // with any locally-toggled tracked state applied on top.
    function recompute() {
      var archivedIds = {}
      for (var i = 0; i < archivedList.length; i++) archivedIds[archivedList[i].id] = true
      var base = Model.dummyTransactions()
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
  }

  FileView {
    id: trackedFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-tracked.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setTrackedOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.setTrackedOverrides({})
  }

  FileView {
    id: archiveFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-archive.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.setArchivedList(JSON.parse(text() || "[]"))
    onLoadFailed: store.setArchivedList([])
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
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Transactions"
          meta: root.untrackedCount + " to track"
          foreground: root.foreground
        }

        ActionRow {
          width: parent.width
          label: root.pendingTrackedCount > 0 ? ("Archive tracked (" + root.pendingTrackedCount + ")") : "Archive tracked"
          rowEnabled: root.pendingTrackedCount > 0
          onClicked: store.archiveTracked()
        }

        PanelSeparator { foreground: root.foreground }
        PanelSectionHeader { text: "RECENT"; foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.transactions
            delegate: Toggle {
              required property var modelData
              width: parent.width
              label: modelData.merchant + "  ·  " + Model.formatAmount(modelData)
              description: modelData.date + "  ·  " + Model.formatAccount(modelData)
              checked: modelData.tracked
              foreground: root.foreground
              color: root.rowBg(modelData)
              onClicked: store.setTracked(modelData.id, !modelData.tracked)
            }
          }

          Text {
            visible: root.transactions.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Nothing pending."
            color: Qt.darker(root.foreground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }
        }

        PanelSeparator { foreground: root.foreground }

        Toggle {
          width: parent.width
          label: "Show archived"
          description: root.archivedCount + " archived"
          checked: root.showArchived
          foreground: root.foreground
          onClicked: root.showArchived = !root.showArchived
        }

        Column {
          visible: root.showArchived
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader { text: "ARCHIVED"; foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

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

    readonly property bool _hot: rowEnabled && mouse.containsMouse

    implicitHeight: Style.space(44)
    implicitWidth: Style.space(240)
    radius: Style.cornerRadius
    // Accent-toned so the action stands out from the plain rows above/below.
    color: rowEnabled ? Style.controlFill(false, _hot, Color.accent, Color.accent) : "transparent"
    borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", Color.accent, Color.accent)

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

  // Read-only row for an archived transaction: merchant/amount, then
  // date + bank + checking/credit-card info. Same green/red background
  // tint as the RECENT rows.
  component ArchivedRow: BorderSurface {
    id: archivedRow
    property var txn: null

    implicitHeight: content.implicitHeight + Style.spacing.rowPaddingX
    radius: Style.cornerRadius
    color: txn ? root.rowBg(txn) : "transparent"
    borderSpec: Border.none()

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.xs

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: archivedRow.txn ? (archivedRow.txn.merchant + "  ·  " + Model.formatAmount(archivedRow.txn)) : ""
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: archivedRow.txn ? (archivedRow.txn.date + "  ·  " + Model.formatAccount(archivedRow.txn)) : ""
        color: Qt.darker(root.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
