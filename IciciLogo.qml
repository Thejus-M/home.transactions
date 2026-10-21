import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of the ICICI mark: an upright
// elliptical form whose lower end narrows to a point and curls inward,
// reading as a handwritten lowercase "i" without its dot, shaded darker
// to brighter orange with the curl's inner edge in maroon. Not the
// official ICICI Bank logo and not a copy of one — its own proportions,
// drawn with shapes only (no images, no Text), sized by markSize, the
// same contract AxisLogo and SbiLogo use.
//
// The palette is third-party and the sources disagree (color.codes.in
// gives this orange/maroon pair; WhatTheLogo and logotyp.us list other
// sets), so treat the hexes as approximate too.
Item {
  id: root

  property real markSize: Style.spaceReal(12)
  readonly property real s: Math.round(markSize)

  // Logo colours, hard-coded rather than themed: a bank mark that changed
  // hue with the wallpaper would stop being recognisable.
  readonly property color orangeDeep: "#D8621C"
  readonly property color orangeBright: "#F58220"
  readonly property color maroon: "#6E1E24"

  implicitWidth: s
  implicitHeight: s
  width: implicitWidth
  height: implicitHeight

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    layer.enabled: true
    layer.samples: 4

    // The body: up the left side, over the top, down the right shoulder
    // and into the point at the bottom left. Coordinates are fractions of
    // the mark's side, so the whole thing scales with markSize.
    ShapePath {
      strokeWidth: 0
      fillGradient: LinearGradient {
        x1: 0; y1: 0
        x2: 0; y2: root.s
        GradientStop { position: 0.0; color: root.orangeDeep }
        GradientStop { position: 1.0; color: root.orangeBright }
      }

      startX: root.s * 0.46; startY: root.s * 0.03
      PathCubic {
        x: root.s * 0.74; y: root.s * 0.44
        control1X: root.s * 0.70; control1Y: root.s * 0.03
        control2X: root.s * 0.78; control2Y: root.s * 0.22
      }
      PathCubic {
        x: root.s * 0.30; y: root.s * 0.97
        control1X: root.s * 0.70; control1Y: root.s * 0.68
        control2X: root.s * 0.56; control2Y: root.s * 0.86
      }
      PathCubic {
        x: root.s * 0.48; y: root.s * 0.44
        control1X: root.s * 0.44; control1Y: root.s * 0.80
        control2X: root.s * 0.50; control2Y: root.s * 0.60
      }
      PathCubic {
        x: root.s * 0.46; y: root.s * 0.03
        control1X: root.s * 0.46; control1Y: root.s * 0.26
        control2X: root.s * 0.34; control2Y: root.s * 0.18
      }
    }

    // The curl's inner edge, which is what stops the form reading as a
    // plain teardrop. Kept wide enough to survive at a 20px mark.
    ShapePath {
      strokeWidth: 0
      fillColor: root.maroon

      startX: root.s * 0.30; startY: root.s * 0.97
      PathCubic {
        x: root.s * 0.25; y: root.s * 0.56
        control1X: root.s * 0.16; control1Y: root.s * 0.88
        control2X: root.s * 0.14; control2Y: root.s * 0.70
      }
      PathCubic {
        x: root.s * 0.30; y: root.s * 0.97
        control1X: root.s * 0.28; control1Y: root.s * 0.74
        control2X: root.s * 0.29; control2Y: root.s * 0.88
      }
    }
  }
}
