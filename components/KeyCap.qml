import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A small keycap used by the footer hint strip and the shortcut reference.
// It deliberately uses the theme's normal control chrome so it reads as a
// key, not as a button the user can press.
BorderSurface {
  id: root

  property string text: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  implicitWidth: label.implicitWidth + Style.space(10)
  implicitHeight: Math.max(Style.space(20), label.implicitHeight + Style.space(6))
  radius: Math.max(Style.space(4), Math.round(Style.cornerRadius * 0.7))
  color: Style.normalFillFor(root.foreground, root.accent)
  borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
