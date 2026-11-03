import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One of the three presentation choices (window, horizontal band, vertical
// band). Large enough to read at a glance, with a small icon and a one-line
// explanation.
BorderSurface {
  id: root

  property string title: ""
  property string description: ""
  property string glyph: ""
  property bool selected: false
  property bool hasCursor: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal hovered(bool isHovered)
  signal clicked()

  readonly property bool hot: root.hasCursor || tileHover.hovered
  readonly property color dim: Qt.darker(root.foreground, 1.5)

  implicitHeight: Style.space(92)
  radius: Style.cornerRadius
  color: selected
    ? Style.selectedFillFor(root.foreground, root.accent)
    : (hot ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")
  borderSpec: selected
    ? Border.flat(root.accent, Math.max(1, Style.space(2)))
    : (hot ? Border.controlSpec("hover-cursor", root.foreground, root.accent)
      : Border.controlSpec("normal", root.foreground, root.accent))

  Behavior on color { ColorAnimation { duration: 110 } }

  HoverHandler {
    id: tileHover
    onHoveredChanged: root.hovered(tileHover.hovered)
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.topMargin: root.borderTop + Style.space(11)
    anchors.bottomMargin: root.borderBottom + Style.space(9)
    anchors.leftMargin: root.borderLeft + Style.space(11)
    anchors.rightMargin: root.borderRight + Style.space(11)
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: root.glyph
      color: root.selected ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: root.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: root.description
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }
  }
}
