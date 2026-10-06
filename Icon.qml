import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Transactions widget: a receipt glyph with a small badge
// showing how many transactions are still untracked. Mirrors the badge
// pattern used by TailscaleIcon.qml's warning indicator.
Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property int untrackedCount: 0
  property bool billDue: false

  width: iconSize
  height: iconSize

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: "󰧾"
    color: root.color
    font.pixelSize: root.iconSize
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
