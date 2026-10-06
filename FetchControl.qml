import QtQuick
import QtQuick.Controls
import qs.Commons

// One bank's reload control: the bank's name, then the bank's logo as the
// reload button while idle, or a Cancel button while that bank's own fetch
// runs. Each bank has its own, so the two reloads stay apart.
Item {
  id: root

  property string label: ""
  // "hdfc" or "axis": which logo the idle button shows.
  property string bank: "hdfc"
  property bool running: false
  // False while the other bank's fetch runs (only one fetch at a time).
  property bool allowed: true
  property string idleTooltip: ""
  property color foreground: Color.foreground
  signal fetch()
  signal cancel()

  readonly property real logoSize: Style.space(22)
  readonly property real controlWidth: running ? cancelBox.width : logoSize

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

  // The bank's logo is the reload button: click it to fetch.
  Item {
    id: logoButton
    visible: !root.running
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.logoSize
    height: width
    opacity: root.allowed ? 1.0 : 0.35

    HdfcLogo {
      visible: root.bank === "hdfc"
      anchors.centerIn: parent
      variant: "icon"
      markSize: root.logoSize
    }

    AxisLogo {
      visible: root.bank === "axis"
      anchors.centerIn: parent
      markSize: root.logoSize
    }

    HoverHandler {
      id: logoHover
    }

    ToolTip.visible: logoHover.hovered && root.idleTooltip !== ""
    ToolTip.text: root.idleTooltip
    ToolTip.delay: 400

    MouseArea {
      anchors.fill: parent
      enabled: root.allowed
      cursorShape: Qt.PointingHandCursor
      onClicked: root.fetch()
    }
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
