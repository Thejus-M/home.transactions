import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Transactions widget: bar icon + click-to-open popup listing recent
// transactions, each with a toggle for "already recorded elsewhere".
//
// Phase 1: dummy data (Model.dummyTransactions()) + tracked-state persisted
// to a local JSON file. Phase 2 will swap the backing store for a real
// bank-scrape + DB pipeline without changing this UI — see README.md.
Panel {
  id: root
  moduleName: "home.transactions"
  ipcTarget: "home.transactions"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property var transactions: store.transactions
  readonly property int untrackedCount: transactions.filter(function (t) { return !t.tracked }).length

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) trackedFile.reload()

  QtObject {
    id: store
    property var transactions: Model.dummyTransactions()

    function applyTrackedOverrides(overrides) {
      var base = Model.dummyTransactions()
      for (var i = 0; i < base.length; i++) {
        if (Object.prototype.hasOwnProperty.call(overrides, base[i].id)) {
          base[i] = Object.assign({}, base[i], { tracked: !!overrides[base[i].id] })
        }
      }
      transactions = base
    }

    function setTracked(id, value) {
      var list = transactions.slice()
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === id) list[i] = Object.assign({}, list[i], { tracked: value })
      }
      transactions = list
      persist()
    }

    function persist() {
      var overrides = {}
      for (var i = 0; i < transactions.length; i++) {
        if (transactions[i].tracked) overrides[transactions[i].id] = true
      }
      trackedFile.setText(JSON.stringify(overrides, null, 2) + "\n")
    }
  }

  FileView {
    id: trackedFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/transactions-tracked.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: store.applyTrackedOverrides(JSON.parse(text() || "{}"))
    onLoadFailed: store.applyTrackedOverrides({})
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

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
              description: modelData.date
              checked: modelData.tracked
              foreground: root.foreground
              onClicked: store.setTracked(modelData.id, !modelData.tracked)
            }
          }
        }
      }
    }
  }
}
