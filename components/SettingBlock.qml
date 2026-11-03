import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Full-width settings block for controls that need the whole row, such as
// the three layout tiles or the placement miniatures. SettingRow handles the
// label-on-the-left case; this is its stacked sibling.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool active: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  default property alias content: control.data

  signal hovered(bool isHovered)

  implicitHeight: blockLayout.implicitHeight + Style.space(18) + root.borderTop + root.borderBottom
  radius: Style.cornerRadius
  color: root.active
    ? Style.hoverFillFor(root.foreground, root.accent)
    : Style.normalFillFor(root.foreground, root.accent)
  borderSpec: root.active
    ? Border.controlSpec("hover-cursor", root.foreground, root.accent)
    : Border.controlSpec("normal", root.foreground, root.accent)

  Behavior on color { ColorAnimation { duration: 100 } }

  HoverHandler {
    id: blockHover
    onHoveredChanged: root.hovered(blockHover.hovered)
  }

  ColumnLayout {
    id: blockLayout
    anchors.fill: parent
    anchors.topMargin: root.borderTop + Style.space(9)
    anchors.bottomMargin: root.borderBottom + Style.space(9)
    anchors.leftMargin: root.borderLeft + Style.space(12)
    anchors.rightMargin: root.borderRight + Style.space(12)
    spacing: Style.space(8)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: root.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        visible: root.description !== ""
        text: root.description
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Item {
      id: control
      Layout.fillWidth: true
      implicitWidth: childrenRect.width
      implicitHeight: childrenRect.height
    }
  }
}
