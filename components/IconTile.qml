import QtQuick
import qs.Commons
import qs.Commons as Commons

// The rounded icon plate used by every notification surface. Keeping the
// plate, the image fallback and the glyph fallback in one place is what
// makes list rows, compact cards and the detail view agree on the same look.
Item {
  id: root

  property string source: ""
  property string glyph: ""
  property string fallbackGlyph: "󰂚"
  property real size: Style.space(38)
  property color foreground: Commons.Color.notifications.text
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real glyphSize: Style.font.icon
  property bool tinted: true

  // An app icon that resolves at least once stays visible even if a later
  // source fails; this avoids a flash of the bell while a themed icon is
  // being looked up.
  property bool imageFailed: false

  implicitWidth: size
  implicitHeight: size

  readonly property string shownGlyph: glyph !== "" ? glyph : fallbackGlyph
  readonly property bool showGlyph: source === "" || imageFailed
  readonly property real imageInset: Math.round(size * 0.2)

  Rectangle {
    anchors.fill: parent
    radius: Math.min(Style.cornerRadius, Math.round(root.size * 0.28))
    color: root.tinted ? Style.normalFillFor(root.foreground, root.accent) : "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  }

  Image {
    anchors.fill: parent
    anchors.margins: root.imageInset
    visible: !root.showGlyph
    source: root.source
    sourceSize.width: Math.max(1, Math.round((root.size - root.imageInset * 2) * Screen.devicePixelRatio))
    sourceSize.height: Math.max(1, Math.round((root.size - root.imageInset * 2) * Screen.devicePixelRatio))
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    onStatusChanged: {
      if (status === Image.Error) root.imageFailed = true
      else if (status === Image.Ready) root.imageFailed = false
    }
  }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    visible: root.showGlyph && root.shownGlyph !== ""
    text: root.shownGlyph
    color: Qt.darker(root.foreground, 1.12)
    font.family: root.fontFamily
    font.pixelSize: root.glyphSize
  }
}
