import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// One bank's reload control: the bank's logo is the reload button. Clicking
// it starts the fetch and the logo spins while the fetch runs; Cancel appears
// beside it during the run. Each bank has its own control, so the two stay
// apart.
Item {
  id: root

  // "hdfc", "axis" or "sbi": which logo the button shows.
  property string bank: "hdfc"
  property bool running: false
  // False while the other bank's fetch runs (only one fetch at a time).
  property bool allowed: true
  property string idleTooltip: ""
  property color foreground: Color.foreground
  signal fetch()
  signal cancel()

  readonly property real logoSize: Style.space(16)

  // Same bounded focus-chain walk as Panel.qml's root.focusNext — this file
  // can't reach that one, so it keeps its own copy for Up/Down. Scrolling
  // the popup's Flickable into view is Panel.qml's job too (it owns
  // column/flick, which this file can't see), so the caller wires its own
  // root.scrollIntoView in here — without it, Up/Down from the bank
  // logo/cancel box moved focus but never scrolled the row into view.
  property var scrollIntoView: null
  function focusNext(item, forward) {
    var next = item
    for (var i = 0; i < 64 && next; i++) {
      next = next.nextItemInFocusChain(forward)
      if (!next || next === item) return
      if (next.activeFocusOnTab) {
        next.forceActiveFocus()
        if (root.scrollIntoView) root.scrollIntoView(next)
        return
      }
    }
  }
  readonly property real gap: Style.spacing.xs

  implicitWidth: logoSize + (running ? gap + cancelBox.width : 0)
  implicitHeight: Style.space(28)
  width: implicitWidth
  height: implicitHeight

  // Stop the logo level when the run ends, wherever the spin had reached.
  onRunningChanged: if (!running) logoButton.rotation = 0

  Rectangle {
    id: cancelBox
    visible: root.running
    anchors.right: logoButton.left
    anchors.rightMargin: root.gap
    anchors.verticalCenter: parent.verticalCenter
    width: cancelLabel.implicitWidth + Style.space(20)
    height: Style.space(26)
    radius: Style.cornerRadius
    color: (cancelHover.hovered || cancelBox.activeFocus) ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.25) : "transparent"
    border.width: 1
    border.color: Color.urgent

    Behavior on color { ColorAnimation { duration: 100 } }

    // Only a tab stop while it's actually showing — matches the chevron
    // hidden-row idiom used elsewhere (e.g. editBtn's visible-gated reach).
    activeFocusOnTab: root.running
    Keys.onReturnPressed: root.cancel()
    Keys.onEnterPressed: root.cancel()
    Keys.onSpacePressed: root.cancel()
    Keys.onDownPressed: root.focusNext(cancelBox, true)
    Keys.onUpPressed: root.focusNext(cancelBox, false)

    HoverHandler {
      id: cancelHover
    }

    Text {
      id: cancelLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "Cancel"
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { cancelBox.forceActiveFocus(); root.cancel() }
    }
  }

  BorderSurface {
    id: logoButton
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.logoSize
    height: width
    radius: width / 2
    opacity: root.allowed || root.running ? 1.0 : 0.35
    scale: logoMouse.pressed ? 0.8 : 1.0
    // Disabled (other bank fetching, or this one already running) stays
    // visually dead on hover too — logoHover itself stays enabled so the
    // idle tooltip still works, but a button that does nothing on click
    // shouldn't look clickable just because the pointer is over it.
    readonly property bool hoverActive: logoHover.hovered && root.allowed && !root.running
    color: logoButton.activeFocus
      ? Style.controlFill(true, false, root.foreground, Color.accent)
      : (logoButton.hoverActive ? Style.controlFill(false, true, root.foreground, Color.accent) : "transparent")
    // Hover-only previously got the fill with no border at all while focus
    // got fill + a focus ring — the two states looked unrelated. Give
    // hover the same graduated hover-cursor border every other control in
    // this widget uses (FilterMenuButton, TextAction, …).
    borderSpec: logoButton.activeFocus
      ? Border.controlSpec("focus", root.foreground, Color.accent)
      : (logoButton.hoverActive ? Border.controlSpec("hover-cursor", root.foreground, Color.accent) : Border.none())
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 120 } }
    Behavior on color { ColorAnimation { duration: 100 } }

    // Skipped from Tab while disallowed (the other bank's fetch is
    // running) or already running — matches logoMouse's own `enabled`.
    activeFocusOnTab: root.allowed && !root.running
    Keys.onReturnPressed: if (root.allowed && !root.running) root.fetch()
    Keys.onEnterPressed: if (root.allowed && !root.running) root.fetch()
    Keys.onSpacePressed: if (root.allowed && !root.running) root.fetch()
    Keys.onDownPressed: root.focusNext(logoButton, true)
    Keys.onUpPressed: root.focusNext(logoButton, false)

    // One full turn on click; keeps turning while the fetch runs.
    NumberAnimation on rotation {
      id: spin
      running: root.running
      from: 0
      to: 360
      duration: 900
      loops: Animation.Infinite
    }

    HdfcLogo {
      visible: root.bank === "hdfc"
      anchors.centerIn: parent
      variant: "icon"
      markSize: root.logoSize
    }

    AxisLogo {
      visible: root.bank === "axis"
      anchors.centerIn: parent
      markSize: root.logoSize
    }

    SbiLogo {
      visible: root.bank === "sbi"
      anchors.centerIn: parent
      markSize: root.logoSize
    }

    HoverHandler {
      id: logoHover
    }

    ToolTip.visible: logoHover.hovered && root.idleTooltip !== "" && !root.running
    ToolTip.text: root.idleTooltip
    ToolTip.delay: 400

    MouseArea {
      id: logoMouse
      anchors.fill: parent
      enabled: root.allowed && !root.running
      cursorShape: Qt.PointingHandCursor
      onClicked: { logoButton.forceActiveFocus(); root.fetch() }
    }
  }
}
