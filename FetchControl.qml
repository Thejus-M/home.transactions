import QtQuick
import QtQuick.Controls
import qs.Commons

// One bank's reload control: the bank's logo is the reload button. Clicking
// it starts the fetch and the logo spins while the fetch runs; Cancel appears
// beside it during the run. Each bank has its own control, so the two stay
// apart.
Item {
  id: root

  // "hdfc" or "axis": which logo the button shows.
  property string bank: "hdfc"
  property bool running: false
  // False while the other bank's fetch runs (only one fetch at a time).
  property bool allowed: true
  property string idleTooltip: ""
  property color foreground: Color.foreground
  signal fetch()
  signal cancel()

  readonly property real logoSize: Style.space(16)
  readonly property real gap: Style.spacing.xs

  implicitWidth: logoSize + (running ? gap + cancelBox.width : 0)
  implicitHeight: Style.space(28)
  width: implicitWidth
  height: implicitHeight

  // Stop the logo level when the run ends, wherever the spin had reached.
  onRunningChanged: if (!running) logoButton.rotation = 0

  Rectangle {
    id: cancelBox
    visible: root.running
    anchors.right: logoButton.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    width: cancelLabel.implicitWidth + Style.space(20)
    height: Style.space(26)
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

  Item {
    id: logoButton
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.logoSize
    height: width
    opacity: root.allowed || root.running ? 1.0 : 0.35
    scale: logoMouse.pressed ? 0.8 : 1.0
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 120 } }

    // One full turn on click; keeps turning while the fetch runs.
    NumberAnimation on rotation {
      id: spin
      running: root.running
      from: 0
      to: 360
      duration: 900
      loops: Animation.Infinite
    }

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

    ToolTip.visible: logoHover.hovered && root.idleTooltip !== "" && !root.running
    ToolTip.text: root.idleTooltip
    ToolTip.delay: 400

    MouseArea {
      id: logoMouse
      anchors.fill: parent
      enabled: root.allowed && !root.running
      cursorShape: Qt.PointingHandCursor
      onClicked: root.fetch()
    }
  }
}
