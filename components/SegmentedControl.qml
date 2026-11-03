import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Full-width mutually-exclusive choice row. Every option gets the same share
// of the available width, so a settings row never leaves a large empty gap
// between its label and its buttons.
RowLayout {
  id: root

  property var options: []
  property string value: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property bool enabled: true

  signal changed(string value)

  width: parent ? parent.width : implicitWidth
  height: implicitHeight
  spacing: Style.space(3)

  function optionValue(option) {
    return (option && typeof option === "object") ? String(option.value) : String(option)
  }

  function optionLabel(option) {
    return (option && typeof option === "object" && option.label !== undefined)
      ? String(option.label) : String(option)
  }

  Repeater {
    model: root.options

    Button {
      required property var modelData
      Layout.fillWidth: true
      Layout.preferredWidth: 1
      text: root.optionLabel(modelData)
      selected: root.optionValue(modelData) === root.value
      bordered: true
      enabled: root.enabled
      background: "transparent"
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: root.changed(root.optionValue(modelData))
    }
  }
}
