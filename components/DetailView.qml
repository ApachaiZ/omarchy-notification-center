import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Expanded notification. The panel keeps the surrounding navigation; this
// component owns the readable card, media and the two primary actions.
Column {
  id: root

  property var entry: null
  property string iconSource: ""
  property string bodyMarkup: ""
  property bool bodyHidden: false
  property string imageSource: ""
  property string timeText: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property color cardText: Commons.Color.notifications.text
  property string fontFamily: Style.font.family

  signal openAppRequested(var entry)
  signal removeRequested(var entry)

  // Keeps the StyledText gate in tests and documents that bodyMarkup is
  // already sanitized by Model.styledBody().
  function bodyText() { return root.bodyMarkup }

  readonly property bool critical: root.entry && Number(root.entry.urgency) === 2
  readonly property bool low: root.entry && Number(root.entry.urgency) === 0
  readonly property color dim: Qt.darker(root.foreground, 1.5)
  readonly property color bodyColor: Qt.darker(root.cardText, 1.12)

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  RowLayout {
    width: parent.width
    spacing: Style.space(12)

    IconTile {
      Layout.alignment: Qt.AlignTop
      size: Style.space(52)
      source: root.iconSource
      glyph: root.entry ? root.entry.glyph : ""
      foreground: root.cardText
      accent: root.accent
      fontFamily: root.fontFamily
      glyphSize: Style.font.title
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.entry && root.entry.app.length > 0
            ? (root.entry.app === "omarchy-action" ? "Omarchy" : root.entry.app)
            : "Notification"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        BorderSurface {
          visible: root.critical
          implicitWidth: urgencyLabel.implicitWidth + Style.space(12)
          implicitHeight: urgencyLabel.implicitHeight + Style.space(5)
          radius: height / 2
          color: Style.selectedFillFor(root.urgent, root.urgent)
          borderSpec: Border.controlSpec("normal", root.urgent, root.urgent)

          Text {
            id: urgencyLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "Critical"
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        BorderSurface {
          visible: root.low
          implicitWidth: lowLabel.implicitWidth + Style.space(12)
          implicitHeight: lowLabel.implicitHeight + Style.space(5)
          radius: height / 2
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.dim, root.accent)

          Text {
            id: lowLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "Low"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: root.timeText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  BorderSurface {
    width: parent.width
    implicitHeight: detailColumn.implicitHeight + borderTop + borderBottom + Style.space(28)
    radius: Style.cornerRadius
    color: Commons.Color.notifications.background
    borderSpec: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
    clip: true

    ColumnLayout {
      id: detailColumn
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: parent.borderTop + Style.space(14)
      anchors.leftMargin: parent.borderLeft + Style.space(14)
      anchors.rightMargin: parent.borderRight + Style.space(14)
      spacing: Style.space(9)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        visible: root.entry && root.entry.summary.length > 0
        text: root.entry ? root.entry.summary : ""
        color: root.cardText
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        visible: root.bodyMarkup.length > 0
        text: root.bodyText()
        textFormat: Text.StyledText
        color: root.bodyColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        visible: root.bodyHidden && root.entry && root.entry.body.length > 0
        text: "Body hidden by the privacy settings."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
        wrapMode: Text.WordWrap
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(180)
        visible: root.imageSource.length > 0 && detailImage.status !== Image.Error
        radius: Math.max(Style.space(4), Math.round(Style.cornerRadius * 0.8))
        color: Style.normalFillFor(root.cardText, root.accent)
        clip: true

        Image {
          id: detailImage
          anchors.fill: parent
          source: root.imageSource
          sourceSize.width: Math.round(root.width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(Style.space(180) * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
        }
      }
    }
  }

  RowLayout {
    width: parent.width
    spacing: Style.space(8)

    Button {
      Layout.fillWidth: true
      Layout.preferredWidth: 1
      text: "Open app"
      iconText: "󰌌"
      bordered: true
      selected: true
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      foreground: root.foreground
      accent: root.accent
      enabled: root.entry && root.entry.app.length > 0
      onClicked: root.openAppRequested(root.entry)
    }

    Button {
      Layout.fillWidth: true
      Layout.preferredWidth: 1
      text: "Dismiss"
      iconText: "󰆴"
      bordered: true
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      foreground: root.urgent
      accent: root.urgent
      onClicked: root.removeRequested(root.entry)
    }
  }
}
