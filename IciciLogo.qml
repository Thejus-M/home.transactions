import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of the ICICI mark: a solid ellipse
// leaning right with a lowercase "i" knocked out of it — a dot and a
// tapered stem that sweeps down to the left. Not the official ICICI Bank
// logo and not a copy of one: its own proportions, drawn with shapes only
// (no images, no Text), sized by markSize, the same contract AxisLogo and
// SbiLogo use.
//
// Two things worth keeping if this is ever adjusted. The lean rides on
// the arc's own xAxisRotation rather than on a transform around the whole
// item, because rotating the group tilts the "i" with the body and the
// letter has to stay upright. And the counters are knocked out of one
// path with OddEvenFill rather than painted over the top, so the mark
// works on the popup, on a hover fill and on the bar alike.
//
// The colour is the one the single-colour glyph ships in; third-party
// sources disagree on ICICI's palette, so treat it as approximate.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Hard-coded rather than themed: a bank mark that changed hue with the
  // wallpaper would stop being recognisable.
  readonly property color brand: "#AE282E"

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: root.brand
      fillRule: ShapePath.OddEvenFill
      strokeWidth: 0

      // The body: an ellipse leaning 26° right, drawn as two half arcs.
      startX: root.s * 0.1585; startY: root.s * 0.3334
      PathArc {
        x: root.s * 0.8415; y: root.s * 0.6666
        radiusX: root.s * 0.38; radiusY: root.s * 0.50
        xAxisRotation: 26
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }
      PathArc {
        x: root.s * 0.1585; y: root.s * 0.3334
        radiusX: root.s * 0.38; radiusY: root.s * 0.50
        xAxisRotation: 26
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }

      // The dot, upright.
      PathMove { x: root.s * 0.52; y: root.s * 0.23 }
      PathArc {
        x: root.s * 0.72; y: root.s * 0.23
        radiusX: root.s * 0.10; radiusY: root.s * 0.092
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }
      PathArc {
        x: root.s * 0.52; y: root.s * 0.23
        radiusX: root.s * 0.10; radiusY: root.s * 0.092
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }

      // The stem: down the right flank, round the foot, back up the left,
      // capped under the dot. Wider at the top than at the foot, which is
      // what stops it reading as a bar.
      PathMove { x: root.s * 0.68; y: root.s * 0.41 }
      PathCubic {
        x: root.s * 0.445; y: root.s * 0.82
        control1X: root.s * 0.68; control1Y: root.s * 0.5945
        control2X: root.s * 0.445; control2Y: root.s * 0.6765
      }
      PathCubic {
        x: root.s * 0.335; y: root.s * 0.82
        control1X: root.s * 0.4175; control1Y: root.s * 0.8805
        control2X: root.s * 0.3625; control2Y: root.s * 0.8805
      }
      PathCubic {
        x: root.s * 0.48; y: root.s * 0.41
        control1X: root.s * 0.335; control1Y: root.s * 0.6765
        control2X: root.s * 0.48; control2Y: root.s * 0.5945
      }
      PathCubic {
        x: root.s * 0.68; y: root.s * 0.41
        control1X: root.s * 0.53; control1Y: root.s * 0.30
        control2X: root.s * 0.63; control2Y: root.s * 0.30
      }
    }
  }
}
