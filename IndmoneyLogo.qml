import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an INDmoney-style mark: a solid
// upright bar beside a rising chevron, in two blues — "money, going up",
// which is what the widget uses the chip for. Not the official INDmoney
// logo, and not a copy of it. Drawn with shapes only (no images, no
// Text), sized by markSize, like the four bank marks beside it.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Logo colours, hard-coded (not tinted by the theme).
  readonly property color barColor: "#2B5CE6"
  readonly property color arrowColor: "#4FA3F7"

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  // Polygon through unit-square points, scaled to the mark size.
  function poly(pts) {
    var out = ""
    for (var i = 0; i < pts.length; i++) {
      out += (i === 0 ? "M " : " L ") + pts[i][0] * root.s + " " + pts[i][1] * root.s
    }
    return out + " Z"
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    // The upright: a full-height bar on the left, thickness 0.22.
    ShapePath {
      fillColor: root.barColor
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.0, 0.08], [0.22, 0.08], [0.22, 1.0], [0.0, 1.0]]) }
    }
    // The rise: a stroke climbing left to right, thickness 0.2 measured
    // vertically, starting clear of the bar so the two never touch.
    ShapePath {
      fillColor: root.arrowColor
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.34, 1.0], [0.34, 0.80], [1.0, 0.20], [1.0, 0.40]]) }
    }
    // The head: a small triangle closing the rise at the top right.
    ShapePath {
      fillColor: root.arrowColor
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.62, 0.08], [1.0, 0.08], [1.0, 0.46]]) }
    }
  }
}
