import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One notification in the vertical list. Presentation only: the panel owns
// selection, deletion and navigation. `bodyMarkup` is already sanitized by
// Model.bodyText() before it reaches this component.
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
  property color cardText: Commons.Color.notifications.text
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property string fontFamily: Style.font.family

  signal hovered(int index)
  signal detailsRequested(var entry)
  signal appRequested(var entry)
  signal removeRequested(var entry)

  // The security test only allows StyledText through a function named
  // bodyText(); this returns the already-sanitized markup passed in.
  function bodyText() { return root.bodyMarkup }

  readonly property bool critical: root.entry && Number(root.entry.urgency) === 2
  readonly property color dimColor: Qt.darker(root.cardText, 1.45)
  readonly property color bodyColor: Qt.darker(root.cardText, 1.13)

  width: parent ? parent.width : 0
  radius: Style.cornerRadius
  color: root.cursorActive
    ? Style.selectedFillFor(root.cardText, root.accent)
    : (rowHover.hovered ? Style.hoverFillFor(root.cardText, root.accent) : Commons.Color.notifications.background)
  borderSpec: root.cursorActive
    ? Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
    : Border.controlSpec("normal", root.cardText, root.accent)
  clip: true

  implicitHeight: rowLayout.implicitHeight + root.borderTop + root.borderBottom


  HoverHandler {
    id: rowHover
    onHoveredChanged: if (rowHover.hovered) root.hovered(root.rowIndex)
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

  // A quiet accent rail marks unread rows; critical notifications use the
  // urgent colour so urgency survives the privacy "hide bodies" mode.
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
    opacity: root.cursorActive ? 1 : 0.8
  }

  RowLayout {
    id: rowLayout
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.borderTop
    anchors.leftMargin: root.borderLeft
    anchors.rightMargin: root.borderRight
    anchors.bottomMargin: root.borderBottom
    spacing: Style.space(10)

    IconTile {
      Layout.leftMargin: Style.space(12) + (root.unread || root.critical ? Style.space(3) : 0)
      Layout.topMargin: Style.space(10)
      Layout.bottomMargin: Style.space(10)
      Layout.alignment: Qt.AlignTop
      size: Style.space(38)
      source: root.iconSource
      glyph: root.entry ? root.entry.glyph : ""
      foreground: root.cardText
      accent: root.accent
      fontFamily: root.fontFamily
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.topMargin: Style.space(9)
      Layout.bottomMargin: Style.space(9)
      Layout.rightMargin: Style.space(10)
      spacing: Style.space(3)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Rectangle {
          visible: root.unread
          Layout.preferredWidth: Style.space(6)
          Layout.preferredHeight: Style.space(6)
          Layout.alignment: Qt.AlignVCenter
          radius: Style.space(3)
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

        // The timestamp and the two hover actions share one fixed corner.
        // Swapping them instead of appending keeps the card width stable.
        Item {
          Layout.preferredWidth: Style.space(50)
          Layout.preferredHeight: Math.max(Style.space(22), timeText.implicitHeight)
          Layout.alignment: Qt.AlignVCenter

          Text {
            id: timeText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.timeText
            color: root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: rowHover.hovered ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 90 } }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)
            opacity: rowHover.hovered ? 1 : 0
            visible: rowHover.hovered
            Behavior on opacity { NumberAnimation { duration: 90 } }

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
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        visible: root.entry && root.entry.summary.length > 0
        text: root.entry ? root.entry.summary : ""
        color: root.cardText
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
      }

      Text {
        Layout.fillWidth: true
        visible: root.showBody && root.bodyMarkup.length > 0
        text: root.bodyText()
        textFormat: Text.StyledText
        color: root.bodyColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
      }
    }
  }
}
