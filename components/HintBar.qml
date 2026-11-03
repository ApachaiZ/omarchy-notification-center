import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons

// Contextual keycap strip. The caller supplies [{ key, label }, ...]; the
// strip justifies every hint across the full card width. Each hint owns an
// equal cell and its label elides, so a narrow card loses text rather than
// letting cells overlap.
Item {
  id: root

  property var hints: []
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  implicitHeight: topRule.height + Style.space(5) + hintRow.implicitHeight + Style.space(5)
  implicitWidth: parent ? parent.width : Style.space(320)

  readonly property color dim: Qt.darker(root.foreground, 1.55)

  Rectangle {
    id: topRule
    anchors.top: parent.top
    width: parent.width
    height: 1
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  }

  RowLayout {
    id: hintRow
    anchors.top: topRule.bottom
    anchors.topMargin: Style.space(5)
    anchors.left: parent.left
    anchors.leftMargin: Style.space(2)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(2)
    height: implicitHeight
    spacing: 0

    Repeater {
      model: root.hints

      RowLayout {
        required property var modelData
        required property int index
        readonly property bool last: index === root.hints.length - 1
        Layout.fillWidth: !last
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(5)

        KeyCap {
          Layout.alignment: Qt.AlignVCenter
          text: String(modelData.key || "")
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
        }

        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: String(modelData.label || "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        // The spacer lives after every hint except the last, so the first
        // hint starts at the left edge and the last ends at the right edge.
        Item {
          Layout.fillWidth: true
          visible: !parent.last
        }
      }
    }
  }
}
