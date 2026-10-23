import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of the ICICI mark: a leaning ellipse,
// red at the top-right fading to orange at the bottom-left, with a solid
// white lowercase "i" — a round dot and a tapered stem — drawn on top of
// it. Not the official ICICI Bank logo and not a copy of one: its own
// proportions, drawn with shapes only (no images, no Text), sized by
// markSize, the same contract AxisLogo and SbiLogo use.
//
// Checked against ICICI's own header logo (retailnetbanking.icici.bank.in
// /assets/img/new-login/icici-header-logo.png, sampled for its real
// colours — #BE2A2A red, #EF7F1A orange) rather than guessed. Three wrong
// builds came before this, each checked by rendering an equivalent SVG
// (this sandbox can't run QML): the ellipse with the "i" knocked out of it
// as a transparent hole (the actual bank logo draws the "i" solid on top,
// not cut out), the "i" alone with no background, and the "i" on a white
// circle / on an orange-red rounded square (both backwards or the wrong
// shape — ICICI's mark is an ellipse, not a square, and the "i" is additive
// paint, not a knockout).
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Hard-coded rather than themed: a bank mark that changed hue with the
  // wallpaper would stop being recognisable. Sampled from the real logo.
  readonly property color red: "#BE2A2A"
  readonly property color orange: "#EF7F1A"
  readonly property color mark: "#FFFFFF"

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    // The body: an ellipse leaning 26° right, drawn as two half arcs,
    // filled red-to-orange along its own tilt (top-right to bottom-left).
    ShapePath {
      strokeWidth: 0
      fillGradient: LinearGradient {
        x1: root.s * 0.75; y1: root.s * 0.15
        x2: root.s * 0.25; y2: root.s * 0.85
        GradientStop { position: 0.0; color: root.red }
        GradientStop { position: 1.0; color: root.orange }
      }

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
    }

    // The "i", solid white, painted on top of the ellipse (not knocked
    // out of it) — a separate ShapePath in the same Shape paints after,
    // and so over, the one above.
    ShapePath {
      fillColor: root.mark
      strokeWidth: 0

      // The dot, upright.
      startX: root.s * 0.52; startY: root.s * 0.23
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
