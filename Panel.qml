import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "components"

// Notification center panel. Data comes from the files the active
// notification service persists (live popups at the state root, archived
// entries under history/ or the engine archive), so the center sees exactly
// what the toasts do — including notifications silenced by Do Not Disturb.
//
// Actions reach the live service through its IPC surface (omarchy-shell):
// dismissal, clear-history and DND toggle, plus a direct rm of the
// per-notification files the service owns.

Panel {
  id: root
  moduleName: "apach.notifications"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  ipcTarget: "apach.notifications"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string hostScreenName: ""
  readonly property var barIdentity: hostWidget || root

  // Data lives in the shared StoreSingleton so this UI can stay unloaded while the center is
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
  // Identity of the cursor row. Entries arrive at the front, so an index
  // alone would slide the destructive target onto a different notification.
  property string cursorStem: ""
  property string query: ""
  property bool searchOpen: false
  property bool clearArmed: false
  property bool helpOpen: false
  property int settingsCursor: 0
  property int settingsCategory: 0
  property int screenCursor: 0
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
  // Height available to the host window on its screen, published by
  // CenterWindow. The virtualized lists cap themselves to it so the card
  // never grows past the monitor.
  property real windowAvailableH: 800

  readonly property bool horizontal: root.store ? root.store.mode === "horizontal" : false
  readonly property bool footerVisible: root.store ? root.store.shortcutBar : true
  readonly property real compactWidth: Style.space(300)

  // Settings are grouped into categories. The navigation rail is the menu;
  // the focused category is the submenu. `settingsIndex` gives both the
  // keyboard state machine and the view one shared set of row numbers.
  readonly property var settingsIndex: ({
    mode: 0,
    marginX: 1,
    marginY: 2,
    padding: 3,
    cardSpacing: 4,
    placement: 5,
    centerScreen: 6,
    screens: 7,
    enterOpens: 8,
    shortcutBar: 9,
    hideBodies: 10,
    showPreviews: 11,
    showBadge: 12,
    captureToasts: 13,
    searchKey: 14,
    dndKey: 15,
    detailKey: 16,
    helpKey: 17,
    settingsKey: 18,
    allowExecActions: 19,
    dndBypass: 20,
    installEngine: 21,
    barSection: 22,
    barIndex: 23,
    confirmClear: 24,
    clearHistory: 25
  })
  readonly property var settingsCategories: [
    {
      id: "layout",
      label: strings.t("settings.category.layout.label"),
      glyph: "󰕮",
      description: strings.t("settings.category.layout.description"),
      rows: [0, 1, 2, 3, 4]
    },
    {
      id: "position",
      label: strings.t("settings.category.position.label"),
      glyph: "󰍹",
      description: strings.t("settings.category.position.description"),
      rows: [5, 6, 7]
    },
    {
      id: "notifications",
      label: strings.t("settings.category.notifications.label"),
      glyph: "󰂚",
      description: strings.t("settings.category.notifications.description"),
      rows: [8, 9, 10, 11, 12, 13]
    },
    {
      id: "shortcuts",
      label: strings.t("settings.category.shortcuts.label"),
      glyph: "󰌌",
      description: strings.t("settings.category.shortcuts.description"),
      rows: [14, 15, 16, 17, 18]
    },
    {
      id: "engine",
      label: strings.t("settings.category.engine.label"),
      glyph: "󰒓",
      description: strings.t("settings.category.engine.description"),
      rows: [19, 20, 21]
    },
    {
      id: "bar",
      label: strings.t("settings.category.bar.label"),
      glyph: "󰅌",
      description: strings.t("settings.category.bar.description"),
      rows: [22, 23]
    },
    {
      id: "data",
      label: strings.t("settings.category.data.label"),
      glyph: "󰆴",
      description: strings.t("settings.category.data.description"),
      rows: [24, 25]
    }
  ]
  readonly property var currentCategory: {
    var list = root.settingsCategories
    if (list.length === 0) return ({ label: "", description: "", rows: [] })
    var index = Math.max(0, Math.min(root.settingsCategory, list.length - 1))
    return list[index]
  }

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

  // The scroll helper lives on the instantiated content item, not on Panel:
  // the host owns state, the per-screen content owns geometry.
  function scrollSettingsCursorIntoView() {
    if (root.activeContent && typeof root.activeContent.scrollSettingsCursorIntoView === "function")
      root.activeContent.scrollSettingsCursorIntoView()
  }

  function keyLabel(value) {
    if (value === "ctrl+f") return "Ctrl+F"
    if (value === "D") return "Shift+D"
    if (value === "I") return "Shift+I"
    if (value === "P") return "Shift+P"
    return String(value || "")
  }

  function headerTitle() {
    if (root.settingsOpen) return strings.t("panel.title.settings")
    if (root.helpOpen) return strings.t("panel.title.shortcuts")
    if (root.selectedEntry !== null) return strings.t("panel.title.notification")
    if (root.searchOpen) return strings.t("panel.title.search")
    return strings.t("panel.title.notifications")
  }

  function headerSubtitle() {
    if (root.settingsOpen) {
      var label = root.currentCategory && root.currentCategory.label
        ? root.currentCategory.label : strings.t("panel.title.settings")
      return strings.t("panel.subtitle.settingsSection").arg(label)
    }
    if (root.helpOpen) return strings.t("panel.subtitle.keyboardReference")
    if (root.searchOpen) {
      if (root.query === "") return strings.t("panel.subtitle.searchPrompt")
      var results = root.matchedEntries.length
      return strings.tn("panel.subtitle.searchResults", results)
        .arg(Commons.I18n.formatNumber(results))
        .arg(root.query)
    }
    if (root.selectedEntry !== null) {
      var app = String(root.selectedEntry.app || "")
      var when = root.detailTime(root.selectedEntry)
      return app !== "" ? strings.t("panel.subtitle.detailMeta").arg(app).arg(when) : when
    }
    var parts = []
    if (root.dnd) parts.push(strings.t("panel.subtitle.dnd"))
    if (root.unseenCount > 0) {
      parts.push(strings.tn("panel.subtitle.unread", root.unseenCount)
        .arg(Commons.I18n.formatNumber(root.unseenCount)))
    }
    if (root.entries.length > 0) {
      parts.push(strings.tn("panel.subtitle.saved", root.entries.length)
        .arg(Commons.I18n.formatNumber(root.entries.length)))
    }
    return parts.length > 0 ? parts.join(" · ") : strings.t("panel.subtitle.caughtUp")
  }

  function hintItems() {
    if (root.settingsOpen) {
      return [
        { key: "Tab", label: strings.t("hint.section") },
        { key: "↑↓", label: strings.t("hint.row") },
        { key: "←→", label: strings.t("hint.adjust") },
        { key: "Enter", label: strings.t("hint.apply") },
        { key: "Esc", label: strings.t("hint.back") }
      ]
    }
    if (root.helpOpen) {
      return [
        { key: "Esc", label: strings.t("hint.close") },
        { key: root.keyLabel(root.store ? root.store.helpKey : "?"), label: strings.t("hint.toggleHelp") }
      ]
    }
    if (root.searchOpen) {
      return [
        { key: "↑↓", label: strings.t("hint.results") },
        { key: "Enter", label: strings.t("hint.open") },
        { key: "Esc", label: strings.t("hint.cancel") }
      ]
    }
    if (root.selectedEntry !== null) {
      return [
        { key: "Esc", label: strings.t("hint.back") },
        { key: "o", label: strings.t("hint.openApp") },
        { key: "x", label: strings.t("hint.dismiss") }
      ]
    }
    // Arrows and Enter are taught by the help view; the main list footer
    // keeps only the actions whose shortcuts are not obvious.
    return [
      { key: root.keyLabel(root.store ? root.store.detailKey : "i"), label: strings.t("hint.details") },
      { key: root.keyLabel(root.store ? root.store.searchKey : "/"), label: strings.t("hint.search") },
      { key: root.keyLabel(root.store ? root.store.dndKey : "d"), label: strings.t("hint.dnd") },
      { key: root.keyLabel(root.store ? root.store.settingsKey : "s"), label: strings.t("hint.settings") },
      { key: root.keyLabel(root.store ? root.store.helpKey : "?"), label: strings.t("hint.help") }
    ]
  }

  readonly property var helpGroups: {
    var enter = root.store && root.store.enterOpens === "detail"
      ? strings.t("help.openDetail") : strings.t("help.focusApp")
    return [
      {
        title: strings.t("help.groupNavigate"),
        items: [
          { key: "↑↓ / jk", label: strings.t("help.moveCursor") },
          { key: "g / G", label: strings.t("help.firstLast") },
          { key: "Esc", label: strings.t("help.backThenClose") }
        ]
      },
      {
        title: strings.t("help.groupActions"),
        items: [
          { key: "Enter", label: enter },
          { key: root.keyLabel(root.store ? root.store.detailKey : "i"), label: strings.t("help.openDetail") },
          { key: "x", label: strings.t("help.dismissSelected") },
          { key: "Shift+C", label: strings.t("help.clearAll") }
        ]
      },
      {
        title: strings.t("help.groupViews"),
        items: [
          { key: root.keyLabel(root.store ? root.store.searchKey : "/"), label: strings.t("help.search") },
          { key: root.keyLabel(root.store ? root.store.settingsKey : "s"), label: strings.t("help.openSettings") },
          { key: root.keyLabel(root.store ? root.store.dndKey : "d"), label: strings.t("help.toggleDnd") },
          { key: root.keyLabel(root.store ? root.store.helpKey : "?"), label: strings.t("help.toggleReference") }
        ]
      }
    ]
  }

  // Filtered view used by the list, the cursor and every keyboard action.
  readonly property var matchedEntries: {
    var q = root.query.trim().toLowerCase()
    if (q === "") return root.entries
    var out = []
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i]
      var hay = e.searchText !== undefined
        ? e.searchText
        : (String(e.app) + "\n" + String(e.summary) + "\n" + String(e.body)).toLowerCase()
      if (hay.indexOf(q) !== -1) out.push(e)
    }
    return out
  }

  // Flat rows for the virtualized lists, plus the count for each day header.
  // Building both in one pass keeps the section headers from rewalking the
  // whole archive on every change.
  readonly property var listData: {
    var rows = []
    var counts = ({})
    for (var i = 0; i < root.matchedEntries.length; i++) {
      var item = root.matchedEntries[i]
      var day = root.dayLabel(item.timestamp)
      counts[day] = (counts[day] || 0) + 1
      rows.push({ entry: item, index: i, day: day })
    }
    return { rows: rows, counts: counts }
  }
  readonly property var listModel: listData.rows
  readonly property var dayCounts: listData.counts

  function isUnread(entry) {
    return !!entry && !!root.store && Number(entry.timestamp) > Number(root.store.lastSeen || 0)
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return ""
    return Quickshell.iconPath(value, true)
  }

  // Prefer app identity in the small icon plate. A notification image is a
  // fallback only when previews are allowed and the sender supplied no icon;
  // the full artwork belongs in the detail view, not in the list.
  function entryIcon(entry) {
    if (!entry) return ""
    var icon = String(entry.appIcon || "")
    if (icon !== "") return root.iconSource(icon)
    if (root.store && root.store.showPreviews === false) return ""
    var image = Model.safeImageSource(entry.image)
    return image !== "" ? root.iconSource(image) : ""
  }

  function previewImage(entry) {
    if (!entry) return ""
    if (root.store && root.store.showPreviews === false) return ""
    return Model.safeImageSource(entry.image)
  }

  function bodyText(entry) {
    if (!entry) return ""
    if (root.store && root.store.hideBodies) return ""
    return Model.styledBody(entry.body, entry.app, entry.appIcon)
  }

  function detailTime(entry) {
    if (!entry || !entry.timestamp) return ""
    var date = new Date(Number(entry.timestamp))
    return root.displayLocale.toString(date, "ddd d MMM yyyy · HH:mm")
  }

  // Localized relative age for list rows. The catalog picks the plural form
  // and Commons.I18n formats the count in the display language; dates older
  // than a week use the display locale instead of the English month names.
  function timeAgo(ts) {
    var parts = Model.timeAgoParts(ts, Date.now())
    if (!parts) return ""
    if (parts.key === "time.justNow") return strings.t(parts.key)
    if (parts.key !== "") {
      return strings.tn(parts.key, parts.count)
        .arg(Commons.I18n.formatNumber(parts.count))
    }
    return root.displayLocale.toString(new Date(parts.date), "d MMM")
  }

  function dayLabel(ts) {
    var date = new Date(Number(ts) || 0)
    var now = new Date()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()
    var diff = Math.round((today - day) / 86400000)
    if (diff === 0) return strings.t("time.today")
    if (diff === 1) return strings.t("time.yesterday")
    if (diff > 1 && diff < 7) return root.displayLocale.toString(date, "dddd")
    return root.displayLocale.toString(date, "d MMMM yyyy")
  }

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property var displayLocale: Qt.locale(Commons.I18n.formatLocale)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Null-safe view for the detail bindings.
  readonly property var entry: root.selectedEntry !== null ? root.selectedEntry : Model.emptyEntry()

  // ---- lifecycle ----

  function open() {
    root.settingsOpen = false
    root.helpOpen = false
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    clearArmTimer.stop()
    root.selectedEntry = null
    root.cursorIndex = -1
    if (root.store) root.store.reloadState()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
    root.settingsOpen = false
    root.helpOpen = false
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    clearArmTimer.stop()
    root.selectedEntry = null
    root.cursorIndex = -1
    root.settingsCategory = 0
    root.settingsCursor = 0
    if (root.store) root.store.markSeen()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onCursorIndexChanged: {
    root.cursorStem = (root.cursorIndex >= 0 && root.cursorIndex < root.matchedEntries.length)
      ? String(root.matchedEntries[root.cursorIndex].stem) : ""
  }

  onOpenedChanged: {
    if (!root.store) return
    root.store.hostOpen = root.opened
    root.store.setCenterOpen(root.opened)
    if (root.opened) root.store.refresh()
  }

  // Entries can change while the list is visible (watcher, poll, dismissal).
  // Keep the keyboard cursor and the detail selection valid.
  Connections {
    target: root.store
    function onEntriesChanged() {
      var keepStem = root.cursorStem
      var keepIndex = root.cursorIndex
      root.clampCursor()
      if (keepStem !== "") {
        var found = -1
        for (var i = 0; i < root.matchedEntries.length; i++) {
          if (String(root.matchedEntries[i].stem) === keepStem) { found = i; break }
        }
        if (found !== -1) root.cursorIndex = found
        else root.cursorIndex = Math.min(keepIndex, root.matchedEntries.length - 1)
      }
      if (root.cursorIndex >= 0 && root.cursorIndex < root.matchedEntries.length)
        root.cursorStem = String(root.matchedEntries[root.cursorIndex].stem)
      else
        root.cursorStem = ""

      if (root.selectedEntry !== null && root.store) {
        var stem = String(root.selectedEntry.stem)
        var refreshed = null
        for (var j = 0; j < root.store.entries.length; j++) {
          if (String(root.store.entries[j].stem) === stem) { refreshed = root.store.entries[j]; break }
        }
        root.selectedEntry = refreshed
      }
    }
  }

  // ---- actions (state changes live in the shared StoreSingleton) ----

  function deleteEntry(entry) {
    if (!entry || !root.store) return
    if (root.selectedEntry && String(root.selectedEntry.stem) === String(entry.stem))
      root.selectedEntry = null
    root.store.deleteEntry(entry)
    // The cursor stays on the same index: the next entry slides into the
    // deleted one's place, like a standard list.
    root.clampCursor()
  }

  // Dismiss every on-screen toast, then wipe the history the service keeps.
  function clearAll() {
    if (root.store) root.store.clearAll()
    root.selectedEntry = null
    root.cursorIndex = -1
    root.clearArmed = false
  }

  function requestClear() {
    if (!root.store) return
    if (!root.store.confirmClear) {
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

  function handleClearShortcut() { root.requestClear() }

  function toggleDnd() {
    if (root.store) root.store.toggleDnd()
  }

  // ---- bar placement ----

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

  // Clicking "Open app" focuses the application that sent the notification.
  // The helper matches Hyprland window classes case-insensitively; archived
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

  // ---- settings navigation ----

  function openSettings() {
    if (!root.opened) root.open()
    root.helpOpen = false
    root.selectedEntry = null
    root.searchOpen = false
    root.query = ""
    root.clearArmed = false
    root.settingsOpen = true
    root.settingsCategory = 0
    root.settingsCursor = root.settingsCategories[0].rows[0]
    root.screenCursor = 0
    var screens = root.screenList
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === root.hostScreenName) {
        root.screenCursor = i
        break
      }
    }
    Qt.callLater(function() { root.scrollSettingsCursorIntoView() })
  }

  function selectSettingsCategory(index) {
    if (index < 0 || index >= root.settingsCategories.length) return
    root.settingsCategory = index
    root.settingsCursor = root.settingsCategories[index].rows[0]
    Qt.callLater(function() {
      root.scrollSettingsCursorIntoView()
      var view = root.activeScrollView()
      if (view) view.contentY = 0
    })
  }

  function switchSettingsCategory(delta) {
    var count = root.settingsCategories.length
    if (count === 0) return
    var step = delta >= 0 ? 1 : -1
    root.selectSettingsCategory((root.settingsCategory + step + count) % count)
  }

  function focusSetting(row) {
    if (row === undefined || row === null || row < 0) return
    root.settingsCursor = row
    for (var i = 0; i < root.settingsCategories.length; i++) {
      if (root.settingsCategories[i].rows.indexOf(row) !== -1) {
        root.settingsCategory = i
        return
      }
    }
  }

  function moveSettingsCursor(dy) {
    if (dy === 0) return
    var rows = root.currentCategory && root.currentCategory.rows ? root.currentCategory.rows : []
    if (rows.length === 0) return
    var position = rows.indexOf(root.settingsCursor)
    if (position === -1) position = 0
    else position = Math.max(0, Math.min(rows.length - 1, position + dy))
    root.settingsCursor = rows[position]
    if (root.activeContent) root.activeContent.scrollSettingsCursorIntoView()
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
    var index = root.settingsIndex
    var modes
    var modeIndex
    var sections
    var sectionIndex

    switch (root.settingsCursor) {
    case index.mode:
      modes = ["window", "horizontal", "vertical"]
      modeIndex = modes.indexOf(root.store.mode)
      root.store.setMode(modes[(modeIndex + step + modes.length) % modes.length])
      break
    case index.marginX:
      root.store.setMargin("x", root.store.marginX + step * 4)
      break
    case index.marginY:
      root.store.setMargin("y", root.store.marginY + step * 4)
      break
    case index.padding:
      root.store.setPadding(root.store.padding + step * 2)
      break
    case index.cardSpacing:
      root.store.setCardSpacing(root.store.cardSpacing + step * 2)
      break
    case index.placement:
      root.cyclePlacement(delta)
      break
    case index.centerScreen:
      break
    case index.screens:
      root.cycleScreen(step)
      break
    case index.enterOpens:
      root.store.setEnterOpens(root.store.enterOpens === "app" ? "detail" : "app")
      break
    case index.shortcutBar:
      root.store.setShortcutBar(!root.store.shortcutBar)
      break
    case index.hideBodies:
      root.store.setHideBodies(!root.store.hideBodies)
      break
    case index.showPreviews:
      root.store.setShowPreviews(!root.store.showPreviews)
      break
    case index.showBadge:
      root.store.setShowBadge(!root.store.showBadge)
      break
    case index.captureToasts:
      root.store.setCaptureToasts(!root.store.captureToasts)
      break
    case index.searchKey:
      root.store.setSearchKey(root.store.searchKey === "ctrl+f" ? "/" : "ctrl+f")
      break
    case index.dndKey:
      root.store.setDndKey(root.store.dndKey === "D" ? "d" : "D")
      break
    case index.detailKey:
      root.store.setDetailKey(root.store.detailKey === "I" ? "i" : "I")
      break
    case index.helpKey:
      root.store.setHelpKey(root.store.helpKey === "F1" ? "?" : "F1")
      break
    case index.settingsKey:
      root.store.setSettingsKey(root.store.settingsKey === "P" ? "s" : "P")
      break
    case index.allowExecActions:
      root.store.setAllowExecActions(!root.store.allowExecActions)
      break
    case index.dndBypass:
      root.store.setDndBypass(!root.store.dndBypass)
      break
    case index.installEngine:
      break
    case index.barSection:
      sections = ["left", "center", "right"]
      sectionIndex = sections.indexOf(root.store.barSection)
      if (sectionIndex === -1) sectionIndex = 0
      root.moveBarSection(sections[(sectionIndex + step + sections.length) % sections.length])
      break
    case index.barIndex:
      root.stepBarIndex(step)
      break
    case index.confirmClear:
      root.store.setConfirmClear(!root.store.confirmClear)
      break
    case index.clearHistory:
      break
    }
  }

  function activateSettings() {
    var index = root.settingsIndex
    if (root.settingsCursor === index.centerScreen) {
      if (!root.store || root.store.mode !== "vertical") root.setPlacement("center", "center")
      return
    }
    if (root.settingsCursor === index.screens) {
      root.toggleScreenAtCursor()
      return
    }
    if (root.settingsCursor === index.installEngine) {
      if (root.store) root.store.installEngine()
      return
    }
    if (root.settingsCursor === index.clearHistory) {
      root.requestClear()
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
    if (root.cursorIndex < 0 && root.matchedEntries.length > 0) root.cursorIndex = 0
    if (root.cursorIndex >= 0 && root.cursorIndex < root.matchedEntries.length)
      root.openDetail(root.matchedEntries[root.cursorIndex])
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
    if (root.selectedEntry !== null) { root.backToList(); return }
    if (root.store && root.store.enterOpens === "detail") root.openDetailAtCursor()
    else {
      if (root.cursorIndex < 0 && root.matchedEntries.length > 0) root.cursorIndex = 0
      root.activateCursor()
    }
  }

  function handleDelete(shift) {
    if (root.settingsOpen || root.helpOpen || root.searchOpen) return
    if (shift) { root.requestClear(); return }
    if (root.selectedEntry !== null) root.deleteEntry(root.selectedEntry)
    else root.deleteCursorEntry()
  }

  onSettingsOpenChanged: {
    var view = root.activeScrollView()
    if (view) view.contentY = 0
  }
  onSettingsCategoryChanged: {
    Qt.callLater(function() {
      root.scrollSettingsCursorIntoView()
      var view = root.activeScrollView()
      if (view) view.contentY = 0
    })
  }
  onSelectedEntryChanged: {
    var view = root.activeScrollView()
    if (view) view.contentY = 0
  }
  onQueryChanged: {
    root.cursorIndex = -1
    var view = root.activeScrollView()
    if (view) view.contentY = 0
    if (root.activeContent && root.activeContent.resetListScroll)
      root.activeContent.resetListScroll()
  }

  // ---- navigation / presentation ----

  function openDetail(entry) {
    if (root.searchOpen) {
      root.searchOpen = false
      root.query = ""
      var field = root.activeSearchField()
      if (field) field.text = ""
      Qt.callLater(function() { root.focusActiveContent() })
    }
    root.selectedEntry = entry
  }
  function backToList() { root.selectedEntry = null }

  // ---- keyboard cursor ----

  function clampCursor() {
    var n = root.matchedEntries.length
    if (n === 0) root.cursorIndex = -1
    else if (root.cursorIndex >= n) root.cursorIndex = n - 1
  }

  function moveCursor(dy) {
    var n = root.matchedEntries.length
    if (n === 0) return
    if (root.cursorIndex < 0) {
      root.cursorIndex = dy > 0 ? 0 : n - 1
    } else {
      root.cursorIndex = Math.max(0, Math.min(n - 1, root.cursorIndex + dy))
    }
    if (root.activeContent) root.activeContent.scrollCursorIntoView()
  }

  function activateCursor() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.matchedEntries.length) return
    var entry = root.matchedEntries[root.cursorIndex]
    if (root.store && root.store.enterOpens === "detail") root.openDetail(entry)
    else root.activateEntry(entry)
  }

  function deleteCursorEntry() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.matchedEntries.length) return
    root.deleteEntry(root.matchedEntries[root.cursorIndex])
  }

  // ======================================================================
  // UI
  // ======================================================================

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
        if (root.settingsOpen) return Style.space(720)
        if (root.selectedEntry !== null) return Style.space(560)
        if (!root.horizontal) return Style.space(440)
        var spacing = root.store ? root.store.cardSpacing : 10
        var count = root.matchedEntries.length
        var cards = count > 0 ? count * root.compactWidth + (count - 1) * spacing : 0
        return Math.max(Style.space(480), cards)
      }
      desiredHeight: (contentLoader.item ? contentLoader.item.activeContentHeight : 0)
        + (root.footerVisible && contentLoader.item ? contentLoader.item.footerHeight : 0)
      focusTarget: contentLoader.item ? contentLoader.item.keyCatcher : null

      // Publish the real usable height so the virtualized list can cap itself
      // instead of overflowing the monitor. The primary window wins; the others
      // only fill in while it has not reported yet.
      onAvailableHChanged: if (isPrimary || root.windowAvailableH <= 0) root.windowAvailableH = availableH
      Component.onCompleted: if (isPrimary || root.windowAvailableH <= 0) root.windowAvailableH = availableH

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
      property real cardWidth: 440
      readonly property real footerHeight: shortcutFooter.height
      readonly property real activeContentHeight: {
        var h = headerRow.height + headerSeparator.height
        var count = 2
        if (root.searchOpen) { h += searchRow.height; count++ }
        if (root.clearArmed) { h += clearBanner.height; count++ }
        var view = root.helpOpen ? helpColumn
          : (root.settingsOpen ? settingsView
          : (root.selectedEntry !== null ? detailView : listSection))
        if (view) { h += view.implicitHeight; count++ }
        return h + Style.space(10) * Math.max(0, count - 1)
      }

      // Maximum height of the virtualized list inside the card. The card is
      // clamped to the screen by CenterWindow, so the list must stop before
      // the header, search field, footer and paddings eat the rest.
      readonly property real listMaxHeight: {
        var pad = root.store ? root.store.padding : 12
        var chrome = headerRow.height + headerSeparator.height + Style.space(10) * 2
        if (root.searchOpen) chrome += searchRow.height + Style.space(10)
        if (root.clearArmed) chrome += clearBanner.height + Style.space(10)
        var footer = root.footerVisible ? contentRoot.footerHeight : 0
        // Small safety margin for the card border, which is not exposed here.
        return Math.max(Style.space(140),
          root.windowAvailableH - pad * 2 - Style.space(6) - footer - chrome)
      }

      // Walk the settings tree to the highlighted row. The rows are nested
      // inside category columns, and the cursor can move past the card when
      // the settings list is taller than the screen.
      function activeSettingsRow(item) {
        var children = item ? item.children : null
        if (!children) return null
        for (var i = 0; i < children.length; i++) {
          var child = children[i]
          if (!child) continue
          if (child.active === true || child.hasCursor === true) return child
          var nested = contentRoot.activeSettingsRow(child)
          if (nested) return nested
        }
        return null
      }

      function scrollSettingsCursorIntoView() {
        if (!root.settingsOpen) return
        var row = contentRoot.activeSettingsRow(settingsView)
        if (!row) return
        var margin = Style.space(16)
        var y = row.mapToItem(contentColumn, 0, 0).y
        var top = scrollView.contentY + margin
        var bottom = scrollView.contentY + scrollView.height - margin
        if (y >= top && y + row.height <= bottom) return
        var maxY = Math.max(0, scrollView.contentHeight - scrollView.height)
        if (y < top) scrollView.contentY = Math.max(0, y - margin)
        else scrollView.contentY = Math.min(maxY, y + row.height - scrollView.height + margin)
      }

      function resetListScroll() {
        listView.savedY = 0
        listView.contentY = 0
        bandList.contentX = 0
      }

      // Let ListView do the work: it knows the delegate geometry and only
      // scrolls when the target row is outside the viewport.
      function scrollCursorIntoView() {
        if (root.cursorIndex < 0) return
        if (root.horizontal) {
          bandList.positionViewAtIndex(root.cursorIndex, ListView.Contain)
          return
        }
        listView.positionViewAtIndex(root.cursorIndex, ListView.Contain)
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
          if (root.settingsOpen) {
            root.switchSettingsCategory(direction)
            return
          }
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
          if (root.selectedEntry !== null) {
            if (t === "o") root.activateEntry(root.selectedEntry)
            return
          }
          if (t === root.store.dndKey) root.toggleDnd()
          else if (t === root.store.detailKey) root.openDetailAtCursor()
          else if (t === root.store.helpKey) root.toggleHelp()
          else if (t === root.store.searchKey) root.openSearch()
          else if (t === root.store.settingsKey) root.openSettings()
          else if (t === "g") { root.cursorIndex = root.matchedEntries.length > 0 ? 0 : -1; contentRoot.scrollCursorIntoView() }
          else if (t === "G") {
            root.cursorIndex = Math.max(0, root.matchedEntries.length - 1)
            contentRoot.scrollCursorIntoView()
          }
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

            RowLayout {
              id: headerRow
              width: parent.width
              spacing: Style.space(7)

              PanelActionButton {
                visible: root.settingsOpen || root.helpOpen || root.selectedEntry !== null || root.searchOpen
                size: Style.space(28)
                iconText: "󰅁"
                tooltipText: strings.t("panel.back")
                foreground: root.fg
                hoverColor: Commons.Color.accent
                fontFamily: root.fontFamily
                onClicked: root.closeView()
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(7)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.headerTitle()
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  BorderSurface {
                    visible: !root.settingsOpen && !root.helpOpen
                      && root.selectedEntry === null && !root.searchOpen
                      && root.unseenCount > 0
                    implicitWidth: unreadPillText.implicitWidth + Style.space(12)
                    implicitHeight: unreadPillText.implicitHeight + Style.space(5)
                    radius: height / 2
                    color: Style.selectedFillFor(root.fg, Commons.Color.accent)
                    borderSpec: Border.controlSpec("normal", root.fg, Commons.Color.accent)

                    Text {
                      id: unreadPillText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: root.unseenCount > 99 ? "99+" : Commons.I18n.formatNumber(root.unseenCount)
                      color: Commons.Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.headerSubtitle()
                  color: Qt.darker(root.fg, 1.55)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Row {
                id: headerActions
                spacing: 0

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                    && root.selectedEntry === null && !root.searchOpen
                  size: Style.space(28)
                  iconText: "󰍉"
                  tooltipText: strings.t("panel.searchTooltip")
                    .arg(root.keyLabel(root.store ? root.store.searchKey : "/"))
                  foreground: root.fg
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openSearch()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                  size: Style.space(28)
                  iconText: root.dnd ? "󰂜" : "󰂛"
                  tooltipText: root.dnd
                    ? strings.t("panel.allowNotifications")
                    : strings.t("panel.silenceNotifications")
                  foreground: root.dnd ? Commons.Color.accent : Qt.darker(root.fg, 1.5)
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.toggleDnd()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                  size: Style.space(28)
                  iconText: "󰒓"
                  tooltipText: strings.t("panel.settingsTooltip")
                    .arg(root.keyLabel(root.store ? root.store.settingsKey : "s"))
                  foreground: root.fg
                  hoverColor: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: root.openSettings()
                }

                PanelActionButton {
                  visible: !root.settingsOpen && !root.helpOpen
                    && root.selectedEntry === null
                  size: Style.space(28)
                  iconText: "󰆴"
                  tooltipText: strings.t("panel.clearAll")
                  foreground: root.fg
                  hoverColor: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  enabled: root.entries.length > 0
                  onClicked: root.requestClear()
                }
              }
            }

            PanelSeparator {
              id: headerSeparator
              foreground: root.fg
              width: parent.width
            }

            Item {
              id: searchRow
              width: parent.width
              height: Math.max(searchField.implicitHeight, Style.space(32))
              visible: root.searchOpen

              TextField {
                id: searchField
                anchors.fill: parent
                leftPadding: Style.space(30)
                rightPadding: Style.space(30)
                placeholderText: strings.t("search.placeholder")
                foreground: root.fg
                accent: Commons.Color.accent
                font.pixelSize: Style.font.bodySmall
                hasCursor: true
                onTextChanged: root.query = text
                Keys.onEscapePressed: root.closeSearch()
                Keys.onReturnPressed: {
                  keyCatcher.forceActiveFocus()
                  if (root.cursorIndex < 0 && root.matchedEntries.length > 0) root.cursorIndex = 0
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
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "󰍉"
                color: Qt.darker(root.fg, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              PanelActionButton {
                visible: root.query !== ""
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                size: Style.space(24)
                iconText: "󰅖"
                tooltipText: strings.t("search.clear")
                foreground: root.fg
                hoverColor: Commons.Color.urgent
                fontFamily: root.fontFamily
                onClicked: {
                  searchField.text = ""
                  root.query = ""
                  searchField.forceActiveFocus()
                }
              }
            }

            BorderSurface {
              id: clearBanner
              visible: root.clearArmed
              width: parent.width
              implicitHeight: clearBannerRow.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: Style.selectedFillFor(Commons.Color.urgent, Commons.Color.urgent)
              borderSpec: Border.controlSpec("normal", Commons.Color.urgent, Commons.Color.urgent)

              RowLayout {
                id: clearBannerRow
                anchors.fill: parent
                anchors.margins: Style.space(7)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "󰀪"
                  color: Commons.Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: strings.t("clear.banner")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  text: strings.t("clear.now")
                  bordered: true
                  foreground: Commons.Color.urgent
                  accent: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.requestClear()
                }
              }
            }

            HelpView {
              id: helpColumn
              visible: root.helpOpen
              width: Math.min(parent.width, Style.space(500))
              x: Math.max(0, (parent.width - width) / 2)
              groups: root.helpGroups
              foreground: root.fg
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
            }

            // ---- list ----
            Column {
              id: listSection
              width: parent.width
              spacing: root.store ? root.store.cardSpacing : 10
              visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry === null

              Column {
                visible: root.matchedEntries.length === 0
                width: parent.width
                spacing: Style.space(6)
                topPadding: Style.space(30)
                bottomPadding: Style.space(30)

                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(58)
                  height: width
                  radius: width / 2
                  color: Style.normalFillFor(root.fg, Commons.Color.accent)
                  border.width: Math.max(1, Style.space(1))
                  border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)

                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.query !== "" ? "󰍉" : "󰂚"
                    color: Qt.darker(root.fg, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.displayLarge
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.query !== "" && root.entries.length > 0
                    ? strings.t("empty.noMatches") : strings.t("empty.caughtUp")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.min(parent.width, Style.space(300))
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: root.query !== "" && root.entries.length > 0
                    ? strings.t("empty.tryDifferent")
                    : strings.t("empty.arrive")
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Button {
                  visible: root.query !== ""
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: strings.t("empty.clearSearch")
                  bordered: true
                  foreground: root.fg
                  accent: Commons.Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.closeSearch()
                }
              }

              // Virtualized stack for the floating window and the vertical
              // band. Only the delegates inside the viewport exist, so the
              // cost of a 1000-entry archive is a screenful, not 1000 rows.
              ListView {
                id: listView
                width: parent.width
                visible: !root.horizontal
                height: count === 0 ? 0 : Math.min(contentHeight, contentRoot.listMaxHeight)
                contentWidth: width
                spacing: root.store ? root.store.cardSpacing : 10
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.listModel

                // A rebuild replaces the model array. Keep the viewport where
                // the user left it instead of snapping back to the newest row.
                property real savedY: 0
                onContentYChanged: savedY = contentY
                onModelChanged: Qt.callLater(function() {
                  listView.contentY = Math.min(listView.savedY,
                    Math.max(0, listView.contentHeight - listView.height))
                })

                section.property: "day"
                section.delegate: Item {
                  required property string section
                  width: listView.width
                  height: Style.space(24)

                  RowLayout {
                    anchors.fill: parent
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      text: parent.parent.section
                      color: Qt.darker(root.fg, 1.65)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 0.8
                    }

                    Rectangle {
                      Layout.fillWidth: true
                      height: 1
                      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: Commons.I18n.formatNumber(root.dayCounts[parent.parent.section] || 0)
                      color: Qt.darker(root.fg, 1.75)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                delegate: NotificationRow {
                  required property var modelData
                  required property int index
                  entry: modelData.entry
                  rowIndex: index
                  cursorActive: root.cursorIndex === index
                  unread: root.isUnread(modelData.entry)
                  showBody: !root.store || !root.store.hideBodies
                  iconSource: root.entryIcon(modelData.entry)
                  bodyMarkup: root.bodyText(modelData.entry)
                  timeText: root.timeAgo(modelData.entry.timestamp)
                  cardText: Commons.Color.notifications.text
                  accent: Commons.Color.accent
                  urgent: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  onHovered: function(index) { root.cursorIndex = index }
                  onDetailsRequested: function(entry) { root.openDetail(entry) }
                  onAppRequested: function(entry) { root.activateEntry(entry) }
                  onRemoveRequested: function(entry) { root.deleteEntry(entry) }
                }
              }

              // Side-by-side cards for the horizontal band, also virtualized.
              Item {
                width: parent.width
                height: bandList.height + (bandList.contentWidth > bandList.width
                  ? (root.store ? root.store.padding : 12) + Style.space(8) : 0)
                visible: root.horizontal

                ListView {
                  id: bandList
                  width: parent.width
                  height: count === 0 ? 0 : Style.space(100)
                  orientation: ListView.Horizontal
                  spacing: root.store ? root.store.cardSpacing : 10
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.listModel

                  // Cards have a fixed width; center the row when it does not
                  // fill the band, and let it scroll when it does.
                  readonly property real itemsWidth: count > 0
                    ? count * root.compactWidth + (count - 1) * spacing : 0
                  leftMargin: Math.max(0, (width - itemsWidth) / 2)
                  rightMargin: leftMargin

                  delegate: CompactCard {
                    required property var modelData
                    required property int index
                    entry: modelData.entry
                    rowIndex: index
                    cursorActive: root.cursorIndex === index
                    unread: root.isUnread(modelData.entry)
                    showBody: !root.store || !root.store.hideBodies
                    preferredWidth: root.compactWidth
                    iconSource: root.entryIcon(modelData.entry)
                    bodyMarkup: root.bodyText(modelData.entry)
                    timeText: root.timeAgo(modelData.entry.timestamp)
                    cardText: Commons.Color.notifications.text
                    accent: Commons.Color.accent
                    urgent: Commons.Color.urgent
                    fontFamily: root.fontFamily
                    onHovered: function(index) { root.cursorIndex = index }
                    onDetailsRequested: function(entry) { root.openDetail(entry) }
                    onAppRequested: function(entry) { root.activateEntry(entry) }
                    onRemoveRequested: function(entry) { root.deleteEntry(entry) }
                  }
                }

                Item {
                  id: hScroll
                  visible: bandList.contentWidth > bandList.width
                  anchors.left: parent.left
                  anchors.right: parent.right
                  // Same inset as the cards have from the outer frame.
                  y: bandList.height + (root.store ? root.store.padding : 12)
                  height: Style.space(8)

                  Rectangle {
                    id: hThumb
                    height: Style.space(4)
                    radius: height / 2
                    color: Commons.Color.accent
                    opacity: hDrag.pressed ? 0.95 : 0.55
                    width: Math.max(Style.space(28), hScroll.width * hScroll.width / Math.max(1, bandList.contentWidth))
                    x: {
                      var max = Math.max(1, bandList.contentWidth - bandList.width)
                      return (bandList.contentX / max) * Math.max(0, hScroll.width - width)
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
                    var max = Math.max(0, bandList.contentWidth - bandList.width)
                    var span = Math.max(1, hScroll.width - hThumb.width)
                    bandList.contentX = Math.max(0, Math.min(1, (px - hThumb.width / 2) / span)) * max
                  }
                }
              }
            }

            // ---- detail ----
            DetailView {
              id: detailView
              visible: !root.settingsOpen && !root.helpOpen && root.selectedEntry !== null
              width: Math.min(parent.width, root.horizontal ? Style.space(760) : Style.space(560))
              x: Math.max(0, (parent.width - width) / 2)
              entry: root.entry
              iconSource: root.entryIcon(root.entry)
              bodyMarkup: root.bodyText(root.entry)
              bodyHidden: !!root.store && root.store.hideBodies
              imageSource: root.previewImage(root.entry)
              timeText: root.detailTime(root.entry)
                + (root.entry.timestamp ? " · " + root.timeAgo(root.entry.timestamp) : "")
              foreground: root.fg
              accent: Commons.Color.accent
              urgent: Commons.Color.urgent
              cardText: Commons.Color.notifications.text
              fontFamily: root.fontFamily
              onOpenAppRequested: function(entry) { root.activateEntry(entry) }
              onRemoveRequested: function(entry) { root.deleteEntry(entry) }
            }

            // ---- settings ----
            SettingsView {
              id: settingsView
              visible: root.settingsOpen
              width: parent.width
              panel: root
            }
          }
        }

        HintBar {
          id: shortcutFooter
          visible: root.footerVisible
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: visible ? implicitHeight : 0
          hints: root.hintItems()
          foreground: root.fg
          accent: Commons.Color.accent
          fontFamily: root.fontFamily
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
