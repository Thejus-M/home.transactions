import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an Axis-style mark: two angled strokes
// in burgundy and magenta. Not the official Axis Bank logo, and not a copy of
// it. Drawn with shapes only, sized by markSize.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Logo colours, hard-coded (not tinted by the theme).
  readonly property color strokeA: "#97144D"
  readonly property color strokeB: "#C12A7B"

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

    ShapePath {
      fillColor: root.strokeA
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.42, 0.0], [0.58, 0.0], [1.0, 1.0], [0.8, 1.0]]) }
    }
    ShapePath {
      fillColor: root.strokeB
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.0, 1.0], [0.2, 1.0], [0.5, 0.45], [0.36, 0.2]]) }
    }
  }
}
