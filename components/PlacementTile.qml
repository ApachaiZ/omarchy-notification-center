import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A miniature screen showing where the center card will sit. The selected
// tile is filled with the accent; the others stay quiet until hovered.
BorderSurface {
  id: root

  property string vertical: "top"
  property string horizontal: "right"
  property bool selected: false
  property bool enabled: true
  property bool hasCursor: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  signal hovered(bool isHovered)
  signal clicked()

  readonly property bool hot: root.enabled && (root.hasCursor || tileHover.hovered)
  readonly property color dim: Qt.darker(root.foreground, 1.65)

  implicitWidth: Style.space(64)
  implicitHeight: Style.space(44)
  opacity: root.enabled ? 1 : 0.35
  radius: Math.max(Style.space(4), Math.round(Style.cornerRadius * 0.7))
  color: root.selected
    ? Style.selectedFillFor(root.foreground, root.accent)
    : (root.hot ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
  borderSpec: root.selected
    ? Border.flat(root.accent, Math.max(1, Style.space(2)))
    : (root.hot ? Border.controlSpec("hover-cursor", root.foreground, root.accent)
      : Border.controlSpec("normal", root.foreground, root.accent))

  Behavior on color { ColorAnimation { duration: 100 } }

  HoverHandler {
    id: tileHover
    onHoveredChanged: if (root.enabled) root.hovered(tileHover.hovered)
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }

  Rectangle {
    id: screen
    anchors.fill: parent
    anchors.margins: Style.space(7)
    radius: Math.max(1, Style.space(3))
    color: "transparent"
    border.width: 1
    border.color: root.selected ? root.accent : root.dim
    opacity: root.enabled ? (root.selected ? 0.9 : 0.55) : 0.5
  }

  Rectangle {
    width: Math.max(Style.space(13), screen.width * 0.42)
    height: Math.max(Style.space(7), screen.height * 0.3)
    radius: Math.max(1, Style.space(2))
    color: root.selected ? root.accent : root.foreground

    x: root.horizontal === "left"
      ? screen.x + Style.space(3)
      : (root.horizontal === "center"
        ? screen.x + (screen.width - width) / 2
        : screen.x + screen.width - width - Style.space(3))
    y: root.vertical === "top"
      ? screen.y + Style.space(3)
      : screen.y + screen.height - height - Style.space(3)

    Behavior on x { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
    Behavior on y { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
  }
}
