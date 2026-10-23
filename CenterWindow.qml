import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Layer-shell window for the notification center. Three presentations share
// one overlay and one focus target:
//
//   window      floating card at the configured corner
//   horizontal  band spanning left/right margins, anchored top or bottom
//   vertical    band spanning top/bottom margins, anchored left or right
//
// Margins are independent per side. The bar's own thickness is added on the
// side it occupies so the band never slides under it.
PanelWindow {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property QtObject owner: null
  property bool open: false
  property string mode: "window"
  property string placement: "top-right"
  property int marginX: 12
  property int marginY: 12
  property int padding: 12
  property int desiredWidth: 430
  property int desiredHeight: 400
  property Item focusTarget: null

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property var anchorScreen: anchorWindow ? anchorWindow.screen : null
  // IPC is answered by one bar instance only, so the panel must not inherit
  // that instance's screen: open where the user is actually looking.
  readonly property var focusedScreen: {
    var monitor = Hyprland.focusedMonitor
    if (monitor && monitor.name) {
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === monitor.name) return screens[i]
    }
    return anchorScreen
  }

  readonly property real screenW: focusedScreen ? focusedScreen.width : 0
  readonly property real screenH: focusedScreen ? focusedScreen.height : 0
  readonly property string barPos: bar ? bar.position : "top"
  readonly property real barThickness: bar ? Math.max(0, bar.barSize) : 0
  readonly property real gap: Style.gapsOut

  readonly property bool atTop: placement.indexOf("top-") === 0
  readonly property bool atCenterY: placement.indexOf("center-") === 0
  readonly property bool atCenterX: placement.indexOf("-center") !== -1
  readonly property bool atLeft: placement.indexOf("-left") !== -1
  readonly property bool atRight: placement.indexOf("-right") !== -1
  readonly property bool horizontal: mode === "horizontal"
  readonly property bool vertical: mode === "vertical"

  readonly property real leftInset: marginX + (barPos === "left" ? barThickness + gap : 0)
  readonly property real rightInset: marginX + (barPos === "right" ? barThickness + gap : 0)
  readonly property real topInset: marginY + (barPos === "top" ? barThickness + gap : 0)
  readonly property real bottomInset: marginY + (barPos === "bottom" ? barThickness + gap : 0)

  readonly property real availableW: Math.max(1, screenW - leftInset - rightInset)
  readonly property real availableH: Math.max(1, screenH - topInset - bottomInset)
  readonly property var cardBorderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  readonly property real borderW: Border.left(cardBorderSpec) + Border.right(cardBorderSpec)
  readonly property real borderH: Border.top(cardBorderSpec) + Border.bottom(cardBorderSpec)

  // Border thickness counts toward the outer size; omitting it clipped the
  // bottom border and the last text line.
  readonly property real cardW: {
    // Horizontal bands always span the free width between the X margins.
    if (horizontal) return Math.round(availableW)
    return Math.round(Math.min(desiredWidth + padding * 2 + borderW, availableW))
  }
  readonly property real cardH: {
    if (vertical) return Math.round(availableH)
    return Math.round(Math.min(desiredHeight + padding * 2 + borderH, availableH))
  }

  readonly property real cardX: {
    if (horizontal) return Math.round(leftInset)
    if (vertical) {
      if (atLeft) return Math.round(leftInset)
      if (atCenterX) return Math.round(Math.max(leftInset, (screenW - cardW) / 2))
      return Math.round(Math.max(leftInset, screenW - rightInset - cardW))
    }
    if (atLeft) return Math.round(leftInset)
    if (atRight) return Math.round(Math.max(leftInset, screenW - rightInset - cardW))
    return Math.round(Math.max(leftInset, (screenW - cardW) / 2))
  }
  readonly property real cardY: {
    if (vertical) return Math.round(topInset)
    if (atTop) return Math.round(topInset)
    if (atCenterY) return Math.round(Math.max(topInset, (screenH - cardH) / 2))
    return Math.round(Math.max(topInset, screenH - bottomInset - cardH))
  }

  screen: focusedScreen
  visible: open
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  WlrLayershell.namespace: "omarchy-notification-center"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  onOpenChanged: {
    if (!open) return
    Qt.callLater(function() {
      if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
    })
  }

  // Click anywhere outside the card closes the center.
  MouseArea {
    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    onClicked: root.close()
  }

  BorderSurface {
    id: card
    x: root.cardX
    y: root.cardY
    width: root.cardW
    height: root.cardH
    color: Commons.Color.popups.background
    borderSpec: root.cardBorderSpec
    padding: root.padding
    radius: Style.cornerRadius

    // Swallow clicks on the card so they don't reach the dismiss area.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
    }
  }

  default property alias contentItem: contentHolder.children
}
