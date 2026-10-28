import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Notification center panel. Data comes from the files the shell's own
// notification service persists (live popups at the state root, archived
// entries under history/), so the center sees exactly what the toasts do —
// including notifications silenced by Do Not Disturb.
//
// Actions reach the live service through its IPC surface (omarchy-shell):
// dismissal, clear-history and DND toggle, plus a direct rm of the
// per-notification files the service owns.

Panel {
  id: root
  moduleName: "apach.notifications"
  ipcTarget: "apach.notifications"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string hostScreenName: ""
  readonly property var barIdentity: hostWidget || root

  // Data lives in Store.qml so this UI can stay unloaded while the center is
  // closed. Entries/DND/unread below are read-only views of that store.
  property var store: null
  readonly property var entries: store ? store.entries : []
  readonly property bool dnd: store ? store.dnd : false
  readonly property int unseenCount: store ? store.unseenCount : 0

  property var selectedEntry: null
  property bool settingsOpen: false
  // Keyboard cursor: index into entries, or -1 when inactive. The first
  // arrow press activates it; mouse hover moves it too, so mouse and
  // keyboard share one selection like the bluetooth panel does.
  property int cursorIndex: -1
  property string query: ""
  property bool searchOpen: false
  property bool clearArmed: false
  property bool helpOpen: false
  property int settingsCursor: 0
  property int screenCursor: 0
  readonly property int settingsRowCount: 21
  readonly property var screenList: Quickshell.screens
  readonly property var centerScreens: {
    var screens = Quickshell.screens
    var names = root.store ? root.store.screenNames : []
    var out = []
    for (var i = 0; i < screens.length && out.length < 4; i++)
      if (names.indexOf(String(screens[i].name || "")) !== -1) out.push(screens[i])
    if (out.length === 0 && screens.length > 0) out.push(screens[0])
    return out
  }
  property Item activeContent: null

  function activeSearchField() {
    return root.activeContent ? root.activeContent.searchField : null
  }

  function activeScrollView() {
    return root.activeContent ? root.activeContent.scrollView : null
  }

  function focusActiveContent() {
    if (root.activeContent && root.activeContent.keyCatcher)
      root.activeContent.keyCatcher.forceActiveFocus()
  }

  readonly property bool horizontal: root.store ? root.store.mode === "horizontal" : false
  readonly property bool footerVisible: root.store ? root.store.shortcutBar : true

  function keyLabel(value) {
    if (value === "ctrl+f") return "Ctrl+F"
    if (value === "D") return "Shift+D"
    if (value === "I") return "Shift+I"
    if (value === "P") return "Shift+P"
    return String(value || "")
  }

  function shortcutHint() {
    if (root.settingsOpen)
      return "↑↓ / jk move · ←→ / hl adjust · Enter apply · Esc back"
    if (root.helpOpen)
      return "Esc close · " + keyLabel(root.store ? root.store.helpKey : "?") + " toggle help"
    var enter = root.store && root.store.enterOpens === "detail" ? "Enter details" : "Enter open"
    return "↑↓ / jk select · " + enter + " · " + keyLabel(root.store ? root.store.detailKey : "i") + " details · "
      + (root.store ? keyLabel(root.store.searchKey) : "/") + " search · "
      + keyLabel(root.store ? root.store.dndKey : "d") + " DND · "
      + keyLabel(root.store ? root.store.settingsKey : "s") + " settings · "
      + keyLabel(root.store ? root.store.helpKey : "?") + " help"
  }
  // Horizontal cards grow to share the band when there are few, and stop at
  // a readable width; the row centers itself when it does not fill.


  // Filtered view used by the list, the cursor and every keyboard action.
  readonly property var visibleEntries: {
    var q = root.query.trim().toLowerCase()
    if (q === "") return root.entries
    var out = []
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i]
      var hay = (String(e.app) + "\n" + String(e.summary) + "\n" + String(e.body)).toLowerCase()
      if (hay.indexOf(q) !== -1) out.push(e)
    }
    return out
  }

  function previewSource(entry) {
    if (!entry) return ""
    var useImage = !root.store || root.store.showPreviews !== false
    return useImage && entry.image.length > 0 ? entry.image : entry.appIcon
  }

  function dayLabel(ts) {
    var date = new Date(Number(ts) || 0)
    var now = new Date()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
    var diff = Math.round((today - day) / 86400000)
    if (diff === 0) return "Today"
    if (diff === 1) return "Yesterday"
    if (diff > 1 && diff < 7) return Qt.formatDate(date, "dddd")
    return Qt.formatDate(date, "d MMMM yyyy")
  }

  readonly property var groupedEntries: {
    var groups = []
    var current = null
    var label = ""
    for (var i = 0; i < root.visibleEntries.length; i++) {
      var item = root.visibleEntries[i]
      var next = root.dayLabel(item.timestamp)
      if (current === null || next !== label) {
        current = { label: next, entries: [] }
        groups.push(current)
        label = next
      }
      current.entries.push({ entry: item, index: i })
    }
    return groups
  }

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int cornerRadius: Style.cornerRadius

  // Null-safe view for the detail bindings.
  readonly property var entry: root.selectedEntry !== null ? root.selectedEntry : Model.emptyEntry()

  // ---- lifecycle ----

  function open() {
    root.settingsOpen = false
    root.helpOpen = false
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    if (root.store) {
      root.store.reloadState()
      root.store.refresh()
    }
    root.controller.show()
  }

  function close() {
    root.controller.hide()
    root.settingsOpen = false
    root.helpOpen = false
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    root.selectedEntry = null
    root.cursorIndex = -1
    if (root.store) root.store.markSeen()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: {
    if (!root.store) return
    root.store.hostOpen = root.opened
    if (root.store.service && typeof root.store.service.setCenterOpen === "function")
      root.store.service.setCenterOpen(root.opened)
    if (root.opened) root.store.refresh()
  }

  // Entries can change while the list is visible (watcher, poll, dismissal).
  // Keep the keyboard cursor and the detail selection valid.
  Connections {
    target: root.store
    function onEntriesChanged() {
      root.clampCursor()
      if (root.selectedEntry !== null && root.store) {
        var stem = String(root.selectedEntry.stem)
        var found = false
        for (var i = 0; i < root.store.entries.length; i++)
          if (String(root.store.entries[i].stem) === stem) { found = true; break }
        if (!found) root.selectedEntry = null
      }
    }
  }

  // ---- actions (state changes live in Store.qml) ----

  function deleteEntry(entry) {
    if (!entry || !root.store) return
    if (root.selectedEntry && String(root.selectedEntry.stem) === String(entry.stem))
      root.selectedEntry = null
    root.store.deleteEntry(entry)
    // The cursor stays on the same index: the next entry slides into the
    // deleted one's place, like a GNOME-style list.
    root.clampCursor()
  }

  // Dismiss every on-screen toast, then wipe the history the service keeps.
  function clearAll() {
    if (root.store) root.store.clearAll()
    root.selectedEntry = null
    root.cursorIndex = -1
    root.clearArmed = false
  }

  function toggleDnd() {
    if (root.store) root.store.toggleDnd()
  }

  // ---- settings ----

  readonly property string placementVertical: root.store ? root.store.placement.split("-")[0] : "top"
  readonly property string placementHorizontal: root.store ? root.store.placement.split("-")[1] : "right"

  function setPlacement(vertical, horizontal) {
    if (root.store) root.store.setPlacement(vertical + "-" + horizontal)
  }

  function moveBar(section, index) {
    if (!root.store || barMoveProc.running) return
    var target = String(section || "")
    if (["left", "center", "right"].indexOf(target) === -1) return
    var size = Number(root.store.barSizes[target] || 0)
    var at = Math.max(0, Math.min(Math.round(Number(index) || 0), size))
    barMoveProc.command = ["omarchy", "bar", "move", "apach.notifications", "--section", target, "--index", String(at)]
    barMoveProc.running = true
  }

  // A section change appends: least surprising, then the index stepper refines.
  function moveBarSection(section) {
    if (!root.store) return
    root.moveBar(section, Number(root.store.barSizes[section] || 0))
  }

  function stepBarIndex(delta) {
    if (!root.store || root.store.barSection === "") return
    var size = Number(root.store.barSizes[root.store.barSection] || 0)
    var next = Math.max(0, Math.min(root.store.barIndex + delta, Math.max(0, size - 1)))
    root.moveBar(root.store.barSection, next)
  }

  Process {
    id: barMoveProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clicking a card focuses the application that sent the notification. The
  // helper matches Hyprland window classes case-insensitively; archived
  // notifications have no live default action, so focusing the sender is the
  // safe equivalent of "open the notification".
  property var pendingActivation: null

  Process {
    id: focusAppProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var entry = root.pendingActivation
      root.pendingActivation = null
      if (code === 0) {
        root.close()
        return
      }
      if (entry) root.openDetail(entry)
    }
  }

  function activateEntry(entry) {
    if (!entry) return
    var app = String(entry.app || "")
    if (app === "") {
      root.openDetail(entry)
      return
    }
    root.pendingActivation = entry
    focusAppProc.command = ["omarchy-hyprland-focus-app", app]
    focusAppProc.running = true
  }

  function openSettings() {
    if (!root.opened) root.open()
    root.helpOpen = false
    root.selectedEntry = null
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    root.settingsOpen = true
    root.settingsCursor = 0
    root.screenCursor = 0
    var screens = root.screenList
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === root.hostScreenName) {
        root.screenCursor = i
        break
      }
    }
  }

  function moveSettingsCursor(dy) {
    if (dy === 0) return
    root.settingsCursor = (root.settingsCursor + dy + root.settingsRowCount) % root.settingsRowCount
  }

  function cyclePlacement(delta) {
    var list = (root.store && root.store.mode === "vertical")
      ? ["top-left", "top-center", "top-right"]
      : ["top-left", "top-center", "top-right",
         "bottom-left", "bottom-center", "bottom-right",
         "center-center"]
    var index = list.indexOf(root.store ? root.store.placement : "top-right")
    if (index === -1) index = 0
    index = (index + (delta > 0 ? 1 : -1) + list.length) % list.length
    var value = list[index]
    root.setPlacement(value.split("-")[0], value.split("-")[1])
  }

  function clampScreenCursor() {
    var count = root.screenList ? root.screenList.length : 0
    root.screenCursor = count === 0 ? 0 : Math.max(0, Math.min(root.screenCursor, count - 1))
  }

  function cycleScreen(delta) {
    var screens = root.screenList
    if (!screens || screens.length === 0) return
    root.clampScreenCursor()
    root.screenCursor = (root.screenCursor + (delta > 0 ? 1 : -1) + screens.length) % screens.length
  }

  function toggleScreenAtCursor() {
    var screens = root.screenList
    if (!root.store || !screens || screens.length === 0) return
    root.clampScreenCursor()
    var name = String(screens[root.screenCursor].name || "")
    if (name === "") return
    root.store.toggleScreen(name)
  }

  function adjustSettings(delta) {
    if (!root.store || delta === 0) return
    var step = delta > 0 ? 1 : -1
    switch (root.settingsCursor) {
    case 0:
      var modes = ["window", "horizontal", "vertical"]
      var mi = modes.indexOf(root.store.mode)
      root.store.setMode(modes[(mi + step + modes.length) % modes.length])
      break
    case 1: root.store.setMargin("x", root.store.marginX + step * 4); break
    case 2: root.store.setMargin("y", root.store.marginY + step * 4); break
    case 3: root.store.setPadding(root.store.padding + step * 2); break
    case 4: root.store.setCardSpacing(root.store.cardSpacing + step * 2); break
    case 5: root.cyclePlacement(delta); break
    case 7: root.cycleScreen(step); break
    case 8:
      var sections = ["left", "center", "right"]
      var si = sections.indexOf(root.store.barSection)
      if (si === -1) si = 0
      root.moveBarSection(sections[(si + step + sections.length) % sections.length])
      break
    case 9: root.stepBarIndex(step); break
    case 10: root.store.setConfirmClear(root.store.confirmClear ? false : true); break
    case 11: root.store.setHideBodies(!root.store.hideBodies); break
    case 12: root.store.setShowPreviews(!root.store.showPreviews); break
    case 13: root.store.setShowBadge(!root.store.showBadge); break
    case 14: root.store.setEnterOpens(root.store.enterOpens === "app" ? "detail" : "app"); break
    case 15: root.store.setShortcutBar(!root.store.shortcutBar); break
    case 16: root.store.setSearchKey(root.store.searchKey === "ctrl+f" ? "/" : "ctrl+f"); break
    case 17: root.store.setDndKey(root.store.dndKey === "D" ? "d" : "D"); break
    case 18: root.store.setDetailKey(root.store.detailKey === "I" ? "i" : "I"); break
    case 19: root.store.setHelpKey(root.store.helpKey === "F1" ? "?" : "F1"); break
    case 20: root.store.setSettingsKey(root.store.settingsKey === "P" ? "s" : "P"); break
    }
  }

  function activateSettings() {
    if (root.settingsCursor === 6) {
      if (!root.store || root.store.mode !== "vertical") root.setPlacement("center", "center")
      return
    }
    if (root.settingsCursor === 7) {
      root.toggleScreenAtCursor()
      return
    }
    root.adjustSettings(1)
  }

  function closeView() {
    if (root.searchOpen) { root.closeSearch(); return }
    if (root.settingsOpen) { root.settingsOpen = false; return }
    if (root.helpOpen) { root.helpOpen = false; return }
    if (root.selectedEntry !== null) { root.selectedEntry = null; return }
    root.close()
  }

  function toggleHelp() {
    if (root.settingsOpen) return
    root.helpOpen = !root.helpOpen
    root.selectedEntry = null
    root.searchOpen = false
    root.query = ""
    if (root.helpOpen) root.cursorIndex = -1
  }

  function openDetailAtCursor() {
    if (root.cursorIndex < 0 && root.visibleEntries.length > 0) root.cursorIndex = 0
    if (root.cursorIndex >= 0 && root.cursorIndex < root.visibleEntries.length)
      root.openDetail(root.visibleEntries[root.cursorIndex])
  }

  function openSearch() {
    root.searchOpen = true
    root.settingsOpen = false
    root.helpOpen = false
    root.selectedEntry = null
    root.cursorIndex = -1
    root.query = ""
    Qt.callLater(function() {
      var field = root.activeSearchField()
      if (!field) return
      field.text = ""
      field.forceActiveFocus()
    })
  }

  function closeSearch() {
    root.searchOpen = false
    root.query = ""
    root.cursorIndex = -1
    var field = root.activeSearchField()
    if (field) field.text = ""
    Qt.callLater(function() { root.focusActiveContent() })
  }

  function handleClearShortcut() {
    if (root.settingsOpen) return
    if (!root.store || !root.store.confirmClear) {
      root.clearArmed = false
      root.clearAll()
      return
    }
    if (root.clearArmed) {
      root.clearArmed = false
      clearArmTimer.stop()
      root.clearAll()
      return
    }
    root.clearArmed = true
    clearArmTimer.restart()
  }

  Timer {
    id: clearArmTimer
    interval: 3000
    repeat: false
    onTriggered: root.clearArmed = false
  }

  function handleMove(dx, dy) {
    if (root.helpOpen) return
    if (root.settingsOpen) {
      if (dx !== 0) root.adjustSettings(dx)
      else if (dy !== 0) root.moveSettingsCursor(dy)
      return
    }
    if (dy === 0) return
    if (root.selectedEntry !== null) {
      var view = root.activeScrollView()
      if (!view) return
      var maxY = Math.max(0, view.contentHeight - view.height)
      view.contentY = Math.max(0, Math.min(view.contentY + dy * Style.space(60), maxY))
      return
    }
    root.moveCursor(dy)
  }

  function handleActivate() {
    if (root.helpOpen) return
    if (root.settingsOpen) { root.activateSettings(); return }
    if (root.selectedEntry !== null) { root.selectedEntry = null; return }
    if (root.store && root.store.enterOpens === "detail") root.openDetailAtCursor()
    else {
      if (root.cursorIndex < 0 && root.visibleEntries.length > 0) root.cursorIndex = 0
      root.activateCursor()
    }
  }

  function handleDelete(shift) {
    if (root.settingsOpen) return
    if (shift) { root.handleClearShortcut(); return }
    if (root.selectedEntry !== null) root.deleteEntry(root.selectedEntry)
    else root.deleteCursorEntry()
  }

  onSettingsOpenChanged: { var v = root.activeScrollView(); if (v) v.contentY = 0 }
  onSelectedEntryChanged: { var v = root.activeScrollView(); if (v) v.contentY = 0 }
  onQueryChanged: {
    root.cursorIndex = -1
    var v = root.activeScrollView()
    if (v) v.contentY = 0
  }

  // ---- navigation / presentation ----

  function openDetail(entry) { root.selectedEntry = entry }
  function backToList() { root.selectedEntry = null }

  // ---- keyboard cursor ----

  function clampCursor() {
    var n = root.visibleEntries.length
    if (n === 0) root.cursorIndex = -1
    else if (root.cursorIndex >= n) root.cursorIndex = n - 1
  }

  function moveCursor(dy) {
    var n = root.visibleEntries.length
    if (n === 0) return
    if (root.cursorIndex < 0) {
      root.cursorIndex = dy > 0 ? 0 : n - 1
    } else {
      root.cursorIndex = Math.max(0, Math.min(n - 1, root.cursorIndex + dy))
    }
    if (root.activeContent) root.activeContent.scrollCursorIntoView()
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.visibleEntries.length) return
    root.openDetail(root.visibleEntries[root.cursorIndex])
  }

  function deleteCursorEntry() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.visibleEntries.length) return
    root.deleteEntry(root.visibleEntries[root.cursorIndex])
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function bodyText(entry) {
    return Model.styledBody(entry.body, entry.app, entry.appIcon)
  }

  // ======================================================================
  // UI
  // ======================================================================

  // One notification row in the list. The Repeater delegate block below
  // passes its model data in through `entry` (required properties are not
  // injectable into inline components).
 component NotificationRow: BorderSurface {
    id: rowRoot
    property var entry: null
    property int rowIndex: -1
    property bool cursorActive: false

    width: parent ? parent.width : 0
    radius: root.cornerRadius
    // Active card (keyboard cursor) carries the theme's colored notification
    // border; inactive cards get the theme's normal control border. Both are
    // theme tokens — no hardcoded colors.
    color: Commons.Color.notifications.background
    borderSpec: rowRoot.cursorActive
      ? Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
      : Border.controlSpec("normal", Commons.Color.notifications.text, Commons.Color.accent)
    clip: true

    readonly property color cardText: Commons.Color.notifications.text
    readonly property color dimColor: Qt.darker(cardText, 1.5)
    readonly property color bodyColor: Qt.darker(cardText, 1.15)

    implicitHeight: rowLayout.implicitHeight + borderTop + borderBottom

    HoverHandler {
      id: rowHover
      // Mouse and keyboard share one selection: hovering a row moves the
      // cursor onto it, so a later Del/Enter acts on what's under the mouse.
      onHoveredChanged: if (rowHover.hovered) root.cursorIndex = rowRoot.rowIndex
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.deleteEntry(rowRoot.entry)
        else root.activateEntry(rowRoot.entry)
      }
    }

    RowLayout {
      id: rowLayout
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: rowRoot.borderTop
      anchors.leftMargin: rowRoot.borderLeft
      // Reserve the dismiss button's corner so the relative time never
      // renders underneath it.
      anchors.rightMargin: rowRoot.borderRight + Style.space(52)
      anchors.bottomMargin: rowRoot.borderBottom
      spacing: Style.space(10)

      // App icon, with the glyph fallback the toasts use when there is no
      // resolvable icon.
      Item {
        id: iconSlot
        Layout.preferredWidth: Style.space(36)
        Layout.preferredHeight: Style.space(36)
        Layout.leftMargin: Style.space(10)
        Layout.topMargin: Style.space(10)
        Layout.alignment: Qt.AlignTop

        property bool imageFailed: false
        readonly property string source: root.iconSource(root.previewSource(rowRoot.entry))
        readonly property bool showGlyph: (source === "" || imageFailed) && rowRoot.entry.glyph.length > 0

        Image {
          anchors.fill: parent
          visible: !iconSlot.showGlyph
          source: iconSlot.source
          sourceSize.width: iconSlot.width * Screen.devicePixelRatio
          sourceSize.height: iconSlot.height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          onStatusChanged: iconSlot.imageFailed = (status === Image.Error)
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          visible: iconSlot.showGlyph
          text: rowRoot.entry.glyph
          color: rowRoot.cardText
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(9)
        Layout.bottomMargin: Style.space(9)
        Layout.rightMargin: Style.space(10)
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: rowRoot.entry.app.length > 0 ? rowRoot.entry.app : "Notification"
            color: rowRoot.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: Model.timeAgo(rowRoot.entry.timestamp, Date.now())
            color: rowRoot.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          visible: rowRoot.entry.summary.length > 0
          text: rowRoot.entry.summary
          color: rowRoot.cardText
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 2
        }

        Text {
          Layout.fillWidth: true
          visible: rowRoot.entry.body.length > 0 && (!root.store || !root.store.hideBodies)
          text: root.bodyText(rowRoot.entry)
          textFormat: Text.StyledText
          color: rowRoot.bodyColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 3
        }
      }
    }

    // Hover actions: open the detail card, or dismiss the notification.
    PanelActionButton {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(5)
      anchors.rightMargin: Style.space(31)
      visible: rowHover.hovered
      iconText: "󰋼"
      tooltipText: "Details"
      foreground: rowRoot.cardText
      hoverColor: Commons.Color.accent
      fontFamily: root.fontFamily
      onClicked: root.openDetail(rowRoot.entry)
    }

    PanelActionButton {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(5)
      anchors.rightMargin: Style.space(5)
      visible: rowHover.hovered
      iconText: "󰆴"
      tooltipText: "Remove"
      foreground: rowRoot.cardText
      hoverColor: Commons.Color.urgent
      fontFamily: root.fontFamily
      onClicked: root.deleteEntry(rowRoot.entry)
    }
  }

  // Side-by-side card for the horizontal band. Fixed width keeps the strip
  // tidy; the body is clamped to two lines.
  component CompactCard: BorderSurface {
    id: compactRoot
    property var entry: null
    property int rowIndex: -1
    property bool cursorActive: false

    width: Style.space(280)
    height: Style.space(88)
    radius: root.cornerRadius
    color: Commons.Color.notifications.background
    borderSpec: compactRoot.cursorActive
      ? Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
      : Border.controlSpec("normal", Commons.Color.notifications.text, Commons.Color.accent)
    clip: true

    readonly property color cardText: Commons.Color.notifications.text
    readonly property color dimColor: Qt.darker(cardText, 1.5)
    readonly property color bodyColor: Qt.darker(cardText, 1.15)

    HoverHandler {
      id: compactHover
      onHoveredChanged: if (compactHover.hovered) root.cursorIndex = compactRoot.rowIndex
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.deleteEntry(compactRoot.entry)
        else root.activateEntry(compactRoot.entry)
      }
    }

    RowLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      anchors.rightMargin: Style.space(50)
      spacing: Style.space(8)

      Item {
        Layout.preferredWidth: Style.space(26)
        Layout.preferredHeight: Style.space(26)
        Layout.alignment: Qt.AlignTop

        property bool imageFailed: false
        readonly property string source: root.iconSource(root.previewSource(compactRoot.entry))
        readonly property bool showGlyph: (source === "" || imageFailed) && compactRoot.entry.glyph.length > 0

        Image {
          anchors.fill: parent
          visible: !parent.showGlyph
          source: parent.source
          sourceSize.width: parent.width * Screen.devicePixelRatio
          sourceSize.height: parent.height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          onStatusChanged: parent.imageFailed = (status === Image.Error)
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          visible: parent.showGlyph
          text: compactRoot.entry.glyph
          color: compactRoot.cardText
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
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
            text: compactRoot.entry.app.length > 0 ? compactRoot.entry.app : "Notification"
            color: compactRoot.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: Model.timeAgo(compactRoot.entry.timestamp, Date.now())
            color: compactRoot.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          visible: compactRoot.entry.summary.length > 0
          text: compactRoot.entry.summary
          color: compactRoot.cardText
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        Text {
          Layout.fillWidth: true
          visible: compactRoot.entry.body.length > 0 && (!root.store || !root.store.hideBodies)
          text: root.bodyText(compactRoot.entry)
          textFormat: Text.StyledText
          color: compactRoot.bodyColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 2
        }
      }
    }

    PanelActionButton {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      anchors.rightMargin: Style.space(29)
      visible: compactHover.hovered
      iconText: "󰋼"
      tooltipText: "Details"
      foreground: compactRoot.cardText
      hoverColor: Commons.Color.accent
      fontFamily: root.fontFamily
      onClicked: root.openDetail(compactRoot.entry)
    }

    PanelActionButton {
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      anchors.rightMargin: Style.space(5)
      visible: compactHover.hovered
      iconText: "󰆴"
      tooltipText: "Remove"
      foreground: compactRoot.cardText
      hoverColor: Commons.Color.urgent
      fontFamily: root.fontFamily
      onClicked: root.deleteEntry(compactRoot.entry)
    }
  }

  component StepperRow: RowLayout {
    id: stepper
    property string label: ""
    property int value: 0
    property int minimum: 0
    property int maximum: 64
    property int stepSize: 4
    signal step(int delta)

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Item { Layout.fillWidth: true; implicitHeight: 1 }

    Text {
      text: stepper.label
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.preferredWidth: Style.space(108)
      elide: Text.ElideRight
    }

    PanelActionButton {
      iconText: "−"
      tooltipText: "Decrease"
      focusable: true
      foreground: root.fg
      hoverColor: Commons.Color.accent
      fontFamily: root.fontFamily
      enabled: stepper.value > stepper.minimum
      onClicked: stepper.step(-stepper.stepSize)
    }

    Text {
      text: stepper.value + " px"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(46)
    }

    PanelActionButton {
      iconText: "+"
      tooltipText: "Increase"
      focusable: true
      foreground: root.fg
      hoverColor: Commons.Color.accent
      fontFamily: root.fontFamily
      enabled: stepper.value < stepper.maximum
      onClicked: stepper.step(stepper.stepSize)
    }

    Item { Layout.fillWidth: true; implicitHeight: 1 }
  }



  component CursorRow: Item {
    id: cursorRow
    property bool active: false
    default property alias content: inner.children

    width: parent ? parent.width : 0
    height: inner.childrenRect.height + Style.space(8)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: cursorRow.active ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
      Behavior on color { ColorAnimation { duration: 100 } }
    }

    Item {
      id: inner
      anchors.fill: parent
      anchors.margins: Style.space(4)
    }
  }

  component SettingsDivider: Item {
    width: parent ? parent.width : 0
    height: Style.space(23)

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width, Style.space(380))
      height: 1
      color: Qt.darker(root.fg, 2.6)
      opacity: 0.8
    }
  }

  component LayoutSettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "LAYOUT"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)


                Item {
                  width: parent.width
                  height: layoutRow.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 0 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Row {
                    id: layoutRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(6)

                    Button {
                      id: settingsFirstControl
                      text: "Window"
                      Layout.preferredWidth: Style.space(80)
                      focusable: true
                      selected: root.store !== null && root.store.mode === "window"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: if (root.store) root.store.setMode("window")
                    }

                    Button {
                      text: "Horizontal"
                      Layout.preferredWidth: Style.space(80)
                      focusable: true
                      selected: root.store !== null && root.store.mode === "horizontal"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: if (root.store) root.store.setMode("horizontal")
                    }

                    Button {
                      text: "Vertical"
                      Layout.preferredWidth: Style.space(80)
                      focusable: true
                      selected: root.store !== null && root.store.mode === "vertical"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: if (root.store) root.store.setMode("vertical")
                    }
                  }
                }
    }
  }

  component SpacingSettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "SPACING"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)


                CursorRow {
                  active: root.settingsCursor === 1

                  StepperRow {
                  label: "Horizontal"
                  value: root.store ? root.store.marginX : 12
                  onStep: function(delta) { if (root.store) root.store.setMargin("x", value + delta) }
                }
                }

                CursorRow {
                  active: root.settingsCursor === 2

                  StepperRow {
                  label: "Vertical"
                  value: root.store ? root.store.marginY : 12
                  onStep: function(delta) { if (root.store) root.store.setMargin("y", value + delta) }
                }
                }

                CursorRow {
                  active: root.settingsCursor === 3

                  StepperRow {
                  label: "Padding"
                  value: root.store ? root.store.padding : 12
                  minimum: 4
                  maximum: 32
                  stepSize: 2
                  onStep: function(delta) { if (root.store) root.store.setPadding(value + delta) }
                }
                }

                CursorRow {
                  active: root.settingsCursor === 4

                  StepperRow {
                  label: "Card spacing"
                  value: root.store ? root.store.cardSpacing : 10
                  minimum: 2
                  maximum: 24
                  stepSize: 2
                  onStep: function(delta) { if (root.store) root.store.setCardSpacing(value + delta) }
                }
                }
    }
  }

  component PositionSettings: Column {
    id: positionSection
    readonly property bool verticalMode: root.store !== null && root.store.mode === "vertical"

    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "POSITION"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)


                Item {
                  width: parent.width
                  height: positionGrid.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 5 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  GridLayout {
                    id: positionGrid
                    anchors.horizontalCenter: parent.horizontalCenter
                    columns: 4
                    columnSpacing: Style.space(6)
                    rowSpacing: Style.space(6)

                    Text {
                      text: "Top"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      Layout.preferredWidth: Style.space(36)
                    }

                    Button {
                      text: "Left"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.placementVertical === "top" && root.placementHorizontal === "left"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("top", "left")
                    }

                    Button {
                      text: "Center"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.placementVertical === "top" && root.placementHorizontal === "center"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("top", "center")
                    }

                    Button {
                      text: "Right"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.placementVertical === "top" && root.placementHorizontal === "right"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("top", "right")
                    }

                    Text {
                      text: "Bottom"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      Layout.preferredWidth: Style.space(36)
                      opacity: positionSection.verticalMode ? 0.4 : 1
                    }

                    Button {
                      text: "Left"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      enabled: !positionSection.verticalMode
                      opacity: positionSection.verticalMode ? 0.4 : 1
                      selected: root.placementVertical === "bottom" && root.placementHorizontal === "left"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("bottom", "left")
                    }

                    Button {
                      text: "Center"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      enabled: !positionSection.verticalMode
                      opacity: positionSection.verticalMode ? 0.4 : 1
                      selected: root.placementVertical === "bottom" && root.placementHorizontal === "center"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("bottom", "center")
                    }

                    Button {
                      text: "Right"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      enabled: !positionSection.verticalMode
                      opacity: positionSection.verticalMode ? 0.4 : 1
                      selected: root.placementVertical === "bottom" && root.placementHorizontal === "right"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.setPlacement("bottom", "right")
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: centerScreenButton.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 6 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Button {
                    id: centerScreenButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Center Screen"
                    enabled: !positionSection.verticalMode
                    opacity: positionSection.verticalMode ? 0.4 : 1
                    Layout.preferredWidth: Style.space(140)
                    focusable: true
                    selected: root.store !== null && root.store.placement === "center-center"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    fontFamily: root.fontFamily
                    foreground: root.fg
                    onClicked: root.setPlacement("center", "center")
                  }
                }

                Item {
                  width: parent.width
                  height: screenFlow.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 7 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }

                  Flow {
                    id: screenFlow
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      text: "Screen"
                      width: Style.space(52)
                      height: Style.space(28)
                      verticalAlignment: Text.AlignVCenter
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Repeater {
                      model: root.screenList

                      delegate: Button {
                        readonly property bool selectedScreen: root.store !== null
                          && root.store.screenNames.indexOf(String(modelData.name || "")) !== -1
                        text: (root.settingsCursor === 7 && root.screenCursor === index ? "› " : "")
                          + (selectedScreen ? "✓ " : "")
                          + String(modelData.name || "")
                        focusable: true
                        selected: selectedScreen
                        bordered: true
                        fontSize: Style.font.bodySmall
                        fontFamily: root.fontFamily
                        foreground: root.fg
                        onClicked: {
                          if (!root.store) return
                          root.screenCursor = index
                          root.store.toggleScreen(String(modelData.name || ""))
                        }
                      }
                    }
                  }
                }
    }
  }

  component BarIconSettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "BAR ICONS"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)


                Item {
                  width: parent.width
                  height: barSectionRow.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 8 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Row {
                    id: barSectionRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(6)

                    Button {
                      text: "Left"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.store !== null && root.store.barSection === "left"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.moveBarSection("left")
                    }

                    Button {
                      text: "Center"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.store !== null && root.store.barSection === "center"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.moveBarSection("center")
                    }

                    Button {
                      text: "Right"
                      Layout.preferredWidth: Style.space(86)
                      focusable: true
                      selected: root.store !== null && root.store.barSection === "right"
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: root.moveBarSection("right")
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: barIndexRow.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 9 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Row {
                    id: barIndexRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(6)

                    Text {
                      text: "Position"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    PanelActionButton {
                      iconText: "‹"
                      tooltipText: "Move earlier"
                      focusable: true
                      foreground: root.fg
                      hoverColor: Commons.Color.accent
                      fontFamily: root.fontFamily
                      enabled: root.store !== null && root.store.barSection !== "" && root.store.barIndex > 0
                      onClicked: root.stepBarIndex(-1)
                    }

                    Text {
                      text: !root.store || root.store.barSection === ""
                        ? "—"
                        : (root.store.barIndex + 1) + " / " + (root.store.barSizes[root.store.barSection] || 0)
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      horizontalAlignment: Text.AlignHCenter
                      Layout.preferredWidth: Style.space(52)
                    }

                    PanelActionButton {
                      iconText: "›"
                      tooltipText: "Move later"
                      focusable: true
                      foreground: root.fg
                      hoverColor: Commons.Color.accent
                      fontFamily: root.fontFamily
                      enabled: root.store !== null && root.store.barSection !== ""
                        && root.store.barIndex < (root.store.barSizes[root.store.barSection] || 0) - 1
                      onClicked: root.stepBarIndex(1)
                    }
                  }
                }
    }
  }

  component ClearSettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "CLEAR"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)


                Item {
                  width: parent.width
                  height: confirmRow.implicitHeight

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.settingsCursor === 10 ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }


                  Row {
                    id: confirmRow
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(6)

                    Text {
                      text: "Confirmation"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      width: Style.space(110)
                      elide: Text.ElideRight
                    }

                    Button {
                      text: "Off"
                      Layout.preferredWidth: Style.space(64)
                      focusable: true
                      selected: root.store !== null && !root.store.confirmClear
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: if (root.store) root.store.setConfirmClear(false)
                    }

                    Button {
                      text: "On"
                      Layout.preferredWidth: Style.space(64)
                      focusable: true
                      selected: root.store !== null && root.store.confirmClear
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.fontFamily
                      foreground: root.fg
                      onClicked: if (root.store) root.store.setConfirmClear(true)
                    }
                  }
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: "30 days of history · / search · d Do Not Disturb · Shift+C clear"
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: "Placement applies to this screen. Bar moves take effect immediately."
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
    }
  }


  component PrivacySettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "PRIVACY"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)

      CursorRow {
        active: root.settingsCursor === 11

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Bodies"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "Show"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && !root.store.hideBodies
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setHideBodies(false)
          }

          Button {
            text: "Hide"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.hideBodies
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setHideBodies(true)
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 12

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Previews"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "Show"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.showPreviews
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShowPreviews(true)
          }

          Button {
            text: "Hide"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && !root.store.showPreviews
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShowPreviews(false)
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 13

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Unread badge"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "On"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.showBadge
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShowBadge(true)
          }

          Button {
            text: "Off"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && !root.store.showBadge
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShowBadge(false)
          }
        }
      }
    }
  }

  component ShortcutSettings: Column {
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: sectionTitle.implicitHeight

      PanelSectionHeader {
        id: sectionTitle
        anchors.horizontalCenter: parent.horizontalCenter
        text: "SHORTCUTS"
        foreground: root.fg
        fontFamily: root.fontFamily
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(7)

      CursorRow {
        active: root.settingsCursor === 14

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Enter"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "Open app"
            Layout.preferredWidth: Style.space(86)
            focusable: true
            selected: root.store !== null && root.store.enterOpens === "app"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setEnterOpens("app")
          }

          Button {
            text: "Details"
            Layout.preferredWidth: Style.space(72)
            focusable: true
            selected: root.store !== null && root.store.enterOpens === "detail"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setEnterOpens("detail")
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 15

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Hint bar"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "On"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.shortcutBar
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShortcutBar(true)
          }

          Button {
            text: "Off"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && !root.store.shortcutBar
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setShortcutBar(false)
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 16

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Search"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "/"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.searchKey === "/"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setSearchKey("/")
          }

          Button {
            text: "Ctrl+F"
            Layout.preferredWidth: Style.space(70)
            focusable: true
            selected: root.store !== null && root.store.searchKey === "ctrl+f"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setSearchKey("ctrl+f")
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 17

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "DND"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "d"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.dndKey === "d"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setDndKey("d")
          }

          Button {
            text: "D"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.dndKey === "D"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setDndKey("D")
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 18

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Details"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "i"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.detailKey === "i"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setDetailKey("i")
          }

          Button {
            text: "I"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.detailKey === "I"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setDetailKey("I")
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 19

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Help"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "?"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.helpKey === "?"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setHelpKey("?")
          }

          Button {
            text: "F1"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.helpKey === "F1"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setHelpKey("F1")
          }
        }
      }

      CursorRow {
        active: root.settingsCursor === 20

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            text: "Settings"
            width: Style.space(100)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "s"
            Layout.preferredWidth: Style.space(64)
            focusable: true
            selected: root.store !== null && root.store.settingsKey === "s"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setSettingsKey("s")
          }

          Button {
            text: "Shift+P"
            Layout.preferredWidth: Style.space(78)
            focusable: true
            selected: root.store !== null && root.store.settingsKey === "P"
            bordered: true
            fontSize: Style.font.bodySmall
            fontFamily: root.fontFamily
            foreground: root.fg
            onClicked: if (root.store) root.store.setSettingsKey("P")
          }
        }
      }
    }
  }


  onScreenListChanged: root.clampScreenCursor()

  Variants {
    model: root.centerScreens

    CenterWindow {
      id: centerWindow
      required property var modelData
      screenName: String(modelData.name || "")
      anchorItem: root.anchorItem
      bar: root.bar
      owner: root
      open: root.opened
      isPrimary: root.centerScreens.length > 0
        && String(modelData.name || "") === String(root.centerScreens[0].name || "")
      mode: root.store ? root.store.mode : "window"
      placement: root.store ? root.store.placement : "top-right"
      marginX: root.store ? root.store.marginX : 12
      marginY: root.store ? root.store.marginY : 12
      padding: root.store ? root.store.padding : 12
      desiredWidth: {
        if (!root.horizontal) return Style.space(430)
        var spacing = root.store ? root.store.cardSpacing : 10
        var count = root.visibleEntries.length
        var cards = count > 0 ? count * Style.space(280) + (count - 1) * spacing : 0
        var content = Math.max(Style.space(480), cards)
        if (root.settingsOpen) content = Math.max(content, Style.space(920))
        else if (root.selectedEntry !== null) content = Math.max(content, Style.space(760))
        return content
      }
      desiredHeight: (contentLoader.item ? contentLoader.item.activeContentHeight : 0)
        + (root.footerVisible && contentLoader.item ? contentLoader.item.footerHeight : 0)
        + (root.settingsOpen ? Style.space(16) : 0)
      focusTarget: contentLoader.item ? contentLoader.item.keyCatcher : null

      Loader {
        id: contentLoader
        anchors.fill: parent
        sourceComponent: centerContentComponent
        onLoaded: {
          if (!item) return
          item.cardWidth = Qt.binding(function() { return centerWindow.cardW })
          if (centerWindow.isPrimary)
            root.activeContent = item
          if (centerWindow.open)
            item.keyCatcher.forceActiveFocus()
        }
      }

      onOpenChanged: {
        if (open && (isPrimary || hostFocused)) root.activeContent = contentLoader.item
      }
      onHostFocusedChanged: {
        if (open && hostFocused) root.activeContent = contentLoader.item
      }
    }
  }

  Component {
    id: centerContentComponent
    Item {
      id: contentRoot
      property alias keyCatcher: keyCatcher
      property alias searchField: searchField
      property alias scrollView: scrollView
      property real cardWidth: 430
      readonly property real footerHeight: shortcutFooter.height
      readonly property real activeContentHeight: {
        var h = headerRow.height + headerSeparator.height
        var count = 2
        if (root.searchOpen) { h += searchField.height; count++ }
        if (root.clearArmed) { h += clearBanner.height; count++ }
        var view = root.helpOpen ? helpColumn
          : (root.settingsOpen ? settingsColumn
          : (root.selectedEntry !== null ? detailColumn : listSection))
        if (view) h += view.implicitHeight
        count++
        return h + Style.space(10) * (count - 1)
      }

      // Keep the cursor's row visible without fighting normal scrolling: only
      // nudge the Flickable when the row would otherwise sit outside the view.
      function scrollCursorIntoView() {
        if (root.cursorIndex < 0) return
        if (root.horizontal) {
          var card = null
          for (var c = 0; c < bandRow.children.length; c++) {
            var candidate = bandRow.children[c]
            if (candidate && candidate.rowIndex !== undefined && candidate.rowIndex === root.cursorIndex) {
              card = candidate
              break
            }
          }
          if (!card) return
          var hmargin = Style.space(16)
          var left = bandScroll.contentX + hmargin
          var right = bandScroll.contentX + bandScroll.width - hmargin
          if (card.x >= left && card.x + card.width <= right) return
          var maxX = Math.max(0, bandScroll.contentWidth - bandScroll.width)
          if (card.x < left) bandScroll.contentX = Math.max(0, card.x - hmargin)
          else bandScroll.contentX = Math.min(maxX, card.x + card.width - bandScroll.width + hmargin)
          return
        }
        if (!listRows) return
        var row = null
        var groupY = 0
        for (var g = 0; g < listRows.children.length; g++) {
          var group = listRows.children[g]
          if (!group) continue
          for (var i = 0; i < group.children.length; i++) {
            var child = group.children[i]
            if (child && child.rowIndex !== undefined && child.rowIndex === root.cursorIndex) {
              row = child
              groupY = group.y
              break
            }
          }
          if (row) break
        }
        if (!row) return

        var margin = Style.space(24)
        var rowY = listRows.y + groupY + row.y
        var top = scrollView.contentY + margin
        var bottom = scrollView.contentY + scrollView.height - margin
        if (rowY >= top && rowY + row.height <= bottom) return

        var maxY = Math.max(0, scrollView.contentHeight - scrollView.height)
        if (rowY < top) scrollView.contentY = Math.max(0, rowY - margin)
        else scrollView.contentY = Math.min(maxY, rowY + row.height - scrollView.height + margin)
      }

      anchors.fill: parent

      // Del / Shift+Del are not covered by PanelKeyCatcher.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Delete) {
          event.accepted = true
          root.handleDelete((event.modifiers & Qt.ShiftModifier) !== 0)
          return
        }
        if (root.searchOpen || root.settingsOpen) return
        if (event.key === Qt.Key_F1 && root.store && root.store.helpKey === "F1") {
          root.toggleHelp(); event.accepted = true; return
        }
        if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)
            && root.store && root.store.searchKey === "ctrl+f") {
          root.openSearch(); event.accepted = true; return
        }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: searchField.activeFocus
        onActiveFocusChanged: if (activeFocus) root.activeContent = contentRoot
        onCloseRequested: { root.activeContent = contentRoot; root.closeView() }
        onTabRequested: function(direction) {
          root.activeContent = contentRoot
          root.close()
          root.switchPanel(direction)
        }
        onMoveRequested: function(dx, dy) {
          root.activeContent = contentRoot
          root.handleMove(dx, dy)
        }
        onActivateRequested: { root.activeContent = contentRoot; root.handleActivate() }
        onDeleteRequested: { root.activeContent = contentRoot; root.handleDelete(false) }
        onTextKey: function(t) {
          root.activeContent = contentRoot
          if (root.searchOpen || root.settingsOpen) return
          if (root.helpOpen) {
            if (t === root.store.helpKey) root.toggleHelp()
            return
          }
          if (t === root.store.dndKey) root.toggleDnd()
          else if (t === root.store.detailKey) root.openDetailAtCursor()
          else if (t === root.store.helpKey) root.toggleHelp()
          else if (t === root.store.searchKey) root.openSearch()
          else if (t === root.store.settingsKey) root.openSettings()
          else if (t === "g") { root.cursorIndex = root.visibleEntries.length > 0 ? 0 : -1; contentRoot.scrollCursorIntoView() }
          else if (t === "G") { root.cursorIndex = root.visibleEntries.length - 1; contentRoot.scrollCursorIntoView() }
          else if (t === "C") root.handleClearShortcut()
        }

        Flickable {
          id: scrollView
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: parent.height - (shortcutFooter.visible ? shortcutFooter.height : 0)
          contentWidth: width
          contentHeight: contentRoot.activeContentHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: contentColumn
            width: scrollView.width - Style.space(10)
            spacing: Style.space(10)

            Item {
              id: headerRow
              width: parent.width
              height: Math.max(headerTitle.implicitHeight, headerActions.implicitHeight)

              PanelSectionHeader {
                id: headerTitle
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                text: root.settingsOpen
                  ? "SETTINGS"
                  : (root.helpOpen ? "SHORTCUTS"
                    : (root.selectedEntry !== null ? "NOTIFICATION" : "NOTIFICATIONS"))
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Row {
                id: headerActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry === null
                  iconText: "󰍉"
                  tooltipText: "Search (/)"
                  foreground: root.fg
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openSearch()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                  iconText: "󰒓"
                  tooltipText: "Settings (" + root.keyLabel(root.store ? root.store.settingsKey : "s") + ")"
                  foreground: root.fg
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openSettings()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                  iconText: root.dnd ? "󰂜" : "󰂛"
                  tooltipText: root.dnd ? "Allow notifications" : "Silence notifications"
                  foreground: root.dnd ? Commons.Color.accent : Qt.darker(root.fg, 1.5)
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.toggleDnd()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry === null
                  iconText: "󰆴"
                  tooltipText: "Clear all"
                  foreground: root.fg
                  hoverColor: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  enabled: root.entries.length > 0
                  onClicked: root.clearAll()
                }

                PanelActionButton {
                  visible: root.settingsOpen || root.helpOpen || root.selectedEntry !== null
                  iconText: "󰅁"
                  tooltipText: "Back"
                  foreground: root.fg
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.closeView()
                }
              }
            }

            PanelSeparator {
              id: headerSeparator
              foreground: root.fg
              width: parent.width
            }

            TextField {
              id: searchField
              width: parent.width
              visible: root.searchOpen
              placeholderText: "Search app, title or body"
              foreground: root.fg
              accent: Commons.Color.accent
              font.pixelSize: Style.font.bodySmall
              hasCursor: true
              onTextChanged: root.query = text
              Keys.onEscapePressed: root.closeSearch()
              Keys.onReturnPressed: {
                keyCatcher.forceActiveFocus()
                if (root.cursorIndex < 0 && root.visibleEntries.length > 0) root.cursorIndex = 0
                root.activateCursor()
              }
              Keys.onDownPressed: {
                keyCatcher.forceActiveFocus()
                root.moveCursor(1)
              }
              Keys.onUpPressed: {
                keyCatcher.forceActiveFocus()
                root.moveCursor(-1)
              }
            }

            Text {
              id: clearBanner
              visible: root.clearArmed
              width: parent.width
              textFormat: Text.PlainText
              text: "Press Shift+C again to clear all notifications"
              color: Commons.Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // ---- shortcuts help ----
            Column {
              id: helpColumn
              visible: root.helpOpen
              width: Math.min(parent.width, Style.space(460))
              x: Math.max(0, (parent.width - width) / 2)
              spacing: Style.space(10)

              GridLayout {
                width: parent.width
                columns: 2
                columnSpacing: Style.space(18)
                rowSpacing: Style.space(6)

                Text { text: "↑↓ / jk"; color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Select a notification"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: "Enter"; color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: root.store && root.store.enterOpens === "detail" ? "Open the detail card" : "Focus the sending app"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: root.keyLabel(root.store ? root.store.detailKey : "i"); color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Open the detail card"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: root.keyLabel(root.store ? root.store.searchKey : "/"); color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Search app, title and body"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: root.keyLabel(root.store ? root.store.settingsKey : "s"); color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Open settings"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: root.keyLabel(root.store ? root.store.dndKey : "d"); color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Toggle Do Not Disturb"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: root.keyLabel(root.store ? root.store.helpKey : "?"); color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Show or hide this help"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: "g / G"; color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "First / last notification"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: "Shift+C"; color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Clear all (twice unless disabled)"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

                Text { text: "Esc"; color: Commons.Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { Layout.fillWidth: true; text: "Back, then close the center"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
              }
            }

            // ---- list ----
            Column {
              id: listSection
              width: parent.width
              spacing: root.store ? root.store.cardSpacing : 10
              visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry === null

              // Empty state.
              Column {
                visible: root.visibleEntries.length === 0
                width: parent.width
                spacing: Style.space(6)
                topPadding: Style.space(26)
                bottomPadding: Style.space(26)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "󰂚"
                  color: Qt.darker(root.fg, 1.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.query !== "" && root.entries.length > 0 ? "No matches" : "No notifications"
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              // Stacked cards for the floating window and the vertical band.
              Column {
                id: listRows
                width: parent.width
                visible: !root.horizontal
                spacing: root.store ? root.store.cardSpacing : 10

                Repeater {
                  model: root.groupedEntries

                  delegate: Column {
                    required property var modelData
                    width: listRows.width
                    spacing: Style.space(6)

                    Text {
                      visible: modelData.label !== ""
                      text: modelData.label
                      color: Qt.darker(root.fg, 1.7)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      leftPadding: Style.space(2)
                    }

                    Repeater {
                      model: modelData.entries

                      delegate: NotificationRow {
                        required property var modelData
                        entry: modelData.entry
                        rowIndex: modelData.index
                        cursorActive: root.cursorIndex === modelData.index
                      }
                    }
                  }
                }
              }

              // Side-by-side cards for the horizontal band.
              Item {
                width: parent.width
                height: bandRow.height + (bandScroll.contentWidth > bandScroll.width
                  ? (root.store ? root.store.padding : 12) + Style.space(8) : 0)
                visible: root.horizontal

                Flickable {
                  id: bandScroll
                  width: parent.width
                  height: bandRow.height
                  contentWidth: Math.max(width, bandRow.x + bandRow.implicitWidth)
                  contentHeight: height
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  interactive: contentWidth > width

                  Row {
                    id: bandRow
                    x: Math.max(0, (bandScroll.width - implicitWidth) / 2)
                    spacing: root.store ? root.store.cardSpacing : 10

                    Repeater {
                      model: root.visibleEntries

                      delegate: CompactCard {
                        required property var modelData
                        required property int index
                        entry: modelData
                        rowIndex: index
                        cursorActive: root.cursorIndex === index
                      }
                    }
                  }
                }

                Item {
                  id: hScroll
                  visible: bandScroll.contentWidth > bandScroll.width
                  anchors.left: parent.left
                  anchors.right: parent.right
                  // Same inset as the cards have from the outer frame.
                  y: bandRow.height + (root.store ? root.store.padding : 12)
                  height: Style.space(8)

                  Rectangle {
                    id: hThumb
                    height: Style.space(4)
                    radius: height / 2
                    color: Commons.Color.accent
                    opacity: hDrag.pressed ? 0.95 : 0.55
                    width: Math.max(Style.space(28), hScroll.width * hScroll.width / Math.max(1, bandScroll.contentWidth))
                    x: {
                      var max = Math.max(1, bandScroll.contentWidth - bandScroll.width)
                      return (bandScroll.contentX / max) * Math.max(0, hScroll.width - width)
                    }
                  }

                  MouseArea {
                    id: hDrag
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onPressed: function(mouse) { hScroll.jump(mouse.x) }
                    onPositionChanged: function(mouse) { if (pressed) hScroll.jump(mouse.x) }
                  }

                  function jump(px) {
                    var max = Math.max(0, bandScroll.contentWidth - bandScroll.width)
                    var span = Math.max(1, hScroll.width - hThumb.width)
                    bandScroll.contentX = Math.max(0, Math.min(1, (px - hThumb.width / 2) / span)) * max
                  }
                }
              }
            }

            // ---- detail ----
            Column {
              id: detailColumn
              width: Math.min(parent.width, root.horizontal ? Style.space(760) : Style.space(560))
              x: Math.max(0, (parent.width - width) / 2)
              spacing: Style.space(10)
              visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry !== null

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.entry.app.length > 0 ? root.entry.app : "Notification"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: Qt.formatDateTime(new Date(root.entry.timestamp), "ddd d MMM yyyy · HH:mm")
                    color: Qt.darker(root.fg, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  iconText: "󰆴"
                  tooltipText: "Remove"
                  foreground: root.fg
                  hoverColor: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.deleteEntry(root.entry)
                }
              }

              // The dedicated detail card: full summary, full body, image when
              // the notification carries one.
              BorderSurface {
                id: detailCard
                width: parent.width
                radius: root.cornerRadius
                color: Commons.Color.notifications.background
                borderSpec: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
                clip: true
                // Anchored content does not size a Rectangle implicitly — the
                // card must carry its own height like the list rows do.
                implicitHeight: detailContent.implicitHeight + borderTop + borderBottom

                ColumnLayout {
                  id: detailContent
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: detailCard.borderTop
                  anchors.leftMargin: detailCard.borderLeft
                  anchors.rightMargin: detailCard.borderRight
                  anchors.bottomMargin: detailCard.borderBottom
                  spacing: Style.space(8)

                  RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Style.space(12)
                    Layout.rightMargin: Style.space(12)
                    Layout.topMargin: Style.space(12)
                    spacing: Style.space(12)

                    Item {
                      id: detailIconSlot
                      Layout.preferredWidth: Style.space(44)
                      Layout.preferredHeight: Style.space(44)
                      Layout.alignment: Qt.AlignTop

                      property bool imageFailed: false
                      readonly property string source: root.iconSource(root.previewSource(root.entry))
                      readonly property bool showGlyph: (source === "" || imageFailed) && root.entry.glyph.length > 0

                      Image {
                        anchors.fill: parent
                        visible: !detailIconSlot.showGlyph
                        source: detailIconSlot.source
                        sourceSize.width: detailIconSlot.width * Screen.devicePixelRatio
                        sourceSize.height: detailIconSlot.height * Screen.devicePixelRatio
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        onStatusChanged: detailIconSlot.imageFailed = (status === Image.Error)
                      }

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        visible: detailIconSlot.showGlyph
                        text: root.entry.glyph
                        color: Commons.Color.notifications.text
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.icon
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      Layout.alignment: Qt.AlignTop
                      textFormat: Text.PlainText
                      visible: root.entry.summary.length > 0
                      text: root.entry.summary
                      color: Commons.Color.notifications.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                      wrapMode: Text.WordWrap
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: Style.space(12)
                    Layout.rightMargin: Style.space(12)
                    Layout.topMargin: Style.space(2)
                    visible: root.entry.body.length > 0
                    text: root.bodyText(root.entry)
                    textFormat: Text.StyledText
                    color: Qt.darker(Commons.Color.notifications.text, 1.15)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }

                  Image {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 160
                    Layout.leftMargin: Style.space(12)
                    Layout.rightMargin: Style.space(12)
                    Layout.topMargin: Style.space(2)
                    visible: root.entry.image.length > 0 && status !== Image.Error
                    source: root.entry.image
                    // Bound the decoded texture, not just the painted size: a
                    // full-resolution notification image otherwise lands in
                    // VRAM at its native dimensions.
                    sourceSize.width: Math.round(contentRoot.cardWidth * Screen.devicePixelRatio)
                    sourceSize.height: Math.round(Style.space(160) * Screen.devicePixelRatio)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                  }

                  // Bottom inset of the card.
                  Item {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: Style.space(10)
                  }
                }
              }
            }

            // ---- settings ----
            Column {
              id: settingsColumn
              width: parent.width
              visible: root.settingsOpen
              spacing: 0

              RowLayout {
                id: settingsSectionsRow
                width: parent.width
                visible: root.horizontal
                spacing: 0
                readonly property real cellWidth: Math.max(
                  Style.space(240),
                  (width - Style.space(6)) / 7)

      LayoutSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      SpacingSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      PositionSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      BarIconSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      PrivacySettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      ShortcutSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
      Rectangle {
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: Qt.darker(root.fg, 2.6)
        opacity: 0.8
      }
      ClearSettings {
        Layout.preferredWidth: settingsSectionsRow.cellWidth
        Layout.minimumWidth: settingsSectionsRow.cellWidth
        Layout.maximumWidth: settingsSectionsRow.cellWidth
        Layout.alignment: Qt.AlignTop
      }
              }

              Column {
                width: parent.width
                visible: !root.horizontal
                spacing: 0

      LayoutSettings {
        width: parent.width
      }
      SettingsDivider { }
      SpacingSettings {
        width: parent.width
      }
      SettingsDivider { }
      PositionSettings {
        width: parent.width
      }
      SettingsDivider { }
      BarIconSettings {
        width: parent.width
      }
      SettingsDivider { }
      PrivacySettings {
        width: parent.width
      }
      SettingsDivider { }
      ShortcutSettings {
        width: parent.width
      }
      SettingsDivider { }
      ClearSettings {
        width: parent.width
      }
              }
            }
          }
        }

        Item {
          id: shortcutFooter
          visible: root.footerVisible
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: visible ? Math.max(Style.space(28), hintText.implicitHeight + Style.space(8)) : 0

          Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Qt.darker(root.fg, 2.6)
            opacity: 0.7
          }

          Text {
            id: hintText
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            anchors.topMargin: Style.space(4)
            anchors.bottomMargin: Style.space(4)
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.shortcutHint()
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Item {
          id: vScroll
          visible: scrollView.contentHeight > scrollView.height
          anchors.right: parent.right
          anchors.top: parent.top
          width: Style.space(10)
          height: parent.height - (shortcutFooter.visible ? shortcutFooter.height : 0)

          Rectangle {
            id: vThumb
            width: Style.space(4)
            radius: width / 2
            color: Commons.Color.accent
            opacity: vDrag.pressed ? 0.95 : 0.55
            height: Math.max(Style.space(24), vScroll.height * vScroll.height / Math.max(1, scrollView.contentHeight))
            x: (vScroll.width - width) / 2
            y: {
              var max = Math.max(1, scrollView.contentHeight - scrollView.height)
              return (scrollView.contentY / max) * Math.max(0, vScroll.height - height)
            }
          }

          MouseArea {
            id: vDrag
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onPressed: function(mouse) { vScroll.jump(mouse.y) }
            onPositionChanged: function(mouse) { if (pressed) vScroll.jump(mouse.y) }
          }

          function jump(py) {
            var max = Math.max(0, scrollView.contentHeight - scrollView.height)
            var span = Math.max(1, vScroll.height - vThumb.height)
            scrollView.contentY = Math.max(0, Math.min(1, (py - vThumb.height / 2) / span)) * max
          }
        }
      }
    }
  }
}
