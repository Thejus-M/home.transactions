import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an Axis-style mark: a stylised "A" made
// of two slanted strokes in burgundy and magenta. The left stroke is a full
// leg rising to a flat apex; the right stroke is a shorter leg that starts
// lower, leaving a clear gap. Not the official Axis Bank logo, and not a copy
// of it. Drawn with shapes only (no images, no Text), sized by markSize.
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
    preferredRendererType: Shape.CurveRenderer

    // Left leg: slope 0.36 across the height, horizontal thickness 0.26.
    ShapePath {
      fillColor: root.strokeA
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.0, 1.0], [0.26, 1.0], [0.62, 0.0], [0.36, 0.0]]) }
    }
    // Right leg: mirror of the left leg's slope, starts at y 0.5 so a gap
    // separates it from the left leg at the apex.
    ShapePath {
      fillColor: root.strokeB
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.poly([[0.56, 0.5], [0.82, 0.5], [1.0, 1.0], [0.74, 1.0]]) }
    }
  }
}
