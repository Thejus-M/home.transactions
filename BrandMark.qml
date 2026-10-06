import QtQuick
import QtQuick.Shapes
import qs.Commons

// Card-network mark: Mastercard's twin circles, RuPay's fast-forward double
// triangle (see the RuPay note in Panel.qml), or a plain "VISA" word. Renders
// nothing for any other network, so callers can bind it unconditionally.
Item {
  id: root

  property string network: ""
  property real markHeight: Style.spaceReal(11)

  readonly property bool isMastercard: network === "MASTERCARD"
  readonly property bool isRupay: network === "RUPAY"
  readonly property bool isVisa: network === "VISA"

  visible: isMastercard || isRupay || isVisa
  implicitHeight: markHeight
  implicitWidth: isMastercard ? markHeight * 18 / 11
    : (isRupay ? markHeight * 9 / 13 : visaText.implicitWidth)
  width: implicitWidth
  height: implicitHeight

  Item {
    visible: root.isMastercard
    anchors.fill: parent

    Rectangle {
      width: root.markHeight
      height: width
      radius: width / 2
      color: "#EB001B"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Rectangle {
      width: root.markHeight
      height: width
      radius: width / 2
      color: Util.alpha("#F79E1B", 0.85)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Shape {
    visible: root.isRupay
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: "#F47920"
      strokeWidth: 0
      startX: root.width * 0.395; startY: 0
      PathLine { x: 0; y: root.height }
      PathLine { x: root.width * 0.744; y: root.height * 0.492 }
      PathLine { x: root.width * 0.395; y: 0 }
    }
    ShapePath {
      fillColor: "#008C44"
      strokeWidth: 0
      startX: root.width * 0.651; startY: 0
      PathLine { x: root.width * 0.256; y: root.height }
      PathLine { x: root.width; y: root.height * 0.492 }
      PathLine { x: root.width * 0.651; y: 0 }
    }
  }

  Text {
    id: visaText
    visible: root.isVisa
    anchors.verticalCenter: parent.verticalCenter
    text: "VISA"
    color: "#1A1F71"
    font.bold: true
    font.italic: true
    font.pixelSize: root.markHeight
  }
}
