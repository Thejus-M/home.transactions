import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an ICICI-style mark: an orange
// rounded tile carrying a white lowercase "i", with a maroon arc sweeping
// up from the lower-left. Not the official ICICI Bank logo and not a copy
// of one — its own proportions, drawn with shapes only (no images, no
// Text), sized by markSize, the same contract AxisLogo and SbiLogo use.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Logo colours, hard-coded rather than themed: a bank mark that changed
  // hue with the wallpaper would stop being recognisable.
  readonly property color tile: "#F37A21"
  readonly property color sweep: "#AE275F"

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: root.s * 0.22
    color: root.tile
  }

  // The arc: a maroon band rising from the lower left to the right edge,
  // clipped by the tile's own rounding.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: root.sweep
      strokeWidth: 0
      // Bottom-left corner, curving up to the right edge and back down,
      // so the band keeps an even width along its length.
      startX: 0
      startY: root.s
      PathCubic {
        x: root.s
        y: root.s * 0.42
        control1X: root.s * 0.34
        control1Y: root.s * 0.98
        control2X: root.s * 0.66
        control2Y: root.s * 0.66
      }
      PathLine { x: root.s; y: root.s * 0.72 }
      PathCubic {
        x: root.s * 0.30
        y: root.s
        control1X: root.s * 0.72
        control1Y: root.s * 0.92
        control2X: root.s * 0.52
        control2Y: root.s
      }
      PathLine { x: 0; y: root.s }
    }
  }

  // The "i": a dot over a stem, both white, left of centre so the arc has
  // room on the right.
  Rectangle {
    width: root.s * 0.14
    height: width
    radius: width / 2
    color: "white"
    x: root.s * 0.26
    y: root.s * 0.18
  }

  Rectangle {
    width: root.s * 0.14
    height: root.s * 0.34
    radius: width * 0.4
    color: "white"
    x: root.s * 0.26
    y: root.s * 0.40
  }
}
