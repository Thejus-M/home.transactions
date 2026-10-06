import QtQuick
import QtQuick.Shapes
import qs.Commons

// Personal, unofficial approximation of an HDFC-style emblem and wordmark. Not
// an official HDFC Bank logo, and not a copy of one: it uses its own colours
// and its own letterforms. Everything is drawn with shapes (QML ShapePath paths
// and Rectangles); no Text element is used for the wordmark.
//
// variant "icon": the square mark only (four red corner brackets around a
// blue centre square). variant "full": the mark with a navy bar underneath
// carrying the pale letters H D F C, space, B A N K. The bar is wider than the
// mark, as in the reference.
//
// Geometry was checked against the reference emblem (900x600 PNG, mark about
// 368 px square): red box, blue square and navy bar match within about 1%.
// Letter paths are in mark units (1 = markSize), so the whole wordmark scales
// with the mark. The "full" variant is intended for larger sizes; at small
// sizes the letters are only a few pixels tall.
Item {
  id: root

  property string variant: "icon"
  property real markSize: Style.spaceReal(12)

  readonly property bool full: variant === "full"

  // Logo colours, hard-coded (not tinted by the theme). Sampled from the reference.
  readonly property color bracketColour: "#FE0000"
  readonly property color squareColour: "#003397"
  readonly property color barColour: "#001F79"
  readonly property color letterColour: "#D6E6F7"

  // Geometry as fractions of the mark side s (mark is 1 x 1 in these units).
  readonly property real armFrac: 0.454
  readonly property real thickFrac: 0.155
  readonly property real squareFrac: 0.364
  readonly property real barWidthFrac: 1.125
  readonly property real barTopFrac: 1.030
  readonly property real barHeightFrac: 0.2283

  // Whole-pixel side so the blue square and bar edges stay crisp.
  readonly property real s: Math.round(markSize)

  // Full variant: the bar is wider than the mark, so the mark is centred in it.
  readonly property real ox: full ? (implicitWidth - s) / 2 : 0

  // Letters, as one path in mark units (height of the letters about 0.106).
  readonly property string wordPath:
    "M0.008 1.092 L0.043 1.092 L0.043 1.127 L0.076 1.127 L0.076 1.092 L0.111 1.092 L0.111 1.198 L0.076 1.198 L0.076 1.158 L0.043 1.158 L0.043 1.198 L0.008 1.198 Z" +
    "M0.133 1.092 L0.175 1.092 L0.175 1.092 L0.185 1.093 L0.193 1.095 L0.202 1.098 L0.21 1.103 L0.217 1.108 L0.223 1.114 L0.227 1.121 L0.231 1.129 L0.233 1.137 L0.234 1.145 L0.233 1.154 L0.231 1.162 L0.227 1.169 L0.223 1.177 L0.217 1.183 L0.21 1.188 L0.202 1.193 L0.193 1.196 L0.185 1.198 L0.175 1.198 L0.133 1.198 ZM0.168 1.117 L0.175 1.117 L0.175 1.117 L0.179 1.117 L0.183 1.118 L0.186 1.12 L0.189 1.122 L0.192 1.125 L0.194 1.129 L0.196 1.132 L0.198 1.137 L0.198 1.141 L0.199 1.145 L0.198 1.15 L0.198 1.154 L0.196 1.158 L0.194 1.162 L0.192 1.166 L0.189 1.169 L0.186 1.171 L0.183 1.173 L0.179 1.174 L0.175 1.174 L0.168 1.174 Z" +
    "M0.25 1.092 L0.334 1.092 L0.334 1.117 L0.285 1.117 L0.285 1.136 L0.323 1.136 L0.323 1.158 L0.285 1.158 L0.285 1.198 L0.25 1.198 Z" +
    "M0.454 1.092 L0.401 1.092 L0.393 1.093 L0.384 1.095 L0.377 1.098 L0.37 1.103 L0.363 1.108 L0.358 1.114 L0.354 1.121 L0.35 1.129 L0.348 1.137 L0.348 1.145 L0.348 1.154 L0.35 1.162 L0.354 1.169 L0.358 1.177 L0.363 1.183 L0.37 1.188 L0.377 1.193 L0.384 1.196 L0.393 1.198 L0.401 1.198 L0.454 1.198 L0.454 1.169 L0.401 1.169 L0.398 1.168 L0.395 1.168 L0.393 1.166 L0.39 1.164 L0.388 1.162 L0.386 1.159 L0.385 1.156 L0.384 1.153 L0.383 1.149 L0.383 1.145 L0.383 1.142 L0.384 1.138 L0.385 1.135 L0.386 1.132 L0.388 1.129 L0.39 1.127 L0.393 1.125 L0.395 1.123 L0.398 1.122 L0.401 1.122 L0.454 1.122 Z" +
    "M0.519 1.092 L0.588 1.092 L0.588 1.092 L0.593 1.093 L0.597 1.094 L0.601 1.095 L0.605 1.097 L0.608 1.1 L0.611 1.103 L0.614 1.107 L0.615 1.111 L0.616 1.115 L0.617 1.119 L0.616 1.123 L0.615 1.127 L0.614 1.131 L0.611 1.134 L0.608 1.138 L0.605 1.14 L0.601 1.142 L0.597 1.144 L0.593 1.145 L0.588 1.145 L0.593 1.146 L0.597 1.147 L0.601 1.148 L0.605 1.15 L0.608 1.153 L0.611 1.156 L0.614 1.16 L0.615 1.164 L0.616 1.168 L0.617 1.172 L0.616 1.176 L0.615 1.18 L0.614 1.184 L0.611 1.187 L0.608 1.191 L0.605 1.193 L0.601 1.195 L0.597 1.197 L0.593 1.198 L0.588 1.198 L0.519 1.198 ZM0.554 1.114 L0.583 1.114 L0.583 1.134 L0.554 1.134 ZM0.554 1.152 L0.583 1.152 L0.583 1.175 L0.554 1.175 Z" +
    "M0.628 1.198 L0.666 1.092 L0.701 1.092 L0.739 1.198 L0.707 1.198 L0.7 1.171 L0.667 1.171 L0.66 1.198 ZM0.683 1.124 L0.705 1.156 L0.662 1.156 Z" +
    "M0.755 1.092 L0.803 1.092 L0.824 1.156 L0.824 1.092 L0.859 1.092 L0.859 1.198 L0.811 1.198 L0.79 1.135 L0.79 1.198 L0.755 1.198 Z" +
    "M0.88 1.092 L0.915 1.092 L0.915 1.137 L0.939 1.092 L0.992 1.092 L0.955 1.145 L0.992 1.198 L0.939 1.198 L0.915 1.154 L0.915 1.198 L0.88 1.198 Z"

  implicitWidth: full ? Math.round(s * barWidthFrac) : s
  implicitHeight: full ? Math.round(s * (barTopFrac + barHeightFrac)) : s
  width: implicitWidth
  height: implicitHeight

  // One corner bracket in mark units. index: 0 TL, 1 TR, 2 BR, 3 BL.
  function bracketPath(index) {
    var right = index === 1 || index === 2
    var bottom = index === 2 || index === 3
    var a = root.armFrac
    var t = root.thickFrac
    var pts = [[0, 0], [a, 0], [a, t], [t, t], [t, a], [0, a]]
    var out = ""
    for (var i = 0; i < pts.length; i++) {
      var u = right ? 1 - pts[i][0] : pts[i][0]
      var v = bottom ? 1 - pts[i][1] : pts[i][1]
      out += (i === 0 ? "M " : " L ") + u + " " + v
    }
    return out + " Z"
  }

  // Navy bar under the mark, full variant only.
  Rectangle {
    visible: root.full
    x: 0
    y: root.s * root.barTopFrac
    width: root.width
    height: root.s * root.barHeightFrac
    color: root.barColour
  }

  // Four red corner brackets, drawn in mark units and scaled by s.
  Shape {
    x: root.ox
    y: 0
    width: 1
    height: 1
    transformOrigin: Item.TopLeft
    transform: Scale { xScale: root.s; yScale: root.s }
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.bracketColour
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      PathSvg { path: root.bracketPath(0) }
    }
    ShapePath {
      fillColor: root.bracketColour
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      PathSvg { path: root.bracketPath(1) }
    }
    ShapePath {
      fillColor: root.bracketColour
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      PathSvg { path: root.bracketPath(2) }
    }
    ShapePath {
      fillColor: root.bracketColour
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      PathSvg { path: root.bracketPath(3) }
    }
  }

  // Blue centre square, centred on the mark.
  Rectangle {
    x: root.ox + root.s * (1 - root.squareFrac) / 2
    y: root.s * (1 - root.squareFrac) / 2
    width: root.s * root.squareFrac
    height: root.s * root.squareFrac
    color: root.squareColour
  }

  // Pale wordmark letters, full variant only.
  Shape {
    visible: root.full
    x: root.ox
    y: 0
    width: 1
    height: 1
    transformOrigin: Item.TopLeft
    transform: Scale { xScale: root.s; yScale: root.s }
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.letterColour
      strokeColor: "transparent"
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      PathSvg { path: root.wordPath }
    }
  }
}
