import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of the ICICI mark: a solid lowercase
// "i" — a round dot and a tapered stem that sweeps down to the left — on a
// white circular badge, the way ICICI shows it (red mark, white roundel),
// not blended into whatever surface it sits on. Not the official ICICI
// Bank logo and not a copy of one: its own proportions, drawn with shapes
// only (no images, no Text), sized by markSize, the same contract AxisLogo
// and SbiLogo use.
//
// Was previously drawn as a solid ellipse with the "i" knocked out of it
// (OddEvenFill) — rendered and checked (this sandbox can't run QML, so via
// an equivalent SVG), it came out as a large red oval with a dark
// silhouette hole, not a red "i". The ellipse is gone; dot and stem are
// filled directly, now over a white circle rather than transparent.
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
  readonly property color badge: "#FFFFFF"

  // The "i" is drawn in a 0..1 unit square, same as always, but mapped
  // into the middle (1 - 2*pad) of the badge rather than filling it edge
  // to edge, so it doesn't touch the circle's rim.
  readonly property real pad: 0.16
  function f(v) { return root.s * (root.pad + v * (1 - 2 * root.pad)) }

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: root.badge
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: root.brand
      strokeWidth: 0

      // The dot, upright.
      startX: root.f(0.52); startY: root.f(0.23)
      PathArc {
        x: root.f(0.72); y: root.f(0.23)
        radiusX: root.f(0.10) - root.f(0); radiusY: root.f(0.092) - root.f(0)
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }
      PathArc {
        x: root.f(0.52); y: root.f(0.23)
        radiusX: root.f(0.10) - root.f(0); radiusY: root.f(0.092) - root.f(0)
        useLargeArc: true
        direction: PathArc.Counterclockwise
      }

      // The stem: down the right flank, round the foot, back up the left,
      // capped under the dot. Wider at the top than at the foot, which is
      // what stops it reading as a bar.
      PathMove { x: root.f(0.68); y: root.f(0.41) }
      PathCubic {
        x: root.f(0.445); y: root.f(0.82)
        control1X: root.f(0.68); control1Y: root.f(0.5945)
        control2X: root.f(0.445); control2Y: root.f(0.6765)
      }
      PathCubic {
        x: root.f(0.335); y: root.f(0.82)
        control1X: root.f(0.4175); control1Y: root.f(0.8805)
        control2X: root.f(0.3625); control2Y: root.f(0.8805)
      }
      PathCubic {
        x: root.f(0.48); y: root.f(0.41)
        control1X: root.f(0.335); control1Y: root.f(0.6765)
        control2X: root.f(0.48); control2Y: root.f(0.5945)
      }
      PathCubic {
        x: root.f(0.68); y: root.f(0.41)
        control1X: root.f(0.53); control1Y: root.f(0.30)
        control2X: root.f(0.63); control2Y: root.f(0.30)
      }
    }
  }
}
