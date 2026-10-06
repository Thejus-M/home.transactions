import QtQuick
import qs.Commons

// Login card: shown while the fetcher waits for a phone scan. The code sits
// on a fixed off-white tile, because it always scans dark-on-light.
Rectangle {
  id: card

  property string imageSource: ""

  // Fixed tile colour: the code must stay dark-on-light in every theme.
  readonly property color tileColor: "#0B1628"

  implicitHeight: content.implicitHeight + Style.spacing.xl * 2
  radius: Style.cornerRadius
  color: Color.popups.background
  border.width: Style.spacing.hairline
  border.color: Color.popups.border

  Column {
    id: content
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: Style.spacing.xl
    width: parent.width - Style.spacing.xl * 2
    spacing: Style.spacing.md

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Scan with HDFC app"
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Rectangle {
      id: tile
      anchors.horizontalCenter: parent.horizontalCenter
      width: qrImage.width + Style.spacing.md * 2
      height: qrImage.height + Style.spacing.md * 2
      radius: Style.cornerRadius
      color: card.tileColor

      Image {
        id: qrImage
        anchors.centerIn: parent
        width: Style.space(200)
        height: Style.space(200)
        fillMode: Image.PreserveAspectFit
        smooth: false
        cache: false
        source: card.imageSource
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Scan with your phone to continue"
      color: Color.popups.text
      opacity: 0.7
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
