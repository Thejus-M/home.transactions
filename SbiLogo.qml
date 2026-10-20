import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an SBI-style mark: a solid blue disc
// with a keyhole cut out of it, a small round hole at the centre and a narrow
// slot running from the hole down through the bottom edge. Not the official
// State Bank of India logo, and not a copy of it. Drawn with shapes only (no
// images, no Text), sized by markSize.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Logo colour, hard-coded (not tinted by the theme).
  readonly property color discColour: "#22409A"

  // Geometry as fractions of the mark side (the disc is 1 x 1 in these units).
  readonly property real holeRadius: 0.14
  readonly property real slotHalfWidth: 0.055

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  // One closed outline, so no fill rule is needed: the outer circle the long
  // way round from the slot's bottom-right corner to its bottom-left corner,
  // up the slot's left edge, round the hole over the top, down the right edge.
  readonly property string outline: {
    var c = 0.5, R = 0.5, r = holeRadius, w = slotHalfWidth
    var yOuter = c + Math.sqrt(R * R - w * w)
    var yHole = c + Math.sqrt(r * r - w * w)
    function p(x, y) { return (x * s) + " " + (y * s) }
    return "M " + p(c + w, yOuter)
      + " A " + (R * s) + " " + (R * s) + " 0 1 0 " + p(c - w, yOuter)
      + " L " + p(c - w, yHole)
      + " A " + (r * s) + " " + (r * s) + " 0 1 1 " + p(c + w, yHole)
      + " Z"
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.discColour
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.outline }
    }
  }
}
