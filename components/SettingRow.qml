import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A settings line: title and short explanation on the left, whatever the
// caller puts inside on the right. The row owns the cursor highlight and the
// hover signal so mouse and keyboard share one selection model.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool active: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  // Instances declare their control directly inside SettingRow { ... }.
  default property alias content: control.data

  signal hovered(bool isHovered)

  implicitHeight: Math.max(labels.implicitHeight, control.implicitHeight)
    + Style.space(18) + root.borderTop + root.borderBottom
  radius: Style.cornerRadius
  color: root.active
    ? Style.hoverFillFor(root.foreground, root.accent)
    : Style.normalFillFor(root.foreground, root.accent)
  borderSpec: root.active
    ? Border.controlSpec("hover-cursor", root.foreground, root.accent)
    : Border.controlSpec("normal", root.foreground, root.accent)

  Behavior on color { ColorAnimation { duration: 100 } }


  HoverHandler {
    id: rowHover
    onHoveredChanged: root.hovered(rowHover.hovered)
  }

  RowLayout {
    anchors.fill: parent
    anchors.topMargin: root.borderTop + Style.space(9)
    anchors.bottomMargin: root.borderBottom + Style.space(9)
    anchors.leftMargin: root.borderLeft + Style.space(12)
    anchors.rightMargin: root.borderRight + Style.space(12)
    spacing: Style.space(12)

    ColumnLayout {
      id: labels
      Layout.fillWidth: false
      Layout.preferredWidth: Style.space(190)
      Layout.minimumWidth: Style.space(120)
      Layout.maximumWidth: Style.space(190)
      Layout.alignment: Qt.AlignTop
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
      Layout.alignment: Qt.AlignVCenter
      implicitHeight: childrenRect.height
    }
  }
}
