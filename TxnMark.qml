import QtQuick
import QtQuick.Shapes

// The mark on a transaction row for "this payment has a bill", "has a note"
// or "has both". Vector, drawn on a 24x24 grid; the path data is the same as
// icons/bill.svg, icons/note.svg and icons/both.svg (keep them in step).
//
// kind: "bill" | "note" | "both" | "refund" (icons/refund.svg)
// billColor / noteColor: the two parts of "both" keep their own colour.
Item {
  id: root
  property string kind: "bill"
  property real markSize: 20
  property color billColor: "#3fb950"
  property color noteColor: "#58a6ff"
  property color refundColor: "#a371f7"

  readonly property bool showBill: kind === "bill" || kind === "both"
  readonly property bool showNote: kind === "note" || kind === "both"

  implicitWidth: markSize
  implicitHeight: markSize
  width: markSize
  height: markSize

  Shape {
    width: 24
    height: 24
    scale: root.markSize / 24
    transformOrigin: Item.TopLeft
    layer.enabled: true
    layer.samples: 4
    preferredRendererType: Shape.GeometryRenderer

    // ---- bill alone: the whole receipt
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "bill" ? root.billColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M6 2.5h12v18.2l-2-1.4-2 1.4-2-1.4-2 1.4-2-1.4-2 1.4z" }
    }
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "bill" ? root.billColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathSvg { path: "M9 7.5h6M9 11h6M9 14.5h3.5" }
    }

    // ---- note alone: the whole sticky note
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "note" ? root.noteColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M4.5 3.5h15v10.5l-5.5 5.5h-9.5z M19.5 14h-5.5v5.5" }
    }
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "note" ? root.noteColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathSvg { path: "M8 8h8M8 11.5h5" }
    }

    // ---- refund: a return arrow curling round, a short bar inside
    ShapePath {
      strokeColor: root.kind === "refund" ? root.refundColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M4.5 12a7.5 7.5 0 1 0 2.2-5.3 M4.5 3.8v3.7H8.2 M9 12h6" }
    }

    // ---- both: receipt behind (upper left), note in front (lower right)
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "both" ? root.billColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M12 9V2H2v14.6l1.7 1.2 1.7-1.2 1.7 1.2 1.7-1.2 M5 6h4M5 9.5h2.5" }
    }
    ShapePath {
      // ShapePath has no `visible`: a hidden part is simply a transparent stroke.
      strokeColor: root.kind === "both" ? root.noteColor : "transparent"
      strokeWidth: 1.6
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: "M9 9h13v8.5L17.5 22H9z M22 17.5h-4.5V22 M12 13.5h7M12 17h3" }
    }
  }
}
