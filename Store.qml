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
  readonly property string historyDir: stateDir + "/history"
  readonly property string imagesDir: stateDir + "/images"
  readonly property string settingsPath: home + "/.local/state/omarchy/notifications.json"
  readonly property string centerStatePath: home + "/.local/state/omarchy/notifications-center.json"
  readonly property string archiveDir: home + "/.local/state/omarchy/notifications-center"
  readonly property string archivePath: archiveDir + "/archive.json"
  readonly property string archiveImagesDir: archiveDir + "/images"

  property bool dnd: false
  property double lastSeen: 0
  property bool centerStateLoaded: false
  property int unseenCount: 0

  // Center placement, persisted next to lastSeen. `placement` is
  // "<top|bottom>-<left|center|right>"; margins are screen-edge insets.
  property string placement: "top-right"
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
  property var historyEntries: []
  property var serviceEntries: []
  property var entries: []
  property string mergeSignature: ""

  // Private 30-day archive. The shell service keeps a short rolling history,
  // so older notifications are mirrored here; the same list feeds the UI.
  readonly property int retentionDays: 30
  readonly property int maxArchivedEntries: 1000
  property var archiveEntries: []
  property bool archiveLoaded: false
  property string archiveSignature: ""

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

  function refresh() {
    if (!liveReadProc.running) liveReadProc.running = true
    if (!historyReadProc.running) historyReadProc.running = true
    settingsFile.reload()
  }

  function onLiveRead(raw) {
    store.liveEntries = store.filterSuppressed(Model.parseEntries(raw, "live"))
    store.refreshServiceEntries()
  }

  function onHistoryRead(raw) {
    store.historyEntries = store.filterSuppressed(Model.parseEntries(raw, "history"))
    store.refreshServiceEntries()
  }

  function refreshServiceEntries() {
    store.serviceEntries = Model.mergeEntries(store.liveEntries, store.historyEntries)
    store.ingestArchive()
    store.applyMerge()
  }

  function applyMerge() {
    var merged = Model.mergeEntries(store.serviceEntries, store.archiveEntries)
    var sig = Model.signature(merged)
    if (sig === store.mergeSignature) return
    store.entries = merged
    store.mergeSignature = sig
    store.recomputeUnseen()
  }

  // ---- private 30-day archive ----

  function localizeArchivePath(value) {
    var v = String(value || "")
    if (v.length === 0) return ""
    var filePrefix = "file://" + store.imagesDir + "/"
    var plainPrefix = store.imagesDir + "/"
    if (v.indexOf(filePrefix) === 0)
      return "file://" + store.archiveImagesDir + "/" + v.slice(filePrefix.length)
    if (v.indexOf(plainPrefix) === 0)
      return store.archiveImagesDir + "/" + v.slice(plainPrefix.length)
    return v
  }

  function parseArchive(raw) {
    var text = String(raw || "").trim()
    if (!text) return []
    try {
      var parsed = JSON.parse(text)
      var list = Array.isArray(parsed) ? parsed : (parsed && parsed.entries)
      if (!Array.isArray(list)) return []
      var out = []
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        if (!e || !e.stem) continue
        var timestamp = Number(e.timestamp) || 0
        if (timestamp <= 0) continue
        out.push({
          id: Number(e.id || 0),
          originalId: Number(e.originalId || 0),
          app: String(e.app || ""),
          appIcon: store.localizeArchivePath(e.appIcon),
          summary: String(e.summary || ""),
          body: String(e.body || ""),
          image: store.localizeArchivePath(e.image),
          glyph: String(e.glyph || ""),
          execArgv: String(e.execArgv || ""),
          urgency: typeof e.urgency === "number" ? e.urgency : 1,
          timestamp: timestamp,
          stem: String(e.stem),
          source: String(e.source || "history")
        })
      }
      return out
    } catch (e) {
      return []
    }
  }

  function pruneArchive(list) {
    var cutoff = Date.now() - store.retentionDays * 86400000
    var out = []
    for (var i = 0; i < list.length; i++)
      if (Number(list[i].timestamp) >= cutoff) out.push(list[i])
    if (out.length > store.maxArchivedEntries) out = out.slice(0, store.maxArchivedEntries)
    return out
  }

  function loadArchive(raw) {
    store.archiveLoaded = true
    store.archiveEntries = store.parseArchive(raw)
    store.archiveSignature = Model.signature(store.archiveEntries)
    // Service entries may have arrived first; fold them in and refresh the list.
    store.ingestArchive()
    store.applyMerge()
  }

  function ingestArchive() {
    if (!store.archiveLoaded) return
    var merged = store.pruneArchive(Model.mergeEntries(store.serviceEntries, store.archiveEntries))
    var sig = Model.signature(merged)
    if (sig === store.archiveSignature) return
    store.archiveEntries = merged
    store.archiveSignature = sig
    store.scheduleArchiveSave()
  }

  function scheduleArchiveSave() {
    if (!store.archiveLoaded) return
    archiveSaveTimer.restart()
    if (store.showPreviews) imagesCopyTimer.restart()
  }

  function purgeArchiveImages() {
    if (!purgeImagesProc.running) purgeImagesProc.running = true
  }

  function flushArchive() {
    archiveFile.setText(JSON.stringify({ version: 1, entries: store.archiveEntries }) + "\n")
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
    var sections = ["left", "center", "right"]
    var sizes = ({})
    var found = ""
    var index = -1
    try {
      var config = JSON.parse(String(raw || "{}"))
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
    if (next) imagesCopyTimer.restart()
    else purgeArchiveImages()
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

  // Remove one notification. A live popup is dismissed through the service
  // (so it leaves the screen immediately); its persisted file is deleted in
  // both possible locations since the service may archive it concurrently.
  function deleteEntry(entry) {
    if (!entry || !entry.stem) return
    var stem = String(entry.stem)
    store.suppress(stem, 2500)

    if (entry.source === "live") {
      store.enqueueAction(["bash", "-c",
        'omarchy-shell -q notifications dismiss "$2" || true; rm -f "$1/$3.json" "$4/$3.json" "$5/$3"-* "$6/$3"-*',
        "--", store.stateDir, String(entry.summary || ""), stem, store.historyDir, store.imagesDir, store.archiveImagesDir])
    } else {
      store.enqueueAction(["bash", "-c",
        'rm -f "$1/$2.json" "$3/$2"-* "$4/$2"-*', "--", store.historyDir, stem, store.imagesDir, store.archiveImagesDir])
    }
    store.removeLocal(stem)
  }

  function removeLocal(stem) {
    var keep = function(e) { return e.stem !== stem }
    store.liveEntries = store.liveEntries.filter(keep)
    store.historyEntries = store.historyEntries.filter(keep)
    store.serviceEntries = Model.mergeEntries(store.liveEntries, store.historyEntries)
    store.archiveEntries = store.archiveEntries.filter(keep)
    store.archiveSignature = Model.signature(store.archiveEntries)
    store.scheduleArchiveSave()
    store.applyMerge()
  }

  // Dismiss every on-screen toast, then wipe the history and the private
  // archive. The shell service keeps its own copy; both are cleared.
  function clearAll() {
    for (var i = 0; i < store.entries.length; i++) store.suppress(store.entries[i].stem, 3500)
    store.enqueueAction(["bash", "-c",
      'omarchy-shell -q notifications dismissAll && omarchy-shell -q notifications clear', "--"])
    store.liveEntries = []
    store.historyEntries = []
    store.serviceEntries = []
    store.archiveEntries = []
    store.archiveSignature = ""
    store.scheduleArchiveSave()
    store.purgeArchiveImages()
    store.entries = []
    store.mergeSignature = ""
    store.recomputeUnseen()
  }

  function toggleDnd() {
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
    id: historyReadProc
    command: ["bash", "-c", "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", store.historyDir]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: store.onHistoryRead(text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: store.runNextAction()
  }

  Process {
    id: imagesCopyProc
    command: ["bash", "-c",
      'mkdir -p "$1"; [ "$3" = "1" ] && cp -n "$2"/* "$1"/ 2>/dev/null || true; find "$1" -type f -mtime +31 -delete 2>/dev/null || true',
      "--", store.archiveImagesDir, store.imagesDir, store.showPreviews ? "1" : "0"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: purgeImagesProc
    command: ["bash", "-c", 'rm -rf "$1"/* 2>/dev/null || true', "--", store.archiveImagesDir]
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: imagesCopyTimer
    interval: 1500
    repeat: false
    onTriggered: if (!imagesCopyProc.running) imagesCopyProc.running = true
  }

  // ---- files & timers ----

  FileView {
    id: settingsFile
    path: store.settingsPath
    watchChanges: false
    atomicWrites: false
    printErrors: false
    onLoaded: store.dnd = Model.parseSettings(text()).dnd
    onLoadFailed: store.dnd = false
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

  FileView {
    id: archiveFile
    path: store.archivePath
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onLoaded: store.loadArchive(text())
    onLoadFailed: store.loadArchive("")
    onFileChanged: reload()
  }

  Process {
    id: ensureArchiveDir
    command: ["mkdir", "-p", store.archiveDir]
    Component.onCompleted: running = true
    onExited: archiveFile.reload()
  }

  // Directory watches for live updates. They can go quiet after rapid
  // changes (see Bar.qml), so the poll timers below are the backstop.
  FileView {
    id: liveDirWatch
    path: store.stateDir
    watchChanges: true
    printErrors: false
    onFileChanged: reloadTimer.restart()
  }

  FileView {
    id: historyDirWatch
    path: store.historyDir
    watchChanges: true
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
    running: hostOpen
    onTriggered: store.refresh()
  }

  // Closed fallback, slow on purpose: the bar only needs the unread count.
  Timer {
    id: closedPollTimer
    interval: 60000
    repeat: true
    running: !hostOpen
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

  Timer {
    id: archiveSaveTimer
    interval: 1000
    repeat: false
    onTriggered: store.flushArchive()
  }

  // Set by Panel.qml while it is loaded and open; defaults to closed.
  property bool hostOpen: false
}
