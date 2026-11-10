import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Settings are split into a navigation rail and one focused category pane.
// The panel still owns the keyboard cursor; this view only reflects it and
// forwards mouse selections back through focusSetting().
Item {
  id: view

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("../i18n") }

  property var panel: null

  readonly property var store: panel ? panel.store : null
  readonly property var idx: panel ? panel.settingsIndex : ({})
  readonly property var categories: panel ? panel.settingsCategories : []
  readonly property var category: panel && categories.length > panel.settingsCategory
    ? categories[panel.settingsCategory]
    : ({ label: "", description: "", rows: [] })

  readonly property color fg: panel ? panel.fg : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color lineColor: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property bool engineInstalled: !!store && String(store.engineVersion || "") !== ""
  readonly property bool engineActive: !!store && store.engineEnabled === true

  implicitWidth: mainLayout.implicitWidth
  implicitHeight: mainLayout.implicitHeight
  height: mainLayout.implicitHeight

  function active(row) { return !!panel && panel.settingsCursor === row }
  function focus(row) { if (panel) panel.focusSetting(row) }
  function isCategory(id) { return !!category && category.id === id }

  function engineStatusText() {
    if (!store) return ""
    if (engineActive) {
      return engineInstalled
        ? strings.t("settings.engine.activeVersion").arg(store.engineVersion)
        : strings.t("settings.engine.active")
    }
    if (engineInstalled) return strings.t("settings.engine.disabled")
    return strings.t("settings.engine.notInstalled")
  }

  function engineButtonText() {
    if (!store) return strings.t("settings.engine.install")
    if (store.engineInstallArmed) return strings.t("settings.engine.confirm")
    if (engineActive) return strings.t("settings.engine.update")
    return engineInstalled
      ? strings.t("settings.engine.enable")
      : strings.t("settings.engine.install")
  }

  function barPositionText() {
    if (!store || store.barSection === "") return "—"
    var size = Number(store.barSizes[store.barSection] || 0)
    return strings.t("settings.bar.position")
      .arg(Commons.I18n.formatNumber(store.barIndex + 1))
      .arg(Commons.I18n.formatNumber(Math.max(1, size)))
  }

  RowLayout {
    id: mainLayout
    width: view.width
    spacing: Style.space(14)

    // ---------------------------------------------------------- navigation
    Column {
      id: sidebar
      Layout.preferredWidth: Style.space(168)
      Layout.alignment: Qt.AlignTop
      spacing: Style.space(4)

      Repeater {
        model: view.categories

        BorderSurface {
          id: navItem
          required property var modelData
          required property int index
          width: sidebar.width
          height: Style.space(38)
          radius: Style.cornerRadius
          color: index === (view.panel ? view.panel.settingsCategory : -1)
            ? Style.selectedFillFor(view.fg, view.accent)
            : (navHover.hovered ? Style.hoverFillFor(view.fg, view.accent) : "transparent")
          borderSpec: index === (view.panel ? view.panel.settingsCategory : -1)
            ? Border.controlSpec("selected", view.fg, view.accent)
            : Border.none()

          Behavior on color { ColorAnimation { duration: 100 } }

          Rectangle {
            visible: index === (view.panel ? view.panel.settingsCategory : -1)
            anchors.left: parent.left
            anchors.leftMargin: parent.borderLeft + Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(2, Style.space(2))
            height: parent.height - Style.space(14)
            radius: width / 2
            color: view.accent
          }

          HoverHandler { id: navHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (view.panel) view.panel.selectSettingsCategory(index)
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: parent.borderLeft + Style.space(12)
            anchors.rightMargin: parent.borderRight + Style.space(8)
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: String(modelData.glyph || "")
              color: index === (view.panel ? view.panel.settingsCategory : -1) ? view.accent : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: String(modelData.label || "")
              color: view.fg
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: index === (view.panel ? view.panel.settingsCategory : -1)
              elide: Text.ElideRight
            }
          }
        }
      }

      Item { width: 1; height: Style.space(6) }

      BorderSurface {
        width: sidebar.width
        implicitHeight: engineHint.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        color: Style.normalFillFor(view.fg, view.accent)
        borderSpec: Border.controlSpec("normal", view.fg, view.accent)

        RowLayout {
          id: engineHint
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(8)

          Rectangle {
            Layout.alignment: Qt.AlignTop
            width: Style.space(7)
            height: width
            radius: width / 2
            color: view.engineActive ? view.accent : view.dim
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: view.engineInstalled
                ? strings.t("settings.engine.title")
                : strings.t("settings.engine.stockService")
              color: view.fg
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: view.engineStatusText()
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    Rectangle {
      Layout.preferredWidth: 1
      Layout.fillHeight: true
      Layout.alignment: Qt.AlignTop
      color: view.lineColor
    }

    // ------------------------------------------------------------- content
    Column {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignTop
      spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: String(view.category.label || "")
          color: view.fg
          font.family: view.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: String(view.category.description || "")
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // -------------------------------------------------- layout category
      Column {
        width: parent.width
        visible: view.isCategory("layout")
        spacing: Style.space(8)

        SettingBlock {
          width: parent.width
          label: strings.t("settings.layout.mode")
          description: strings.t("settings.layout.modeDescription")
          active: view.active(view.idx.mode)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.mode) }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            ModeTile {
              Layout.fillWidth: true
              title: strings.t("settings.layout.window")
              description: strings.t("settings.layout.windowDescription")
              glyph: "󰖯"
              selected: view.store && view.store.mode === "window"
              hasCursor: view.active(view.idx.mode) && selected
              foreground: view.fg
              accent: view.accent
              fontFamily: view.fontFamily
              onClicked: { view.focus(view.idx.mode); if (view.store) view.store.setMode("window") }
            }

            ModeTile {
              Layout.fillWidth: true
              title: strings.t("settings.layout.horizontal")
              description: strings.t("settings.layout.horizontalDescription")
              glyph: "󰍹"
              selected: view.store && view.store.mode === "horizontal"
              hasCursor: view.active(view.idx.mode) && selected
              foreground: view.fg
              accent: view.accent
              fontFamily: view.fontFamily
              onClicked: { view.focus(view.idx.mode); if (view.store) view.store.setMode("horizontal") }
            }

            ModeTile {
              Layout.fillWidth: true
              title: strings.t("settings.layout.vertical")
              description: strings.t("settings.layout.verticalDescription")
              glyph: "󰤼"
              selected: view.store && view.store.mode === "vertical"
              hasCursor: view.active(view.idx.mode) && selected
              foreground: view.fg
              accent: view.accent
              fontFamily: view.fontFamily
              onClicked: { view.focus(view.idx.mode); if (view.store) view.store.setMode("vertical") }
            }
          }
        }

        SliderSetting {
          width: parent.width
          rowIndex: view.idx.marginX
          label: strings.t("settings.layout.marginX")
          description: strings.t("settings.layout.marginXDescription")
          sliderValue: view.store ? view.store.marginX : 12
          sliderMin: 0
          sliderMax: 64
          sliderStep: 4
          onValueEdited: function(v) { view.focus(view.idx.marginX); if (view.store) view.store.setMargin("x", v) }
        }

        SliderSetting {
          width: parent.width
          rowIndex: view.idx.marginY
          label: strings.t("settings.layout.marginY")
          description: strings.t("settings.layout.marginYDescription")
          sliderValue: view.store ? view.store.marginY : 12
          sliderMin: 0
          sliderMax: 64
          sliderStep: 4
          onValueEdited: function(v) { view.focus(view.idx.marginY); if (view.store) view.store.setMargin("y", v) }
        }

        SliderSetting {
          width: parent.width
          rowIndex: view.idx.padding
          label: strings.t("settings.layout.padding")
          description: strings.t("settings.layout.paddingDescription")
          sliderValue: view.store ? view.store.padding : 12
          sliderMin: 4
          sliderMax: 32
          sliderStep: 2
          onValueEdited: function(v) { view.focus(view.idx.padding); if (view.store) view.store.setPadding(v) }
        }

        SliderSetting {
          width: parent.width
          rowIndex: view.idx.cardSpacing
          label: strings.t("settings.layout.spacing")
          description: strings.t("settings.layout.spacingDescription")
          sliderValue: view.store ? view.store.cardSpacing : 10
          sliderMin: 2
          sliderMax: 24
          sliderStep: 2
          onValueEdited: function(v) { view.focus(view.idx.cardSpacing); if (view.store) view.store.setCardSpacing(v) }
        }
      }

      // ------------------------------------------------ position category
      Column {
        width: parent.width
        visible: view.isCategory("position")
        spacing: Style.space(8)

        SettingBlock {
          width: parent.width
          label: strings.t("settings.position.placement")
          description: strings.t("settings.position.placementDescription")
          active: view.active(view.idx.placement)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.placement) }

          GridLayout {
            width: parent.width
            columns: 4
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: strings.t("settings.position.top")
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              Layout.preferredWidth: Style.space(38)
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "top"; horizontal: "left"
              selected: view.store && view.store.placement === "top-left"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("top", "left") }
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "top"; horizontal: "center"
              selected: view.store && view.store.placement === "top-center"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("top", "center") }
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "top"; horizontal: "right"
              selected: view.store && view.store.placement === "top-right"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("top", "right") }
            }

            Text {
              textFormat: Text.PlainText
              text: strings.t("settings.position.bottom")
              color: view.dim
              opacity: view.store && view.store.mode === "vertical" ? 0.35 : 1
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              Layout.preferredWidth: Style.space(38)
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "bottom"; horizontal: "left"
              selected: view.store && view.store.placement === "bottom-left"
              enabled: !view.store || view.store.mode !== "vertical"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("bottom", "left") }
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "bottom"; horizontal: "center"
              selected: view.store && view.store.placement === "bottom-center"
              enabled: !view.store || view.store.mode !== "vertical"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("bottom", "center") }
            }

            PlacementTile {
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              vertical: "bottom"; horizontal: "right"
              selected: view.store && view.store.placement === "bottom-right"
              enabled: !view.store || view.store.mode !== "vertical"
              hasCursor: view.active(view.idx.placement) && selected
              foreground: view.fg; accent: view.accent
              onClicked: { view.focus(view.idx.placement); if (view.store) view.panel.setPlacement("bottom", "right") }
            }
          }
        }

        SettingBlock {
          width: parent.width
          label: strings.t("settings.position.centerScreen")
          description: strings.t("settings.position.centerScreenDescription")
          active: view.active(view.idx.centerScreen)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.centerScreen) }

          Button {
            width: parent.width
            text: strings.t("settings.position.centerCard")
            iconText: "󰍹"
            bordered: true
            selected: view.store && view.store.placement === "center-center"
            enabled: !view.store || view.store.mode !== "vertical"
            foreground: view.fg
            accent: view.accent
            fontFamily: view.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: {
              view.focus(view.idx.centerScreen)
              if (view.store && view.store.mode !== "vertical") view.panel.setPlacement("center", "center")
            }
          }
        }

        SettingBlock {
          width: parent.width
          label: strings.t("settings.position.monitors")
          description: strings.t("settings.position.monitorsDescription")
          active: view.active(view.idx.screens)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.screens) }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: view.panel ? view.panel.screenList : []

              Button {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                readonly property string screenName: String(modelData.name || "")
                readonly property bool selectedScreen: view.store
                  && view.store.screenNames.indexOf(screenName) !== -1
                text: (selectedScreen ? "✓ " : "") + screenName
                bordered: true
                selected: selectedScreen
                hasCursor: view.active(view.idx.screens) && view.panel.screenCursor === index
                foreground: view.fg
                accent: view.accent
                fontFamily: view.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: {
                  view.focus(view.idx.screens)
                  if (view.panel) view.panel.screenCursor = index
                  if (view.store) view.store.toggleScreen(screenName)
                }
                onHovered: function(h) {
                  if (!h) return
                  view.focus(view.idx.screens)
                  if (view.panel) view.panel.screenCursor = index
                }
              }
            }
          }
        }
      }

      // -------------------------------------------- notifications category
      Column {
        width: parent.width
        visible: view.isCategory("notifications")
        spacing: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("settings.notifications.behavior")
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }

        SettingBlock {
          width: parent.width
          label: strings.t("settings.notifications.enterOpens")
          description: strings.t("settings.notifications.enterOpensDescription")
          active: view.active(view.idx.enterOpens)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.enterOpens) }

          SegmentedControl {
            width: parent.width
            options: [
              { value: "app", label: strings.t("settings.notifications.openApp") },
              { value: "detail", label: strings.t("settings.notifications.details") }
            ]
            value: view.store ? view.store.enterOpens : "app"
            foreground: view.fg
            accent: view.accent
            fontFamily: view.fontFamily
            onChanged: function(v) {
              view.focus(view.idx.enterOpens)
              if (view.store) view.store.setEnterOpens(v)
            }
          }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.notifications.hintBar")
          description: strings.t("settings.notifications.hintBarDescription")
          checked: view.store ? view.store.shortcutBar : true
          hasCursor: view.active(view.idx.shortcutBar)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.shortcutBar)
            if (view.store) view.store.setShortcutBar(!view.store.shortcutBar)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.shortcutBar) }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("settings.notifications.privacy")
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
          topPadding: Style.space(2)
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.notifications.hideBodies")
          description: strings.t("settings.notifications.hideBodiesDescription")
          checked: view.store ? view.store.hideBodies : false
          hasCursor: view.active(view.idx.hideBodies)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.hideBodies)
            if (view.store) view.store.setHideBodies(!view.store.hideBodies)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.hideBodies) }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.notifications.showPreviews")
          description: strings.t("settings.notifications.showPreviewsDescription")
          checked: view.store ? view.store.showPreviews : true
          hasCursor: view.active(view.idx.showPreviews)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.showPreviews)
            if (view.store) view.store.setShowPreviews(!view.store.showPreviews)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.showPreviews) }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.notifications.showBadge")
          description: strings.t("settings.notifications.showBadgeDescription")
          checked: view.store ? view.store.showBadge : true
          hasCursor: view.active(view.idx.showBadge)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.showBadge)
            if (view.store) view.store.setShowBadge(!view.store.showBadge)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.showBadge) }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.notifications.captureToasts")
          description: strings.t("settings.notifications.captureToastsDescription")
          checked: view.store ? view.store.captureToasts : true
          hasCursor: view.active(view.idx.captureToasts)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.captureToasts)
            if (view.store) view.store.setCaptureToasts(!view.store.captureToasts)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.captureToasts) }
        }
      }

      // ----------------------------------------------- shortcuts category
      Column {
        width: parent.width
        visible: view.isCategory("shortcuts")
        spacing: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("settings.shortcuts.note")
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        KeyChoiceRow {
          width: parent.width
          rowIndex: view.idx.searchKey
          title: strings.t("settings.shortcuts.search")
          description: strings.t("settings.shortcuts.searchDescription")
          options: [
            { value: "/", label: "/" },
            { value: "ctrl+f", label: "Ctrl+F" }
          ]
          current: view.store ? view.store.searchKey : "/"
          onPicked: function(v) { if (view.store) view.store.setSearchKey(v) }
        }

        KeyChoiceRow {
          width: parent.width
          rowIndex: view.idx.dndKey
          title: strings.t("settings.shortcuts.dnd")
          description: strings.t("settings.shortcuts.dndDescription")
          options: [
            { value: "d", label: "d" },
            { value: "D", label: "Shift+D" }
          ]
          current: view.store ? view.store.dndKey : "d"
          onPicked: function(v) { if (view.store) view.store.setDndKey(v) }
        }

        KeyChoiceRow {
          width: parent.width
          rowIndex: view.idx.detailKey
          title: strings.t("settings.shortcuts.details")
          description: strings.t("settings.shortcuts.detailsDescription")
          options: [
            { value: "i", label: "i" },
            { value: "I", label: "Shift+I" }
          ]
          current: view.store ? view.store.detailKey : "i"
          onPicked: function(v) { if (view.store) view.store.setDetailKey(v) }
        }

        KeyChoiceRow {
          width: parent.width
          rowIndex: view.idx.helpKey
          title: strings.t("settings.shortcuts.help")
          description: strings.t("settings.shortcuts.helpDescription")
          options: [
            { value: "?", label: "?" },
            { value: "F1", label: "F1" }
          ]
          current: view.store ? view.store.helpKey : "?"
          onPicked: function(v) { if (view.store) view.store.setHelpKey(v) }
        }

        KeyChoiceRow {
          width: parent.width
          rowIndex: view.idx.settingsKey
          title: strings.t("settings.shortcuts.settings")
          description: strings.t("settings.shortcuts.settingsDescription")
          options: [
            { value: "s", label: "s" },
            { value: "P", label: "Shift+P" }
          ]
          current: view.store ? view.store.settingsKey : "s"
          onPicked: function(v) { if (view.store) view.store.setSettingsKey(v) }
        }
      }

      // -------------------------------------------------- engine category
      Column {
        width: parent.width
        visible: view.isCategory("engine")
        spacing: Style.space(8)

        BorderSurface {
          width: parent.width
          implicitHeight: engineCard.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.normalFillFor(view.fg, view.accent)
          borderSpec: Border.controlSpec("normal", view.fg, view.accent)

          RowLayout {
            id: engineCard
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(10)

            Rectangle {
              Layout.alignment: Qt.AlignTop
              width: Style.space(34)
              height: width
              radius: Math.min(Style.cornerRadius, Style.space(10))
              color: Style.selectedFillFor(view.fg, view.accent)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "󰒓"
                color: view.engineActive ? view.accent : view.fg
                font.family: view.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: strings.t("settings.engine.title")
                  color: view.fg
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                BorderSurface {
                  implicitWidth: engineState.implicitWidth + Style.space(10)
                  implicitHeight: engineState.implicitHeight + Style.space(4)
                  radius: height / 2
                  color: view.engineActive
                    ? Style.selectedFillFor(view.fg, view.accent)
                    : "transparent"
                  borderSpec: Border.controlSpec("normal", view.fg, view.accent)

                  Text {
                    id: engineState
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: view.engineStatusText()
                    color: view.engineActive ? view.accent : view.dim
                    font.family: view.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: view.engineActive
                  }
                }
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: view.engineActive
                  ? strings.t("settings.engine.owns")
                  : strings.t("settings.engine.stockDescription")
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Button {
              text: view.engineButtonText()
              iconText: view.engineActive ? "󰑐" : "󰐕"
              bordered: true
              selected: view.engineActive
              hasCursor: view.active(view.idx.installEngine)
              foreground: view.fg
              accent: view.accent
              fontFamily: view.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: {
                view.focus(view.idx.installEngine)
                if (view.store) view.store.installEngine()
              }
            }
          }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.engine.actions")
          description: strings.t("settings.engine.actionsDescription")
          checked: view.store ? view.store.allowExecActions : true
          hasCursor: view.active(view.idx.allowExecActions)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.allowExecActions)
            if (view.store) view.store.setAllowExecActions(!view.store.allowExecActions)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.allowExecActions) }
        }

        Toggle {
          width: parent.width
          label: strings.t("settings.engine.dndBypass")
          description: strings.t("settings.engine.dndBypassDescription")
          checked: view.store ? view.store.dndBypass : true
          hasCursor: view.active(view.idx.dndBypass)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.dndBypass)
            if (view.store) view.store.setDndBypass(!view.store.dndBypass)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.dndBypass) }
        }

        BorderSurface {
          width: parent.width
          implicitHeight: securityNote.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: Style.normalFillFor(view.fg, view.accent)
          borderSpec: Border.controlSpec("normal", view.fg, view.accent)

          RowLayout {
            id: securityNote
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Text {
              Layout.alignment: Qt.AlignTop
              textFormat: Text.PlainText
              text: "󰌾"
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: strings.t("settings.engine.securityNote")
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      // ------------------------------------------------------ bar category
      Column {
        width: parent.width
        visible: view.isCategory("bar")
        spacing: Style.space(8)

        SettingBlock {
          width: parent.width
          label: strings.t("settings.bar.section")
          description: strings.t("settings.bar.sectionDescription")
          active: view.active(view.idx.barSection)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.barSection) }

          SegmentedControl {
            width: parent.width
            options: [
              { value: "left", label: strings.t("settings.bar.left") },
              { value: "center", label: strings.t("settings.bar.center") },
              { value: "right", label: strings.t("settings.bar.right") }
            ]
            value: view.store ? view.store.barSection : ""
            foreground: view.fg
            accent: view.accent
            fontFamily: view.fontFamily
            onChanged: function(v) {
              view.focus(view.idx.barSection)
              if (view.panel) view.panel.moveBarSection(v)
            }
          }
        }

        SettingBlock {
          width: parent.width
          label: strings.t("settings.bar.index")
          description: strings.t("settings.bar.indexDescription")
          active: view.active(view.idx.barIndex)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onHovered: function(h) { if (h) view.focus(view.idx.barIndex) }

          RowLayout {
            width: parent.width
            spacing: Style.space(10)

            PanelSlider {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              bar: view.panel ? view.panel.bar : null
              value: view.store && view.store.barIndex >= 0 ? view.store.barIndex : 0
              minimum: 0
              maximum: view.store && view.store.barSection !== ""
                ? Math.max(0, Number(view.store.barSizes[view.store.barSection] || 1) - 1)
                : 0
              step: 1
              integer: true
              enabled: !!view.store && view.store.barSection !== ""
                && Number(view.store.barSizes[view.store.barSection] || 0) > 1
              trackColor: Style.normalFillFor(view.fg, view.accent)
              fillColor: view.accent
              knobColor: view.fg
              onReleased: function(value) {
                view.focus(view.idx.barIndex)
                if (view.panel && view.store && view.store.barSection !== "")
                  view.panel.moveBar(view.store.barSection, Math.round(value))
              }
            }

            Text {
              Layout.preferredWidth: Style.space(48)
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: view.barPositionText()
              color: view.store && view.store.barSection !== "" ? view.fg : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

      }

      // ----------------------------------------------------- data category
      Column {
        width: parent.width
        visible: view.isCategory("data")
        spacing: Style.space(8)

        Toggle {
          width: parent.width
          label: strings.t("settings.data.confirm")
          description: strings.t("settings.data.confirmDescription")
          checked: view.store ? view.store.confirmClear : true
          hasCursor: view.active(view.idx.confirmClear)
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: {
            view.focus(view.idx.confirmClear)
            if (view.store) view.store.setConfirmClear(!view.store.confirmClear)
          }
          onHovered: function(h) { if (h) view.focus(view.idx.confirmClear) }
        }

        BorderSurface {
          width: parent.width
          implicitHeight: dataCard.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.normalFillFor(view.fg, view.accent)
          borderSpec: Border.controlSpec("normal", view.fg, view.accent)

          ColumnLayout {
            id: dataCard
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: strings.t("settings.data.history")
              color: view.fg
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: view.store
                ? strings.tn("settings.data.historySummary", view.store.entries.length)
                    .arg(Commons.I18n.formatNumber(view.store.entries.length))
                    .arg(Commons.I18n.formatNumber(view.store.archiveRetentionDays))
                : ""
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              Layout.fillWidth: true
              text: view.panel && view.panel.clearArmed
                ? strings.t("settings.data.confirmClear")
                : strings.t("settings.data.clearAll")
              iconText: "󰆴"
              bordered: true
              selected: view.panel && view.panel.clearArmed
              hasCursor: view.active(view.idx.clearHistory)
              foreground: view.urgent
              accent: view.urgent
              fontFamily: view.fontFamily
              fontSize: Style.font.bodySmall
              enabled: view.store && view.store.entries.length > 0
              onClicked: {
                view.focus(view.idx.clearHistory)
                if (view.panel) view.panel.requestClear()
              }
            }

            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: view.panel && view.panel.clearArmed
                ? strings.t("settings.data.pressAgain") : ""
              color: view.urgent
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ----------------------------------------------------- reusable rows

  component SliderSetting: SettingRow {
    id: sliderRow
    property int rowIndex: -1
    property int sliderValue: 0
    property int sliderMin: 0
    property int sliderMax: 64
    property int sliderStep: 4
    signal valueEdited(int value)

    active: view.active(rowIndex)
    onHovered: function(h) { if (h) view.focus(rowIndex) }

    RowLayout {
      width: parent.width
      height: implicitHeight
      spacing: Style.space(8)

      PanelSlider {
        Layout.fillWidth: true
        Layout.minimumWidth: Style.space(100)
        Layout.alignment: Qt.AlignVCenter
        bar: view.panel ? view.panel.bar : null
        value: sliderRow.sliderValue
        minimum: sliderRow.sliderMin
        maximum: sliderRow.sliderMax
        step: sliderRow.sliderStep
        integer: true
        trackColor: Style.normalFillFor(view.fg, view.accent)
        fillColor: view.accent
        knobColor: view.fg
        onReleased: function(value) { sliderRow.valueEdited(Math.round(value)) }
      }

      Text {
        Layout.preferredWidth: Style.space(44)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: strings.t("settings.layout.valuePx")
          .arg(Commons.I18n.formatNumber(sliderRow.sliderValue))
        color: view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  component KeyChoiceRow: SettingBlock {
    id: choiceRow
    property int rowIndex: -1
    property string title: ""
    property var options: []
    property string current: ""
    signal picked(string value)

    label: title
    active: view.active(rowIndex)
    onHovered: function(h) { if (h) view.focus(rowIndex) }

    SegmentedControl {
      width: parent.width
      options: choiceRow.options
      value: choiceRow.current
      foreground: view.fg
      accent: view.accent
      fontFamily: view.fontFamily
      onChanged: function(v) {
        view.focus(choiceRow.rowIndex)
        choiceRow.picked(v)
      }
    }
  }
}
