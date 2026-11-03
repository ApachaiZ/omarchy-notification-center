import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Grouped keyboard reference. The panel builds the groups from the user's
// configured keys, so this component stays purely presentational.
Column {
  id: root

  property var groups: []
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  spacing: Style.space(10)

  readonly property color dim: Qt.darker(root.foreground, 1.55)

  Repeater {
    model: root.groups

    BorderSurface {
      required property var modelData
      width: root.width
      implicitHeight: groupColumn.implicitHeight + Style.space(18) + borderTop + borderBottom
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)
      borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

      ColumnLayout {
        id: groupColumn
        anchors.fill: parent
        anchors.topMargin: parent.borderTop + Style.space(10)
        anchors.bottomMargin: parent.borderBottom + Style.space(10)
        anchors.leftMargin: parent.borderLeft + Style.space(12)
        anchors.rightMargin: parent.borderRight + Style.space(12)
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: String(modelData.title || "").toUpperCase()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        Repeater {
          model: modelData.items || []

          RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(10)

            Item {
              Layout.preferredWidth: Style.space(88)
              Layout.fillHeight: true
              implicitHeight: keyCap.implicitHeight

              KeyCap {
                id: keyCap
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.key || "")
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
              }
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: String(modelData.label || "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
}
