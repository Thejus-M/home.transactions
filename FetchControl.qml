import QtQuick
import qs.Commons
import qs.Ui

// One bank's reload control: the bank's name, then a ⟳ button while idle or a
// Cancel button while that bank's own fetch runs. Each bank has its own, so
// the two reloads stay apart.
Item {
  id: root

  property string label: ""
  property bool running: false
  // False while the other bank's fetch runs (only one fetch at a time).
  property bool allowed: true
  property string idleTooltip: ""
  property color foreground: Color.foreground
  signal fetch()
  signal cancel()

  readonly property real controlWidth: running ? cancelBox.width : Style.space(28)

  implicitWidth: nameText.implicitWidth + Style.spacing.xs + controlWidth
  implicitHeight: Style.space(28)

  Text {
    id: nameText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.label
    color: Qt.darker(root.foreground, 1.3)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PanelActionButton {
    visible: !root.running
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    size: Style.space(28)
    fontSize: Style.font.bodySmall
    iconText: "⟳"
    tooltipText: root.idleTooltip
    foreground: root.foreground
    hoverColor: Color.accent
    bordered: true
    focusable: true
    enabled: root.allowed
    onClicked: root.fetch()
  }

  Rectangle {
    id: cancelBox
    visible: root.running
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: cancelLabel.implicitWidth + Style.space(20)
    height: Style.space(28)
    radius: Style.cornerRadius
    color: cancelHover.hovered ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.25) : "transparent"
    border.width: 1
    border.color: Color.urgent

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
      onClicked: root.cancel()
    }
  }
}
