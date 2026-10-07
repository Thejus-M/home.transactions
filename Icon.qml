import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Transactions widget: a coin with a dollar sign, plus a
// small badge showing how many transactions are still untracked. Mirrors
// the badge pattern used by TailscaleIcon.qml's warning indicator.
//
// A simplified, monochrome take on a coin-in-hand/pie-chart reference image:
// at the actual bar size (16-24px) the hand and the pie-chart divisions
// collapsed into noise when tried (checked by rendering both at real size),
// so just the coin and the $ survive — legible is more important than
// matching every detail of the reference at this size.
Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property int untrackedCount: 0
  property bool billDue: false

  width: iconSize
  height: iconSize

  Rectangle {
    width: root.iconSize
    height: width
    radius: width / 2
    anchors.centerIn: parent
    color: "transparent"
    border.width: Math.max(1, Math.round(root.iconSize * 0.10))
    border.color: root.color
  }

  Text {
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -root.iconSize * 0.02
    textFormat: Text.PlainText
    text: "$"
    color: root.color
    font.bold: true
    font.pixelSize: root.iconSize * 0.66
  }

  // Bottom-right: numeric untracked-count badge.
  BorderSurface {
    visible: root.untrackedCount > 0
    width: Math.max(7, parent.width * 0.5)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.untrackedCount > 9 ? "9+" : String(root.untrackedCount)
      color: Color.background
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }

  // Top-right: bill-due warning badge, same pattern as TailscaleIcon.qml's
  // warning indicator, at a corner that doesn't collide with the badge above.
  BorderSurface {
    visible: root.billDue
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
    borderSpec: Border.flat(Color.popups.background, 1)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "!"
      color: Color.background
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
