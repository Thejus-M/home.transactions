import QtQuick
import QtQuick.Shapes
import qs.Commons

// A value line, small enough to sit beside a figure rather than take a
// section of its own.
//
// Drawn with QtQuick.Shapes, not Canvas: nothing in this plugin set uses
// Canvas, every vector mark here is a ShapePath already, and Shapes are
// rendered on the GPU instead of repainting a texture whenever the
// snapshot changes.
//
// `points` is what Portfolio.sparkline() returns: x and y both 0..1 with
// y already flipped, so this file does no arithmetic beyond scaling.
// Below two points it draws nothing at all — one snapshot is not a
// history, and a flat line would imply one that is not there.
Item {
  id: root

  property var points: []
  property color lineColor: Color.accent
  property real lineWidth: Style.spaceReal(1.5)
  // A faint wash under the line. Off by default: at chip size it reads
  // as noise, and it earns its place only on the wider header line.
  property bool filled: false

  readonly property bool hasLine: !!points && points.length > 1

  function _path(close) {
    if (!root.hasLine) return ""
    var out = ""
    for (var i = 0; i < root.points.length; i++) {
      out += (i === 0 ? "M " : " L ")
        + (root.points[i].x * root.width).toFixed(2) + " "
        + (root.points[i].y * root.height).toFixed(2)
    }
    if (close) {
      out += " L " + root.width.toFixed(2) + " " + root.height.toFixed(2)
        + " L 0 " + root.height.toFixed(2) + " Z"
    }
    return out
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    visible: root.hasLine
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.filled ? Util.alpha(root.lineColor, 0.16) : "transparent"
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: root.filled ? root._path(true) : "" }
    }

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.lineColor
      strokeWidth: root.lineWidth
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: root._path(false) }
    }
  }
}
