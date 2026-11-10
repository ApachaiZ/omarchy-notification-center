import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Horizontal-band variant of NotificationRow. The card has a fixed width so
// the strip can be measured and centred as one row.
BorderSurface {
  id: root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  property var entry: null
  property int rowIndex: -1
  property bool cursorActive: false
  property bool unread: false
  property bool showBody: true
  property string iconSource: ""
  property string bodyMarkup: ""
  property string timeText: ""
  property real preferredWidth: Style.space(300)
  property color cardText: Commons.Color.notifications.text
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  signal hovered(int index)
  signal detailsRequested(var entry)
  signal appRequested(var entry)
  signal removeRequested(var entry)

  function bodyText() { return root.bodyMarkup }

  readonly property bool critical: root.entry && Number(root.entry.urgency) === 2
  readonly property color dimColor: Qt.darker(root.cardText, 1.45)
  readonly property color bodyColor: Qt.darker(root.cardText, 1.13)

  implicitWidth: preferredWidth
  implicitHeight: Style.space(100)
  width: preferredWidth
  height: implicitHeight
  radius: Style.cornerRadius
  color: root.cursorActive
    ? Style.selectedFillFor(root.cardText, root.accent)
    : (compactHover.hovered ? Style.hoverFillFor(root.cardText, root.accent) : Commons.Color.notifications.background)
  borderSpec: root.cursorActive
    ? Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
    : Border.controlSpec("normal", root.cardText, root.accent)
  clip: true


  HoverHandler {
    id: compactHover
    onHoveredChanged: if (compactHover.hovered) root.hovered(root.rowIndex)
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.removeRequested(root.entry)
      else root.detailsRequested(root.entry)
    }
  }

  Rectangle {
    visible: root.unread || root.critical
    anchors.left: parent.left
    anchors.leftMargin: root.borderLeft + Style.space(4)
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.space(9)
    anchors.bottomMargin: Style.space(9)
    width: Math.max(2, Style.space(2))
    radius: width / 2
    color: root.critical ? root.urgent : root.accent
    opacity: 0.85
  }

  RowLayout {
    anchors.fill: parent
    anchors.topMargin: root.borderTop + Style.space(9)
    anchors.bottomMargin: root.borderBottom + Style.space(9)
    anchors.leftMargin: root.borderLeft + Style.space(12) + (root.unread || root.critical ? Style.space(3) : 0)
    anchors.rightMargin: root.borderRight + Style.space(10)
    spacing: Style.space(9)

    IconTile {
      Layout.alignment: Qt.AlignTop
      Layout.preferredWidth: Style.space(32)
      Layout.preferredHeight: Style.space(32)
      size: Style.space(32)
      source: root.iconSource
      glyph: root.entry ? root.entry.glyph : ""
      foreground: root.cardText
      accent: root.accent
      fontFamily: root.fontFamily
      glyphSize: Style.font.body
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(5)

        Rectangle {
          visible: root.unread
          Layout.preferredWidth: Style.space(5)
          Layout.preferredHeight: Style.space(5)
          Layout.alignment: Qt.AlignVCenter
          radius: Style.space(2.5)
          color: root.accent
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.entry && root.entry.app.length > 0
            ? (root.entry.app === "omarchy-action" ? "Omarchy" : root.entry.app)
            : strings.t("notification.appFallback")
          color: root.unread ? root.cardText : root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: root.unread
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: root.timeText
          color: root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          opacity: compactHover.hovered ? 0 : 1
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        visible: root.entry && root.entry.summary.length > 0
        text: root.entry ? root.entry.summary : ""
        color: root.cardText
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        maximumLineCount: 1
      }

      Text {
        Layout.fillWidth: true
        visible: root.showBody && root.bodyMarkup.length > 0
        text: root.bodyText()
        textFormat: Text.StyledText
        color: root.bodyColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
      }
    }
  }

  // Hover actions sit above the card content instead of widening it.
  Row {
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: root.borderTop + Style.space(4)
    anchors.rightMargin: root.borderRight + Style.space(4)
    spacing: Style.space(1)
    visible: compactHover.hovered

    PanelActionButton {
      size: Style.space(22)
      iconText: "󰌌"
      tooltipText: strings.t("row.openApp")
      foreground: root.cardText
      hoverColor: root.accent
      fontFamily: root.fontFamily
      onClicked: root.appRequested(root.entry)
    }

    PanelActionButton {
      size: Style.space(22)
      iconText: "󰆴"
      tooltipText: strings.t("row.remove")
      foreground: root.cardText
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      onClicked: root.removeRequested(root.entry)
    }
  }
}
