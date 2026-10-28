import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Data half of the notification center: everything the bar bell needs
// (unread count, DND state) plus the live/history merge and the action queue.
//
// Kept in its own object so the UI in Panel.qml can stay unloaded until the
// user actually opens the center. One Store exists per bar instance and is
// inert (no visible item, width/height 0) — the visible cost is zero.
Item {
  id: store
  visible: false
  width: 0
  height: 0

  // ---- state dirs (owned by the shell's notification service) ----
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/notifications"
  readonly property string settingsPath: home + "/.local/state/omarchy/notifications.json"
  readonly property string centerStatePath: home + "/.local/state/omarchy/notifications-center.json"

  // Injected by BarWidget from the merged plugin's service. When present, the
  // live rows come straight from the service model and DND is a direct call;
  // the file readers below remain only as a fallback.
  property var service: null

  property bool dnd: false
  property double lastSeen: 0
  property bool centerStateLoaded: false
  property int unseenCount: 0

  // Center placement, persisted next to lastSeen. `placement` is
  // "<top|bottom>-<left|center|right>"; margins are screen-edge insets.
  property string placement: "top-right"
  // Monitors where both the center and its toasts appear. Chosen explicitly
  // in settings from the detected outputs, never derived from focus. At most
  // four names are kept.
  property var screenNames: []
  property string primaryScreenName: ""
  property bool screensDefaulted: false
  property bool shellConfigLoaded: false
  // "window" floats a card, "horizontal"/"vertical" turn the center into a
  // band that spans the free screen area along that axis.
  property string mode: "window"
  // Symmetric margins: X applies to both sides, Y to top and bottom.
  property int marginX: 12
  property int marginY: 12
  property int padding: 12
  property int cardSpacing: 10
  // Shift+C asks for a second press before clearing everything.
  property bool confirmClear: true

  // Behaviour / privacy / shortcut preferences.
  property string enterOpens: "app"
  property bool shortcutBar: true
  property bool hideBodies: false
  property bool showPreviews: true
  property bool showBadge: true
  property string searchKey: "/"
  property string dndKey: "d"
  property string detailKey: "i"
  property string helpKey: "?"
  property string settingsKey: "s"

  // Where the bar entry currently lives (read from shell.json), so the
  // settings view can show the active section and offer a fine index move.
  property string barSection: ""
  property int barIndex: -1
  property var barSizes: ({})

  property var liveEntries: []
  property var archiveEntries: []
  property var entries: []
  property string mergeSignature: ""

  // ---- action queue (one serialized Process for all mutating actions) ----
  property var actionQueue: []

  // Stems whose files we just deleted ourselves. The service may still be
  // mid-archive (or the dir watch may fire on a file that is about to
  // vanish), so reads within this window drop these rows instead of
  // resurrecting them. Keyed by stem, valued by expiry timestamp.
  property var suppressedStems: ({})

  // ---- lifecycle ----

  Component.onCompleted: {
    store.refresh()
    // FileView can fire onLoaded more than once during startup; the guard
    // inside loadCenterState handles that.
    Qt.callLater(function() { centerStateFile.reload() })
  }

  // ---- data ----

  Connections {
    target: store.service
    ignoreUnknownSignals: true
    function onDoNotDisturbChanged() {
      store.dnd = store.service.doNotDisturb === true
    }
    function onArchiveEntriesChanged() {
      store.onArchiveChanged()
    }
  }

  // Live toast rows change in place as clients update them through
  // replaces_id, and rows leave when a toast is dismissed or expires.
  Connections {
    target: store.service ? store.service.popupModel : null
    ignoreUnknownSignals: true
    function onRowsInserted() { store.refreshLive() }
    function onRowsRemoved() { store.refreshLive() }
    function onDataChanged() { store.refreshLive() }
    function onModelReset() { store.refreshLive() }
  }

  function refresh() {
    if (store.service) store.refreshLive()
    else if (!liveReadProc.running) liveReadProc.running = true
    if (!store.service) settingsFile.reload()
  }

  function onServiceChanged() {
    if (!store.service) return
    if (typeof store.service.setCenterOpen === "function")
      store.service.setCenterOpen(store.hostOpen === true)
    store.dnd = store.service.doNotDisturb === true
    store.archiveEntries = store.service.archiveEntries || []
    store.refreshLive()
  }

  function onArchiveChanged() {
    if (!store.service) return
    store.archiveEntries = store.service.archiveEntries || []
    store.rebuildEntries()
  }

  // Snapshot the service's live ListModel. Roles are copied out because a
  // model row is not stable across service updates.
  function refreshLive() {
    if (!store.service) return
    var model = store.service.popupModel
    if (!model) return
    var out = []
    for (var i = 0; i < model.count; i++) {
      var row = model.get(i)
      if (!row) continue
      out.push({
        id: Number(row.id || 0),
        originalId: Number(row.originalId || 0),
        app: String(row.app || ""),
        appIcon: String(row.appIcon || ""),
        summary: String(row.summary || ""),
        body: String(row.body || ""),
        image: String(row.image || ""),
        glyph: String(row.glyph || ""),
        execArgv: String(row.execArgv || ""),
        urgency: typeof row.urgency === "number" ? row.urgency : 1,
        timestamp: Number(row.timestamp || 0),
        stem: String(row.timestamp || 0) + "-" + String(row.originalId || 0),
        source: "live"
      })
    }
    store.liveEntries = store.filterSuppressed(out)
    store.rebuildEntries()
  }

  function onLiveRead(raw) {
    if (store.service) return
    store.liveEntries = store.filterSuppressed(Model.parseEntries(raw, "live"))
    store.rebuildEntries()
  }

  function rebuildEntries() {
    var merged = Model.mergeEntries(store.liveEntries, store.archiveEntries)
    var sig = Model.signature(merged)
    if (sig === store.mergeSignature) return
    store.entries = merged
    store.mergeSignature = sig
    store.recomputeUnseen()
  }

  function recomputeUnseen() {
    var n = 0
    for (var i = 0; i < store.entries.length; i++)
      if (Number(store.entries[i].timestamp) > store.lastSeen) n++
    store.unseenCount = n
  }

  function suppress(stem, ms) {
    var next = {}
    var now = Date.now()
    for (var k in store.suppressedStems)
      if (store.suppressedStems[k] > now) next[k] = store.suppressedStems[k]
    next[String(stem)] = now + (Number(ms) || 2000)
    store.suppressedStems = next
  }

  function filterSuppressed(parsed) {
    var now = Date.now()
    var out = []
    for (var i = 0; i < parsed.length; i++) {
      var expiry = store.suppressedStems[parsed[i].stem]
      if (expiry !== undefined && expiry > now) continue
      out.push(parsed[i])
    }
    return out
  }

  // ---- unseen state persistence ----

  function loadCenterState(raw) {
    var parsed = Model.parseCenterState(raw)
    // Re-read on every change so both bar instances agree on placement.
    if (!store.centerStateLoaded) {
      store.centerStateLoaded = true
      if (parsed.lastSeen > 0) {
        store.lastSeen = parsed.lastSeen
      } else {
        // First run of this widget: history that predates it is old news.
        store.lastSeen = Date.now()
        store.scheduleCenterStateSave()
      }
    } else if (parsed.lastSeen > 0) {
      store.lastSeen = parsed.lastSeen
    }
    store.placement = parsed.placement
    store.mode = parsed.mode
    var screens = parsed.screens
    if (!Array.isArray(screens) || screens.length === 0) {
      var defaultScreen = store.defaultScreenName()
      screens = defaultScreen !== "" ? [defaultScreen] : []
      store.screensDefaulted = true
      // The bar's primaryScreen is the best default. Wait for shell.json so
      // the first saved screen is not an arbitrary output-order guess.
      if (store.shellConfigLoaded) store.scheduleCenterStateSave()
    } else {
      store.screensDefaulted = false
    }
    store.screenNames = store.cleanScreenNames(screens)
    if (parsed.screensLegacy) Qt.callLater(function() { store.flushScreens() })
    if (store.mode === "vertical" && store.placement.indexOf("top-") !== 0)
      store.placement = "top-" + store.placement.split("-")[1]
    store.marginX = parsed.marginX
    store.marginY = parsed.marginY
    store.padding = parsed.padding
    store.cardSpacing = parsed.cardSpacing
    store.confirmClear = parsed.confirmClear
    store.enterOpens = parsed.enterOpens
    store.shortcutBar = parsed.shortcutBar
    store.hideBodies = parsed.hideBodies
    store.showPreviews = parsed.showPreviews
    store.showBadge = parsed.showBadge
    store.searchKey = parsed.searchKey
    store.dndKey = parsed.dndKey
    store.detailKey = parsed.detailKey
    store.helpKey = parsed.helpKey
    store.settingsKey = parsed.settingsKey === "P" ? "P" : "s"
    store.recomputeUnseen()
  }

  function reloadState() {
    centerStateFile.reload()
    shellConfigFile.reload()
  }

  // ---- bar placement (read-only view of shell.json) ----

  function parseShellConfig(raw) {
    store.shellConfigLoaded = true
    var sections = ["left", "center", "right"]
    var sizes = ({})
    var found = ""
    var index = -1
    try {
      var config = JSON.parse(String(raw || "{}"))
      store.primaryScreenName = String(config && config.bar && config.bar.primaryScreen || "")
      if (store.screensDefaulted) {
        var defaultScreen = store.defaultScreenName()
        store.screenNames = defaultScreen !== "" ? [defaultScreen] : []
        store.screensDefaulted = false
        store.scheduleCenterStateSave()
      }
      var layout = (config && config.bar && config.bar.layout) || ({})
      for (var s = 0; s < sections.length; s++) {
        var list = layout[sections[s]]
        if (!Array.isArray(list)) list = []
        sizes[sections[s]] = list.length
        for (var i = 0; i < list.length; i++) {
          var entry = list[i]
          var id = entry && typeof entry === "object" ? String(entry.id || "") : String(entry || "")
          if (id === "apach.notifications") {
            found = sections[s]
            index = i
          }
        }
      }
    } catch (e) {
      return
    }
    store.barSizes = sizes
    store.barSection = found
    store.barIndex = index
  }

  function markSeen() {
    store.lastSeen = Date.now()
    store.recomputeUnseen()
    store.scheduleCenterStateSave()
  }

  function scheduleCenterStateSave() {
    if (!store.centerStateLoaded) return
    centerStateSaveTimer.restart()
  }

  function flushCenterState() {
    centerStateFile.setText(JSON.stringify({
      version: 1,
      lastSeen: store.lastSeen,
      placement: store.placement,
      mode: store.mode,
      screens: store.screenNames,
      marginX: store.marginX,
      marginY: store.marginY,
      padding: store.padding,
      cardSpacing: store.cardSpacing,
      confirmClear: store.confirmClear,
      enterOpens: store.enterOpens,
      shortcutBar: store.shortcutBar,
      hideBodies: store.hideBodies,
      showPreviews: store.showPreviews,
      showBadge: store.showBadge,
      searchKey: store.searchKey,
      dndKey: store.dndKey,
      detailKey: store.detailKey,
      helpKey: store.helpKey,
      settingsKey: store.settingsKey
    }) + "\n")
  }

  function defaultScreenName() {
    var screens = Quickshell.screens
    var primary = String(store.primaryScreenName || "")
    if (primary !== "") {
      for (var i = 0; i < screens.length; i++)
        if (String(screens[i].name) === primary) return primary
    }
    return screens && screens.length > 0 ? String(screens[0].name || "") : ""
  }

  function cleanScreenNames(value) {
    var out = []
    if (!Array.isArray(value)) return out
    for (var i = 0; i < value.length && out.length < 4; i++) {
      var name = String(value[i] || "")
      if (name !== "" && out.indexOf(name) === -1) out.push(name)
    }
    return out
  }

  function setScreenNames(value) {
    var next = store.cleanScreenNames(value)
    if (next.length === 0) return
    if (JSON.stringify(next) === JSON.stringify(store.screenNames)) return
    store.screenNames = next
    store.screensDefaulted = false
    // Move the toast with the center immediately; the service watches this
    // file. Patch only the screen list so a sibling bar instance's stale
    // placement/margins cannot be written back at the same time.
    if (store.centerStateLoaded) store.flushScreens()
    else store.scheduleCenterStateSave()
  }

  function flushScreens() {
    if (!store.centerStateLoaded) return
    var payload = ({})
    try {
      var parsed = JSON.parse(String(centerStateFile.text() || "").trim())
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) payload = parsed
    } catch (e) {
      payload = ({})
    }
    payload.version = 1
    payload.screens = store.screenNames
    delete payload.screen
    centerStateFile.setText(JSON.stringify(payload) + "\n")
  }

  function toggleScreen(name) {
    var target = String(name || "")
    if (target === "") return
    var next = store.screenNames.slice()
    var index = next.indexOf(target)
    if (index !== -1) {
      if (next.length <= 1) return
      next.splice(index, 1)
    } else {
      if (next.length >= 4) return
      next.push(target)
    }
    store.setScreenNames(next)
  }

  function setMode(value) {
    var next = String(value || "")
    if (["window", "horizontal", "vertical"].indexOf(next) === -1) return
    if (store.mode === next) return
    store.mode = next
    // A vertical band always hangs from the top; keep only its X anchor.
    if (next === "vertical" && store.placement.indexOf("top-") !== 0)
      store.placement = "top-" + store.placement.split("-")[1]
    store.scheduleCenterStateSave()
  }

  function setMargin(side, value) {
    var key = String(side || "").toLowerCase() === "x" ? "marginX" : "marginY"
    var next = Math.max(0, Math.min(64, Math.round(Number(value) || 0)))
    if (store[key] === next) return
    store[key] = next
    store.scheduleCenterStateSave()
  }

  function setPadding(value) {
    var next = Math.max(4, Math.min(32, Math.round(Number(value) || 0)))
    if (store.padding === next) return
    store.padding = next
    store.scheduleCenterStateSave()
  }

  function setCardSpacing(value) {
    var next = Math.max(2, Math.min(24, Math.round(Number(value) || 0)))
    if (store.cardSpacing === next) return
    store.cardSpacing = next
    store.scheduleCenterStateSave()
  }

  function setConfirmClear(value) {
    var next = !!value
    if (store.confirmClear === next) return
    store.confirmClear = next
    store.scheduleCenterStateSave()
  }

  function setEnterOpens(value) {
    var next = String(value || "") === "detail" ? "detail" : "app"
    if (store.enterOpens === next) return
    store.enterOpens = next
    store.scheduleCenterStateSave()
  }

  function setShortcutBar(value) {
    var next = !!value
    if (store.shortcutBar === next) return
    store.shortcutBar = next
    store.scheduleCenterStateSave()
  }

  function setHideBodies(value) {
    var next = !!value
    if (store.hideBodies === next) return
    store.hideBodies = next
    store.scheduleCenterStateSave()
  }

  function setShowPreviews(value) {
    var next = !!value
    if (store.showPreviews === next) return
    store.showPreviews = next
    store.scheduleCenterStateSave()
    if (!next && store.service && typeof store.service.purgeArchiveImages === "function")
      store.service.purgeArchiveImages()
  }

  function setShowBadge(value) {
    var next = !!value
    if (store.showBadge === next) return
    store.showBadge = next
    store.scheduleCenterStateSave()
  }

  function setSearchKey(value) {
    var next = String(value || "") === "ctrl+f" ? "ctrl+f" : "/"
    if (store.searchKey === next) return
    store.searchKey = next
    store.scheduleCenterStateSave()
  }

  function setDndKey(value) {
    var next = String(value || "") === "D" ? "D" : "d"
    if (store.dndKey === next) return
    store.dndKey = next
    store.scheduleCenterStateSave()
  }

  function setDetailKey(value) {
    var next = String(value || "") === "I" ? "I" : "i"
    if (store.detailKey === next) return
    store.detailKey = next
    store.scheduleCenterStateSave()
  }

  function setHelpKey(value) {
    var next = String(value || "") === "F1" ? "F1" : "?"
    if (store.helpKey === next) return
    store.helpKey = next
    store.scheduleCenterStateSave()
  }

  function setSettingsKey(value) {
    var next = String(value || "") === "P" ? "P" : "s"
    if (store.settingsKey === next) return
    store.settingsKey = next
    store.scheduleCenterStateSave()
  }

  function setPlacement(value) {
    var next = String(value || "")
    if (!/^(top|bottom|center)-(left|center|right)$/.test(next)) return
    if (store.placement === next) return
    store.placement = next
    store.scheduleCenterStateSave()
  }

  // ---- actions ----

  function enqueueAction(argv) {
    store.actionQueue = store.actionQueue.concat([argv])
    store.runNextAction()
  }

  function runNextAction() {
    if (actionProc.running || store.actionQueue.length === 0) return
    var argv = store.actionQueue[0]
    store.actionQueue = store.actionQueue.slice(1)
    actionProc.command = argv
    actionProc.running = true
  }

  // Remove one notification. The service owns both the live popup and the
  // archive, so one direct call forgets it from both without a subprocess.
  function deleteEntry(entry) {
    if (!entry || !entry.stem) return
    var stem = String(entry.stem)
    store.suppress(stem, 2500)

    if (store.service && typeof store.service.forgetEntry === "function") {
      store.service.forgetEntry(stem)
    } else {
      store.enqueueAction(["bash", "-c",
        'omarchy-shell -q notifications dismiss "$2" || true; rm -f "$1/$3.json"',
        "--", store.stateDir, String(entry.summary || ""), stem])
    }
    store.removeLocal(stem)
  }

  function removeLocal(stem) {
    var keep = function(e) { return e.stem !== stem }
    store.liveEntries = store.liveEntries.filter(keep)
    store.archiveEntries = store.archiveEntries.filter(keep)
    store.rebuildEntries()
  }

  // Dismiss every on-screen toast, then wipe the unified archive.
  function clearAll() {
    for (var i = 0; i < store.entries.length; i++) store.suppress(store.entries[i].stem, 3500)
    if (store.service) {
      store.service.clearPopups()
      if (typeof store.service.clearArchive === "function") store.service.clearArchive()
      else store.service.clearHistory()
    } else {
      store.enqueueAction(["bash", "-c",
        'omarchy-shell -q notifications dismissAll && omarchy-shell -q notifications clear', "--"])
    }
    store.liveEntries = []
    store.archiveEntries = []
    store.entries = []
    store.mergeSignature = ""
    store.recomputeUnseen()
  }

  function toggleDnd() {
    if (store.service) {
      store.service.setDoNotDisturb(!store.service.doNotDisturb)
      store.dnd = store.service.doNotDisturb === true
      return
    }
    store.enqueueAction(["omarchy-shell", "-q", "notifications", "toggleDnd"])
    // The service debounces its settings write; sync again shortly after.
    dndSyncTimer.restart()
  }

  // ---- processes ----

  Process {
    id: liveReadProc
    command: ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", store.stateDir]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: store.onLiveRead(text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: store.runNextAction()
  }

  // ---- files & timers ----

  FileView {
    id: settingsFile
    path: store.settingsPath
    watchChanges: false
    atomicWrites: false
    printErrors: false
    onLoaded: store.dnd = store.service ? store.service.doNotDisturb === true : Model.parseSettings(text()).dnd
    onLoadFailed: store.dnd = store.service ? store.service.doNotDisturb === true : false
  }

  FileView {
    id: centerStateFile
    path: store.centerStatePath
    watchChanges: true
    // In-place writes: an atomic rename would detach every other bar
    // instance's watcher from the old inode.
    atomicWrites: false
    printErrors: false
    onLoaded: store.loadCenterState(text())
    onLoadFailed: store.loadCenterState("")
    // watchChanges can miss a truncate+rewrite depending on timing; a
    // reload on the event and on open() keeps every instance in sync.
    onFileChanged: reload()
  }

  FileView {
    id: shellConfigFile
    path: store.home + "/.config/omarchy/shell.json"
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onLoaded: store.parseShellConfig(text())
  }

  // Directory watch for the fallback path only. The merged service pushes
  // live rows and archive changes through its properties, so the center has
  // no file watchers or polling while the service is live.
  FileView {
    id: liveDirWatch
    path: store.stateDir
    watchChanges: store.service === null
    printErrors: false
    onFileChanged: reloadTimer.restart()
  }

  Timer {
    id: reloadTimer
    interval: 150
    repeat: false
    onTriggered: store.refresh()
  }

  // While the center is open the provider polls faster so toasts appear as
  // they arrive; the directory watches usually fire first.
  Timer {
    id: openPollTimer
    interval: 2000
    repeat: true
    running: hostOpen && store.service === null
    onTriggered: store.refresh()
  }

  // Closed fallback, slow on purpose: the bar only needs the unread count.
  Timer {
    id: closedPollTimer
    interval: 60000
    repeat: true
    running: !hostOpen && store.service === null
    onTriggered: store.refresh()
  }

  Timer {
    id: dndSyncTimer
    interval: 500
    repeat: false
    onTriggered: store.refresh()
  }

  Timer {
    id: centerStateSaveTimer
    interval: 200
    repeat: false
    onTriggered: store.flushCenterState()
  }

  // Set by Panel.qml while it is loaded and open; defaults to closed.
  property bool hostOpen: false
}
