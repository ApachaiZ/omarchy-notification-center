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
  readonly property string archivePath: home + "/.local/state/omarchy/notifications-archive.json"
  readonly property string historyDir: stateDir + "/history"
  readonly property string engineRepoUrl: "https://github.com/ApachaiZ/omarchy-notification-engine"
  readonly property string engineDir: home + "/.config/omarchy/plugins/apach.notification-engine"
  readonly property string engineId: "apach.notification-engine"
  // Private archive written by the pre-3.0 monolithic plugin. v3 never reads
  // it; it is removed on upgrade unless the engine is enabled and can merge
  // it first. An installed-but-disabled engine must not keep it alive: it will
  // never run its migration, so the stock service would leave the data past
  // its retention.
  readonly property string legacyDir: home + "/.local/state/omarchy/notifications-center"

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
  property bool captureToasts: true
  // Engine execution/DND policy. Both default on for compatibility; app names
  // are sender-chosen, so these are the user's only control over spoofing.
  property bool allowExecActions: true
  property bool dndBypass: true
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
  property var archiveFileEntries: []
  property var historyEntries: []
  property var archiveEntries: []
  property var entries: []
  property string mergeSignature: ""
  // Raw file snapshots: a directory watch or a fallback poll often re-reads
  // unchanged files. Skip parsing and hashing when the bytes did not change.
  property string lastLiveRaw: ""
  property string lastHistoryRaw: ""
  property string lastArchiveRaw: ""

  // ---- action queue (one serialized Process for all mutating actions) ----
  property var actionQueue: []
  // Two-step install for the optional engine: the first click arms, the second
  // installs. The warning is visible in the settings row.
  property bool engineInstallArmed: false

  // Stems whose files we just deleted ourselves. The service may still be
  // mid-archive (or the dir watch may fire on a file that is about to
  // vanish), so reads within this window drop these rows instead of
  // resurrecting them. Keyed by stem, valued by expiry timestamp.
  property var suppressedStems: ({})

  // ---- lifecycle ----

  Component.onCompleted: {
    store.refresh()
    store.cleanupLegacyArchive()
    // FileView can fire onLoaded more than once during startup; the guard
    // inside loadCenterState handles that.
    Qt.callLater(function() { centerStateFile.reload() })
  }

  property bool legacyCleanupStarted: false
  property bool engineEnabled: false
  property string engineVersion: ""
  property bool engineManifestLoaded: false
  property bool engineVersionSafe: false
  property bool engineUpdateAttempted: false

  // The v3 center keeps no private archive. With the stock service the old
  // v1.6 archive would otherwise sit on disk forever, past its retention and
  // after "Clear all". Only an enabled engine whose manifest is at least
  // 1.0.4 can safely own the migration: older engines dropped expired entries
  // without deleting their images. Wait for both shell.json and the engine
  // manifest so the decision is based on configuration and version.
  function cleanupLegacyArchive() {
    if (!store.shellConfigLoaded || !store.engineManifestLoaded) return
    if (store.legacyCleanupStarted) return
    store.legacyCleanupStarted = true
    legacyCleanupProc.running = true
  }

  function maybeUpdateEngine() {
    if (!store.engineEnabled || !store.engineManifestLoaded) return
    if (store.engineVersionSafe || store.engineUpdateAttempted) return
    store.engineUpdateAttempted = true
    engineUpdateProc.running = true
  }

  // ---- data ----

  function refresh() {
    if (!liveReadProc.running) liveReadProc.running = true
    if (!historyReadProc.running) historyReadProc.running = true
    archiveFile.reload()
    settingsFile.reload()
  }

  function onLiveRead(raw) {
    if (raw === store.lastLiveRaw) return
    store.lastLiveRaw = raw
    store.liveEntries = store.filterSuppressed(Model.parseEntries(raw, "live"))
    store.rebuildEntries()
  }

  function onHistoryRead(raw) {
    if (raw === store.lastHistoryRaw) return
    store.lastHistoryRaw = raw
    store.historyEntries = store.filterSuppressed(Model.parseEntries(raw, "history"))
    store.rebuildArchive()
  }

  function onArchiveLoaded(raw) {
    if (raw === store.lastArchiveRaw) return
    store.lastArchiveRaw = raw
    store.archiveFileEntries = store.filterSuppressed(Model.parseArchive(raw))
    store.rebuildArchive()
  }

  function rebuildArchive() {
    // The engine writes one archive JSON; the stock service writes one file
    // per entry under history/. Merge both so the center works with either.
    store.archiveEntries = Model.mergeEntries(store.archiveFileEntries, store.historyEntries)
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
    store.captureToasts = parsed.captureToasts !== false
    store.allowExecActions = parsed.allowExecActions !== false
    store.dndBypass = parsed.dndBypass !== false
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
    var config
    try {
      config = JSON.parse(String(raw || "{}"))
    } catch (e) {
      return
    }
    store.shellConfigLoaded = true
    store.engineEnabled = Model.engineEnabledFromShellConfig(raw, store.engineId)
    store.maybeUpdateEngine()
    store.cleanupLegacyArchive()
    var sections = ["left", "center", "right"]
    var sizes = ({})
    var found = ""
    var index = -1
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
      captureToasts: store.captureToasts,
      allowExecActions: store.allowExecActions,
      dndBypass: store.dndBypass,
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
    // The engine implements this; the stock service ignores the unknown IPC.
    if (!next) store.enqueueAction(["omarchy-shell", "-q", "notifications", "purgeImages"])
  }

  function setShowBadge(value) {
    var next = !!value
    if (store.showBadge === next) return
    store.showBadge = next
    store.scheduleCenterStateSave()
  }

  function setAllowExecActions(value) {
    var next = !!value
    if (store.allowExecActions === next) return
    store.allowExecActions = next
    store.scheduleCenterStateSave()
  }

  function setDndBypass(value) {
    var next = !!value
    if (store.dndBypass === next) return
    store.dndBypass = next
    store.scheduleCenterStateSave()
  }

  function setCaptureToasts(value) {
    var next = !!value
    if (store.captureToasts === next) return
    store.captureToasts = next
    // The engine watches notifications-center.json and applies this. The
    // stock service ignores it and always keeps its own history.
    store.scheduleCenterStateSave()
  }

  function installEngine() {
    if (!store.engineInstallArmed) {
      store.engineInstallArmed = true
      engineArmTimer.restart()
      return
    }
    store.engineInstallArmed = false
    engineArmTimer.stop()
    // If the engine is already installed but disabled, enable it; otherwise
    // install it from its repository. Passing paths/URLs as arguments keeps
    // the script free of shell interpolation.
    store.enqueueAction(["bash", "-c",
      'if [[ -d "$1" ]]; then\n' +
      '  omarchy plugin update apach.notification-engine --yes >/dev/null 2>&1 || true\n' +
      '  omarchy plugin enable apach.notification-engine\n' +
      'else\n' +
      '  omarchy plugin add "$2" --enable --yes\n' +
      'fi', "--", store.engineDir, store.engineRepoUrl])
  }

  Timer {
    id: engineArmTimer
    interval: 4000
    repeat: false
    onTriggered: store.engineInstallArmed = false
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
    store.suppress(stem, 3000)
    // The engine's `forget` IPC removes an archive entry. The stock service
    // ignores it and only knows its per-file history, so with the engine
    // disabled the center must also remove the entry from the engine archive
    // it is displaying. Do that directly only when shell.json is loaded and
    // the engine is off, so it can never race a live engine writer.
    var direct = store.shellConfigLoaded && !store.engineEnabled
    store.enqueueAction(["bash", "-c",
      "omarchy-shell -q notifications dismiss \"$2\" || true\n" +
      "omarchy-shell -q notifications forget \"$3\" >/dev/null 2>&1 || true\n" +
      "sleep 0.3\n" +
      "rm -f \"$1/$3.json\" \"$1/history/$3.json\" \"$1/images/$3\"-*\n" +
      "if [[ \"$4\" == \"direct\" && -f \"$5\" ]] && command -v jq >/dev/null 2>&1; then\n" +
      "  umask 077\n" +
      "  tmp=\"$5.tmp\"\n" +
      "  jq --arg stem \"$3\" 'if (.entries|type)==\"array\" then .entries |= map(select(.stem != $stem)) else . end' \"$5\" > \"$tmp\" && chmod 600 \"$tmp\" && mv -f \"$tmp\" \"$5\" || rm -f \"$tmp\"\n" +
      "fi",
      "--", store.stateDir, String(entry.summary || ""), stem,
      direct ? "direct" : "ipc", store.archivePath])
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
    var direct = store.shellConfigLoaded && !store.engineEnabled
    store.enqueueAction(["bash", "-c",
      'omarchy-shell -q notifications dismissAll || true\n' +
      'omarchy-shell -q notifications clear || true\n' +
      'rm -rf -- "$1"\n' +
      'if [[ "$2" == "direct" && -f "$3" ]] && command -v jq >/dev/null 2>&1; then\n' +
      '  umask 077\n' +
      '  tmp="$3.tmp"\n' +
      '  jq \'if (.entries|type)=="array" then .entries = [] else . end\' "$3" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$3" || rm -f "$tmp"\n' +
      'fi\n' +
      '[[ "$2" == "direct" ]] && rm -f "$4"/*',
      "--", store.legacyDir, direct ? "direct" : "ipc", store.archivePath,
      store.stateDir + "/images"])
    store.liveEntries = []
    store.archiveEntries = []
    store.entries = []
    store.mergeSignature = ""
    store.recomputeUnseen()
  }

  function toggleDnd() {
    store.enqueueAction(["omarchy-shell", "-q", "notifications", "toggleDnd"])
    // The active service debounces its settings write; sync again shortly.
    dndSyncTimer.restart()
  }

  function setCenterOpen(value) {
    // The engine uses this to hide toasts while the center is open. The stock
    // service ignores the unknown IPC.
    store.enqueueAction(["omarchy-shell", "-q", "notifications", "setCenterOpen",
      value ? "true" : "false"])
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
    id: legacyCleanupProc
    command: ["bash", "-c",
      '[[ -d "$3" ]] || exit 0\n[[ "$1" == "enabled" && "$2" == "safe" ]] && exit 0\nrm -rf -- "$3"',
      "--", store.engineEnabled ? "enabled" : "disabled",
      store.engineVersionSafe ? "safe" : "unsafe", store.legacyDir]
    running: false
  }

  // An existing installation can have an old engine enabled while the center
  // is updated. Update it once per session; a live keepLoaded service still
  // needs the next shell restart, but the legacy cleanup above falls back to
  // the center until then. omarchy plugin update rescans plugins.
  Process {
    id: engineUpdateProc
    command: ["omarchy", "plugin", "update", "apach.notification-engine", "--yes"]
    running: false
    onExited: engineManifestFile.reload()
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

  // The engine version decides whether it can own the pre-3.0 migration. An
  // installed-but-disabled engine has no manifest loaded here only if the
  // directory is missing; that is treated as unsafe and cleaned by the center.
  FileView {
    id: engineManifestFile
    path: store.engineDir + "/manifest.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      store.engineVersion = Model.manifestVersion(text())
      store.engineVersionSafe = Model.versionAtLeast(store.engineVersion, "1.0.5")
      store.engineManifestLoaded = true
      store.maybeUpdateEngine()
      store.cleanupLegacyArchive()
    }
    onLoadFailed: {
      if (store.engineManifestLoaded) return
      store.engineVersion = ""
      store.engineVersionSafe = false
      store.engineManifestLoaded = true
      store.cleanupLegacyArchive()
    }
    onFileChanged: reload()
  }

  // The optional engine writes one archive JSON; the stock service writes one
  // file per entry under history/. Read both so either service works.
  FileView {
    id: archiveFile
    path: store.archivePath
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onLoaded: store.onArchiveLoaded(text())
    onLoadFailed: store.onArchiveLoaded("")
    onFileChanged: reload()
  }

  // Directory watches are the primary trigger. The timers are only a safety
  // net for filesystems where a directory watch does not fire.
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

  // While the center is open, poll slowly as a fallback; the watches usually
  // fire first. Reading the whole history every few seconds was wasteful.
  Timer {
    id: openPollTimer
    interval: 15000
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

  // Set by Panel.qml while it is loaded and open; defaults to closed.
  property bool hostOpen: false
}
