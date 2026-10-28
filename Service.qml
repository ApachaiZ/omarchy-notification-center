// Notification service for the omarchy shell.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  // History + DND live under XDG_STATE_HOME: they're persistent user state
  // (the notifications received, the last-set DND preference), not
  // regeneratable cache that a `rm -rf ~/.cache` should wipe.
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string settingsPath: stateDir + "notifications.json"
  readonly property string centerStatePath: stateDir + "notifications-center.json"
  // Toasts follow the center's horizontal side and top/bottom edge. A center
  // placement is clamped to the top: a toast never sits in the middle of the
  // screen.
  property string toastPlacement: "top-right"
  // Monitors chosen in the center settings, in selection order. Both
  // surfaces share the list; it is not derived from the focused output.
  property var toastScreenNames: []
  // One file per on-screen popup, so live toasts survive shell restarts.
  // A file exists exactly as long as its popup is showing: written when the
  // toast appears, moved into historyDir when it expires, is dismissed, or is
  // acted upon.
  readonly property string popupStateDir: stateDir + "notifications/"
  // The notifications that already left the screen, one file each, trimmed to
  // the newest historyLimit. This directory IS the history: `showHistory`
  // replays exactly what has been moved in here.
  readonly property string historyDir: popupStateDir + "history/"
  // Copies of the avatars/images persisted entries reference — the sender's
  // originals don't outlive the notification (see persistablePopup). Each
  // copy lives and dies with the JSON file whose stem it carries.
  readonly property string imagesDir: popupStateDir + "images/"
  // Corner radius is shared with the menu and shell panels.
  // It mirrors Hyprland's current decoration:rounding value.
  readonly property int cornerRadius: Style.cornerRadius
  // Toasts are fixed to the top-right corner. They only clear the omarchy bar
  // when the bar occupies the top or right edge, so left/bottom bars do not
  // pull notification popups away from the expected top-right location.
  // Falls back to the bar's default size (26 horizontal / 28 vertical) when
  // shell.bar isn't reachable so the popup never lands on top of the bar.
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property bool barVertical: barPosition === "left" || barPosition === "right"
  readonly property int defaultBarSize: barVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int liveBarSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize) : defaultBarSize
  readonly property int barClearance: liveBarSize + Style.gapsOut

  readonly property var toastScreens: {
    var screens = Quickshell.screens
    var names = service.toastScreenNames
    var out = []
    for (var i = 0; i < screens.length; i++) {
      var screenName = String(screens[i].name || "")
      if (names && names.indexOf(screenName) !== -1 && out.length < 4) out.push(screens[i])
    }
    // All selected outputs are gone (or settings have not loaded yet): keep
    // the toast visible on the first detected output instead of nowhere.
    if (out.length === 0 && screens.length > 0) out.push(screens[0])
    return out
  }

  // Live Notification objects by originalId, kept OUT of the ListModels: a
  // QObject stored in a model role becomes a dangling C++ pointer when the
  // server destroys the notification (sender close, DND untrack, dismiss),
  // and the next read of that role segfaults in QQmlListModel::data. A JS
  // map only holds a wrapper, which degrades to a catchable error instead.
  property var liveRefs: ({})

  // PersistentProperties handles in-process QML reloads. The on-disk
  // notifications.json file is the cross-restart backstop — its `dnd` key
  // is hydrated into persisted.doNotDisturb on startup and written back via
  // a debounced save timer.
  PersistentProperties {
    id: persisted
    reloadableId: "apach-notifications"
    property bool doNotDisturb: false
    onDoNotDisturbChanged: {
      // Suppress the write that load-time hydration would otherwise trigger.
      if (service._hydrating) return
      service.scheduleSettingsSave()
    }
  }

  // Guards onDoNotDisturbChanged while we're hydrating from disk so the
  // hydration assignment doesn't immediately schedule a write-back.
  property bool _hydrating: false

  readonly property alias doNotDisturb: persisted.doNotDisturb

  function setDoNotDisturb(value) {
    persisted.doNotDisturb = !!value
  }

  // popupModel feeds the on-screen toast stack — the only model the service
  // keeps. Everything a toast leaves behind lives on disk under historyDir.
  //
  // Aliased as a property so consumers outside this Item's id scope can bind
  // to it. QML ids aren't visible to external consumers without the alias.
  property alias popupModel: popupModel
  ListModel { id: popupModel }

  // Set by the center while it is open. Toasts stay in the model but their
  // surface is hidden so the two overlays cannot sit on top of each other.
  property bool centerOpen: false

  function setCenterOpen(value) {
    service.centerOpen = !!value
  }

  // One archive for both surfaces: a single in-memory list and a single JSON
  // file. The center reads it directly. The old per-file history directory is
  // read once at startup to migrate entries written by previous versions.
  readonly property int archiveRetentionDays: 30
  readonly property int archiveLimit: 1000
  // Kept beside settingsPath, not inside popupStateDir: restorePopupsProc
  // globs every *.json in the live directory.
  readonly property string archivePath: stateDir + "notifications-archive.json"
  readonly property string legacyArchivePath: home + "/.local/state/omarchy/notifications-center/archive.json"
  property var archiveEntries: []
  property bool archiveLoaded: false
  // Persisted image paths for live rows, keyed by stem. Archiving a toast uses
  // these copies instead of re-copying its sender-owned originals.
  property var persistedEntries: ({})
  property bool archiveFileLoaded: false
  property bool legacyArchiveLoaded: false
  property bool historyArchiveLoaded: false
  property bool archiveLoadStarted: false
  property bool legacyArchiveRequested: false
  property bool historyArchiveStarted: false
  property string archiveWriteSignature: ""

  // How many notifications the old history directory keeps. Only the legacy
  // replay path uses it now; the archive above is the real history.
  readonly property int historyLimit: 10

  readonly property int lowPopupDuration: 5000
  readonly property int normalPopupDuration: 8000
  readonly property int maxPopupDuration: 30000

  function durationFor(urgency, expireTimeout) {
    switch (urgency) {
    case NotificationUrgency.Critical:
      return 0
    case NotificationUrgency.Low:
      return Math.min(maxPopupDuration, Math.max(lowPopupDuration, requestedDuration(expireTimeout)))
    default:
      return Math.min(maxPopupDuration, Math.max(normalPopupDuration, requestedDuration(expireTimeout)))
    }
  }

  function requestedDuration(expireTimeout) {
    // FreeDesktop notification spec (and Quickshell) report expireTimeout in
    // milliseconds, so pass it through directly.
    var ms = Number(expireTimeout || 0)
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.round(ms)
  }

  // DND bypass: only let through notifications we trust to be intentional
  // and rare.
  //   - omarchy-action: a user-action confirmation toast ("Theme changed",
  //     "Screenshot saved"). The user JUST did something — their feedback
  //     should show.
  //   - urgency=critical AND app_name=notify-send: bare-CLI emergency alerts.
  //     Trusted because it's almost always omarchy or system shell scripts —
  //     chat apps set app_name to their brand (Discord/Slack/Vesktop), which
  //     falls outside this rule.
  function shouldBypassDnd(notification) {
    return NotificationLogic.shouldBypassDnd(notification, NotificationUrgency.Critical)
  }

  function snapshotOf(notification) {
    return NotificationLogic.snapshotOf(notification, Date.now())
  }

  // A notification nobody looks back at:
  //   - the freedesktop `transient` hint is set ("popup only, don't store")
  //   - app_name is "notify-send" (the CLI default — means the sender
  //     didn't bother declaring an identity, so it's almost certainly
  //     ephemeral test/feedback noise)
  //   - app_name is "omarchy-action" (Omarchy's own user-action toasts —
  //     the user just triggered them)
  // Their toasts still land in history like any other once they've been on
  // screen; the distinction only decides whether a DND-silenced one is worth
  // recording at all.
  function isEphemeral(notification) {
    var transient = false
    try {
      transient = !!(notification.hints && notification.hints["transient"])
    } catch (e) { transient = false }
    return transient || NotificationLogic.isEphemeralApp(String(notification.appName || ""))
  }

  // ---------------------------------------------------- unified archive

  function normalizeArchiveEntry(value) {
    var entry = NotificationLogic.historyEntry(value, NotificationUrgency.Normal)
    entry.stem = String((value && value.stem) || NotificationLogic.imageStem(entry))
    entry.source = "history"
    return entry
  }

  function archiveMigrationFlags(text) {
    var flags = { legacyMerged: false, historyMerged: false }
    try {
      var parsed = JSON.parse(String(text || ""))
      flags.legacyMerged = !!(parsed && parsed.legacyMerged)
      flags.historyMerged = !!(parsed && parsed.historyMerged)
    } catch (e) {
      // Missing or old archive: both legacy sources still need one merge.
    }
    return flags
  }

  function archiveDocuments(text) {
    var whole = null
    try { whole = JSON.parse(text) } catch (e) { whole = null }
    if (whole) {
      if (Array.isArray(whole)) return whole
      if (Array.isArray(whole.entries)) return whole.entries
      return []
    }
    // The legacy history directory is one compact JSON object per line.
    var out = []
    var lines = text.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var value = JSON.parse(line)
        if (value && typeof value === "object") out.push(value)
      } catch (e) {
        // Torn write from a crash mid-save — skip the line, keep the rest.
      }
    }
    return out
  }

  function mergeArchiveRaw(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var source = archiveDocuments(text)
    if (!source.length) return

    var byStem = {}
    for (var i = 0; i < service.archiveEntries.length; i++) {
      var old = service.archiveEntries[i]
      if (old && old.stem) byStem[old.stem] = old
    }
    for (var j = 0; j < source.length; j++) {
      var entry = normalizeArchiveEntry(source[j])
      if (entry.timestamp > 0) byStem[entry.stem] = entry
    }

    var merged = []
    for (var stem in byStem) merged.push(byStem[stem])
    merged.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })

    var cutoff = Date.now() - service.archiveRetentionDays * 86400000
    var keep = []
    var dropped = []
    for (var k = 0; k < merged.length; k++) {
      if ((merged[k].timestamp || 0) >= cutoff && keep.length < service.archiveLimit)
        keep.push(merged[k])
      else
        dropped.push(merged[k])
    }
    service.archiveEntries = keep
    if (service.archiveLoaded) service.cleanupImages(dropped)
  }

  function appendArchiveEntry(value) {
    if (!value) return
    var entry = normalizeArchiveEntry(value)
    if (!entry.timestamp || entry.timestamp <= 0) return
    var cutoff = Date.now() - service.archiveRetentionDays * 86400000
    if (entry.timestamp < cutoff) return

    var list = []
    var replaced = false
    for (var i = 0; i < service.archiveEntries.length; i++) {
      var old = service.archiveEntries[i]
      if (old && old.stem === entry.stem) {
        list.push(entry)
        replaced = true
      } else {
        list.push(old)
      }
    }
    if (!replaced) list.push(entry)
    list.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })

    var dropped = []
    if (list.length > service.archiveLimit) {
      dropped = list.slice(service.archiveLimit)
      list = list.slice(0, service.archiveLimit)
    }
    service.archiveEntries = list
    if (service.archiveLoaded) service.cleanupImages(dropped)
    service.scheduleArchiveSave()
  }

  function pruneArchive() {
    var list = service.archiveEntries.slice()
    list.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
    var cutoff = Date.now() - service.archiveRetentionDays * 86400000
    var keep = []
    var dropped = []
    for (var i = 0; i < list.length; i++) {
      if ((list[i].timestamp || 0) >= cutoff && keep.length < service.archiveLimit)
        keep.push(list[i])
      else
        dropped.push(list[i])
    }
    service.archiveEntries = keep
    service.cleanupImages(dropped)
  }

  function removeArchiveEntry(stem) {
    var needle = String(stem || "")
    if (!needle) return false
    var keep = []
    var removed = []
    for (var i = 0; i < service.archiveEntries.length; i++) {
      var entry = service.archiveEntries[i]
      if (entry && entry.stem === needle) removed.push(entry)
      else keep.push(entry)
    }
    if (removed.length === 0) return false
    service.archiveEntries = keep
    service.cleanupImages(removed)
    service.scheduleArchiveSave()
    return true
  }

  function clearArchive() {
    var removed = service.archiveEntries
    service.archiveEntries = []
    service.cleanupImages(removed)
    service.scheduleArchiveSave()
  }

  // Kept as the IPC-facing name used by `notifications clear`.
  function clearHistory() {
    service.clearArchive()
  }

  // Privacy toggle from the center: drop image copies belonging to archived
  // entries, but never touch images still needed by a live toast.
  function purgeArchiveImages() {
    var live = ({})
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (row) live[NotificationLogic.imageStem(row)] = true
    }
    var stems = []
    for (var j = 0; j < service.archiveEntries.length; j++) {
      var entry = service.archiveEntries[j]
      if (entry && entry.stem && !live[entry.stem]) stems.push(entry.stem)
    }
    if (stems.length === 0) return
    var command = ["bash", "-c",
      'dir="$1"; shift; for stem in "$@"; do rm -f "$dir/$stem"-*; done',
      "--", imagesDir]
    for (var k = 0; k < stems.length; k++) command.push(stems[k])
    enqueuePopupFileJob(command)
  }

  // Delete one notification by its file stem, whether it is still on screen
  // or already in the archive.
  function forgetEntry(stem) {
    var needle = String(stem || "")
    if (!needle) return false
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (row && NotificationLogic.imageStem(row) === needle) service.dismissPopup(i)
    }
    service.removeArchiveEntry(needle)
    return true
  }

  // Delete images belonging to archive entries that are leaving, unless a
  // live row or a surviving archive entry still references the same stem.
  function cleanupImages(entries) {
    if (!entries || entries.length === 0) return
    var keep = ({})
    for (var i = 0; i < service.archiveEntries.length; i++) {
      var kept = service.archiveEntries[i]
      if (kept && kept.stem) keep[kept.stem] = true
    }
    for (var j = 0; j < popupModel.count; j++) {
      var row = popupModel.get(j)
      if (row) keep[NotificationLogic.imageStem(row)] = true
    }
    var stems = []
    for (var k = 0; k < entries.length; k++) {
      var stem = String((entries[k] && entries[k].stem) || NotificationLogic.imageStem(entries[k] || {}))
      if (stem && !keep[stem] && stems.indexOf(stem) === -1) stems.push(stem)
    }
    if (stems.length === 0) return
    var command = ["bash", "-c",
      'dir="$1"; shift; for stem in "$@"; do rm -f "$dir/$stem"-*; done',
      "--", imagesDir]
    for (var n = 0; n < stems.length; n++) command.push(stems[n])
    enqueuePopupFileJob(command)
  }

  function scheduleArchiveSave() {
    if (!service.archiveLoaded) return
    archiveSaveTimer.restart()
  }

  function flushArchive() {
    if (!service.archiveLoaded) return
    var json = JSON.stringify({
      version: 1,
      legacyMerged: true,
      historyMerged: true,
      entries: service.archiveEntries
    }) + "\n"
    if (json === service.archiveWriteSignature) return
    service.archiveWriteSignature = json
    archiveFile.setText(json)
  }

  function maybeFinalizeArchive() {
    if (service.archiveLoaded) return
    if (!service.archiveFileLoaded || !service.legacyArchiveLoaded || !service.historyArchiveLoaded) return
    service.archiveLoaded = true
    service.pruneArchive()
    service.scheduleArchiveSave()
    service.sweepTempImages()
  }

  function sweepTempImages() {
    enqueuePopupFileJob(["bash", "-c", 'rm -f "$1"/*.tmp', "--", imagesDir])
  }

  function deleteLivePopupFile(row) {
    if (!row) return
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$2.json\"", "--",
      popupStateDir, NotificationLogic.imageStem(row)])
  }

  function writeArchiveEntry(entry, done) {
    if (!entry) {
      if (done) done()
      return
    }
    var persistable = NotificationLogic.persistablePopup(entry, imagesDir)
    function finish() {
      service.appendArchiveEntry(persistable.entry)
      if (done) done()
    }
    if (persistable.copies.length === 0) {
      finish()
      return
    }
    var command = ["bash", "-c", "mkdir -p \"$1\" || exit 0\nshift\n" + service.copyImagesScript, "--", imagesDir]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command, finish)
  }

  function handleNotification(notification) {
    // Without `tracked = true` the Notification object is destroyed as soon
    // as this signal handler returns, which would null out the `ref` we just
    // captured for the popup card.
    notification.tracked = true
    var snapshot = snapshotOf(notification)
    liveRefs[snapshot.originalId] = notification
    // Guard the delete: a newer notification may have reused this originalId
    // (freedesktop replaces_id) and taken over the map slot.
    notification.closed.connect(function() {
      if (service.liveRefs[snapshot.originalId] === notification)
        delete service.liveRefs[snapshot.originalId]
    })

    // DND bypass rules: chat apps abuse urgency=critical to force
    // visibility, so critical alone isn't enough — we also require the
    // sender to be CLI-style. See shouldBypassDnd().
    if (service.doNotDisturb && !shouldBypassDnd(notification)) {
      // The toast never shows, so the only record a silenced notification
      // can leave is a history entry. Write it straight into history —
      // "what did I miss while silenced" is exactly what history is for.
      if (!isEphemeral(notification)) {
        writeSilenced(notification, snapshot)
        return
      }
      delete liveRefs[snapshot.originalId]
      notification.tracked = false
      return
    }

    persistPopupFile(snapshot)
    watchForUpdates(notification, snapshot)
    // Qt.callLater avoids "QV4::Object::insertMember" crashes when a
    // Repeater is mid-incubation while we mutate its model.
    Qt.callLater(function() {
      removePopupsByOriginalId(snapshot.originalId, NotificationLogic.popupFileName(snapshot))
      popupModel.insert(0, snapshot)
      // An update that arrived while the insert was deferred found no row to
      // write to, and a property that already changed will not change again.
      // Reading the object once the row exists catches up on it.
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    })
  }

  // Persist a silenced notification, held tracked until its content is
  // stable: untracking tells the sender its notification closed (Chromium
  // then deletes its avatar file), and a replaces_id update lands on this
  // object without a second onNotification — releasing on a stale snapshot
  // would drop it. Each catch-up write reuses the original file identity.
  function writeSilenced(notification, written) {
    writeArchiveEntry(written, function() {
      var updated = null
      try {
        updated = NotificationLogic.replacementSnapshot(notification, written.originalId, written.timestamp)
      } catch (e) {
        // Torn down by the server while the write was queued.
      }
      if (updated && NotificationLogic.popupRowChanged(written, updated)) {
        service.writeSilenced(notification, updated)
        return
      }
      service.releaseSilenced(notification, written.originalId)
    })
  }

  // Let go of a DND-silenced notification once its history write has run.
  // The id may have been reused and the object torn down meanwhile.
  function releaseSilenced(notification, originalId) {
    if (liveRefs[originalId] === notification) delete liveRefs[originalId]
    try {
      notification.tracked = false
    } catch (e) {
      // Object already destroyed by the server — nothing left to release.
    }
  }

  // Everything the card draws. A change to any of these is a client updating
  // the notification in place, which is the only kind of update we ever hear
  // about after the popup exists.
  readonly property var updateSignals: [
    "summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
    "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"
  ]

  // A client that updates a notification through replaces_id does not produce
  // a second onNotification: the server writes the new content onto the object
  // we are already holding. The card draws a snapshot copied out of that
  // object — deliberately, since the object itself must stay out of the model
  // — so nothing reaches the screen until we copy it again.
  function watchForUpdates(notification, snapshot) {
    function refresh() {
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    }

    for (var i = 0; i < updateSignals.length; i++) {
      var signal = notification[updateSignals[i]]
      if (signal && typeof signal.connect === "function") signal.connect(refresh)
    }
  }

  function refreshPopup(notification, originalId, timestamp) {
    // A newer notification may have taken this id over, and the object may
    // outlive its popup — in both cases there is nothing here to refresh.
    if (service.liveRefs[originalId] !== notification) return

    var updated
    try {
      updated = NotificationLogic.replacementSnapshot(notification, originalId, timestamp)
    } catch (e) {
      // Object torn down by the server while the signal was in flight.
      return
    }

    var roles = NotificationLogic.popupRoles()
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId || row.timestamp !== timestamp) continue
      if (!NotificationLogic.popupRowChanged(row, updated)) return
      for (var r = 0; r < roles.length; r++) popupModel.setProperty(i, roles[r], updated[roles[r]])
      // The file name is the timestamp and id this popup was persisted under,
      // so the rewrite lands on the same file: a restart restores the version
      // last shown, and so does the copy that ends up in history.
      persistPopupFile(updated)
      return
    }
  }

  // A restored row carries an id from the previous server generation, and
  // the new server hands out ids from 1 again — so a fresh notification
  // with the same originalId is a coincidence, not the same notification.
  // The timestamp (via the file name) disambiguates: it travels with the
  // row through every model and file round-trip.
  function isRestoredRow(row) {
    return !!row && !!restoredPopups[NotificationLogic.popupFileName(row)]
  }

  // A notification arriving under an originalId a popup on screen already
  // holds supersedes it, so that row leaves the screen. Its file is deleted
  // rather than archived: the row taking its place archives itself when it
  // goes, and history would otherwise hold two entries for what the sender
  // means as one notification.
  // keepFileName is the replacement's own file: a same-millisecond
  // replacement shares the replaced row's filename, and the new write is
  // already queued — deleting that path here would erase the replacement's
  // only file.
  function removePopupsByOriginalId(originalId, keepFileName) {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId) continue
      // Not a replaces_id match — see isRestoredRow. Removing it here
      // would silently kill a restored critical alert on an unrelated ping.
      if (isRestoredRow(row)) continue
      if (NotificationLogic.popupFileName(row) !== keepFileName) {
        delete service.persistedEntries[NotificationLogic.imageStem(row)]
        deletePopupFileFor(row)
      }
      popupModel.remove(i)
    }
  }

  function dismissPopup(index) {
    removePopup(index, "dismiss")
  }

  function expirePopup(index) {
    removePopup(index, "expire")
  }

  function removePopup(index, reason) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    var originalId = entry ? entry.originalId : -1
    // A restored row has no live server object, and its old-generation id
    // may meanwhile belong to a fresh notification — resolving liveRefs by
    // id would dismiss that unrelated notification at the server.
    var restored = isRestoredRow(entry)
    var ref = !restored && originalId >= 0 ? liveRefs[originalId] : null
    // The popup is leaving the screen — for any reason — so its file must not
    // survive to the next shell restart. Its persisted copy becomes the newest
    // archive entry, and only the live JSON is deleted; archive images stay.
    if (entry) {
      if (entry.originalId >= 0) {
        var stem = NotificationLogic.imageStem(entry)
        service.appendArchiveEntry(service.persistedEntries[stem] || entry)
        delete service.persistedEntries[stem]
      }
      service.deleteLivePopupFile(entry)
      if (restored) delete restoredPopups[NotificationLogic.popupFileName(entry)]
    }
    popupModel.remove(index)
    if (ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (e) {
        // Object already torn down by the server — nothing to dismiss.
      }
    }
  }

  function clearPopups() {
    while (popupModel.count > 0) dismissPopup(0)
  }

  // Run the popup's click action, then dismiss. Omarchy's own toasts carry the
  // action as an argv vector in the `execArgv` role (see execArgvFromHints),
  // which the persistence files preserve, so restored toasts stay clickable.
  // Third-party clients register a libnotify action under the canonical
  // identifier "default" instead; that one only works while the sender is live.
  function invokePopupDefault(index) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)

    // Run the argv (via Util.execArgv, no shell interpretation). Detached so it
    // outlives the shell, which installer toasts depend on: they restart it.
    var argv = NotificationLogic.parseExecArgv(entry ? entry.execArgv : "")
    if (argv) {
      Util.execArgv(argv)
      dismissPopup(index)
      return
    }
    // Restored rows have no live actions, and looking up liveRefs by their
    // old-generation id could fire an unrelated fresh notification's action.
    var ref = entry && !isRestoredRow(entry) ? liveRefs[entry.originalId] : null
    var invoked = false
    try {
      if (ref && ref.actions) {
        for (var i = 0; i < ref.actions.length; i++) {
          var action = ref.actions[i]
          if (action && action.identifier === "default") {
            action.invoke()
            invoked = true
            break
          }
        }
      }
    } catch (e) {
      // Notification already torn down by the server — fall through to focus.
      console.warn("invoke default failed:", e)
    }
    // Chat apps (Slack, Discord, Vesktop, etc.) rarely register a "default"
    // libnotify action — they just expect clicking the notification to
    // focus their window. Fall back to focusing the sending app by class so
    // that click-to-jump actually works.
    if (!invoked) focusApp(entry)
    dismissPopup(index)
  }

  // Try to focus an existing Hyprland window matching the notification's
  // sender. The helper handles case-insensitive class matching.
  function focusApp(entry) {
    if (!entry || !entry.app) return
    focusAppProc.command = [
      service.omarchyPath + "/bin/omarchy-hyprland-focus-app",
      String(entry.app)
    ]
    focusAppProc.running = true
  }

  Process { id: focusAppProc; running: false }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", service.stateDir, service.popupStateDir, service.historyDir, service.imagesDir]
    running: false
    onExited: service.startArchiveLoad()
  }

  // ---------------------------------------------------- popup persistence
  //
  // Mirror every on-screen popup to its own file under popupStateDir so
  // toasts survive shell restarts (notably the restart `omarchy-update`
  // performs). Writes, moves and deletes go through one serialized queue: a
  // burst of replaces_id updates must not race a single reused Process, and
  // ordering guarantees a delete issued after a write wins.

  // Popups restored from a previous shell process, keyed by their file
  // name (timestamp-originalId) since ids alone repeat across server
  // generations. The replaces_id handling and liveRefs lookups must not
  // match these rows against fresh notifications.
  property var restoredPopups: ({})

  // Entries are either { command, done } for a file job or { read: true } for
  // a replay's directory read. Queueing the read rather than running it beside
  // the queue is what makes it a barrier: it takes its place in line, so the
  // history it sees is the one that existed when the replay was asked for.
  // Everything queued after it — a clear, an archive, a silenced write — waits
  // for it, and no amount of later traffic can push it back.
  property var popupFileQueue: []

  // Done callback of the job popupFileProc is currently running.
  property var runningPopupFileJobDone: null

  function enqueuePopupFileJob(command, done) {
    popupFileQueue = popupFileQueue.concat([{ command: command, done: done || null }])
    runNextPopupFileJob()
  }

  function enqueueHistoryRead() {
    popupFileQueue = popupFileQueue.concat([{ read: true }])
    runNextPopupFileJob()
  }

  function runNextPopupFileJob() {
    if (readHistoryProc.running || popupFileProc.running) return
    if (popupFileQueue.length === 0) return

    var job = popupFileQueue[0]
    popupFileQueue = popupFileQueue.slice(1)

    if (job.read) {
      startHistoryRead()
      return
    }

    popupFileProc.command = job.command
    service.runningPopupFileJobDone = job.done || null
    popupFileProc.running = true
  }

  Process {
    id: popupFileProc
    running: false
    onExited: {
      var done = service.runningPopupFileJobDone
      service.runningPopupFileJobDone = null
      if (done) {
        try {
          done()
        } catch (e) {
          console.warn("notifications: file job callback failed:", e)
        }
      }
      service.runNextPopupFileJob()
    }
  }

  // Consumes the remaining args as from/to pairs. Bounded read into a temp
  // file, validated, then renamed into place: the source path is
  // sender-controlled and may grow, block, or become a FIFO mid-copy, and
  // must neither hang the serialized queue nor fill the state dir.
  readonly property string copyImagesScript:
    "while (( $# >= 2 )); do\n" +
    "  if [[ -f $1 ]] && timeout 5 head -c 5242881 -- \"$1\" > \"$2.tmp\" 2>/dev/null &&\n" +
    "     (( $(stat -c%s -- \"$2.tmp\") <= 5242880 )); then mv -f -- \"$2.tmp\" \"$2\"; else rm -f -- \"$2.tmp\"; fi\n" +
    "  shift 2\n" +
    "done\n"

  function persistPopupFile(snapshot) {
    // The JSON travels as an argument, not through shell interpolation, so
    // summaries/bodies with quotes or backticks can't break the command. The
    // mkdir guards notifications that arrive before ensureDirsProc has run.
    // Copies run before the JSON referencing them, while the source exists.
    var persistable = NotificationLogic.persistablePopup(snapshot, imagesDir)
    service.persistedEntries[NotificationLogic.imageStem(snapshot)] = persistable.entry
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$2\" || exit 0\n" +
      "dir=\"$1\" json=\"$3\" name=\"$4\"\n" +
      "shift 4\n" +
      copyImagesScript +
      "printf '%s\\n' \"$json\" > \"$dir/$name\"", "--",
      popupStateDir,
      imagesDir,
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      NotificationLogic.popupFileName(snapshot)]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command)
  }

  function deletePopupFileFor(row) {
    if (!row) return
    // History replays and the "no recent notifications" placeholder never
    // had a file — rm -f on the computed paths is a harmless no-op there.
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$2.json\" \"$3/$2\"-*", "--",
      popupStateDir, NotificationLogic.imageStem(row), imagesDir])
  }

  Process {
    id: readHistoryProc
    running: false
    // Let the file queue go again, whatever the read did — a failed or empty
    // read must not leave archives and clears parked behind it forever.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replayHistory(text)
    }
  }

  // Toasts that were on screen when the replay was asked for. The clear in
  // replayHistory archives them, but the directory read is already in flight
  // by then, so they're handed over in memory instead of being waited for.
  property var replayCarryOver: []

  // Set from the moment a read is queued until it starts, so a second
  // showHistory while one is still waiting its turn doesn't queue another.
  property bool historyReadQueued: false

  // Re-show what's in historyDir as toasts. The read goes through the file
  // queue and its own subprocess, so the replay lands in replayHistory once
  // the work queued ahead of it has finished.
  function showRecentHistory() {
    if (readHistoryProc.running || service.historyReadQueued) return "ok"
    service.replayCarryOver = liveRowsForReplay()
    service.historyReadQueued = true
    enqueueHistoryRead()
    return "ok"
  }

  function startHistoryRead() {
    service.historyReadQueued = false
    readHistoryProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", historyDir]
    readHistoryProc.running = true
  }

  // Copy the on-screen rows out of the model. The placeholder from an earlier
  // empty replay carries originalId -1 and is not a notification, so it is
  // left behind rather than replayed as one. The replay dismisses these
  // notifications, and senders delete their images on close — so the carried
  // rows point at the persisted copies, like the archived files they join.
  function liveRowsForReplay() {
    var rows = []
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId < 0) continue
      rows.push(NotificationLogic.persistablePopup({
        id: row.id,
        originalId: row.originalId,
        app: row.app,
        appIcon: row.appIcon,
        summary: row.summary,
        body: row.body,
        image: row.image,
        glyph: row.glyph || "",
        execArgv: row.execArgv || "",
        urgency: row.urgency,
        timestamp: row.timestamp
      }, imagesDir).entry)
    }
    return rows
  }

  function replayHistory(raw) {
    var rows = NotificationLogic.historyRows(
      raw, service.replayCarryOver, NotificationUrgency.Normal, service.historyLimit)
    service.replayCarryOver = []

    // Replaying nothing at all looks like a dead keybinding, so say so.
    if (rows.length === 0) {
      popupModel.insert(0, {
        id: -1,
        originalId: -1,
        app: "omarchy-action",
        appIcon: "",
        summary: "No recent notifications",
        body: "",
        image: "",
        glyph: "󰂚",
        execArgv: "",
        urgency: NotificationUrgency.Low,
        expireTimeout: 0,
        timestamp: Date.now()
      })
      return
    }

    clearPopups()
    // Rows arrive newest-first, and index 0 is the top of the toast stack.
    for (var i = 0; i < rows.length; i++) {
      // Replayed rows are restored rows: their notification died with the
      // sender long ago, so they must never resolve to a live server object
      // that has since been handed their old id.
      service.restoredPopups[NotificationLogic.popupFileName(rows[i])] = true
      service.persistedEntries[NotificationLogic.imageStem(rows[i])] = rows[i]
      popupModel.append(rows[i])
    }
  }

  Process {
    id: restorePopupsProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restorePopups(text)
    }
  }

  function restorePopups(raw) {
    var entries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    var now = Date.now()
    var live = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var stem = NotificationLogic.imageStem(entry)
      service.persistedEntries[stem] = entry
      var duration = durationFor(entry.urgency, entry.expireTimeout)
      if (NotificationLogic.popupExpired(entry, duration, now)) {
        // It would have expired on screen had the shell kept running, so it
        // gets archived exactly like an expiry that happened while it did.
        service.appendArchiveEntry(entry)
        service.deleteLivePopupFile(entry)
        delete service.persistedEntries[stem]
        continue
      }
      // Survivors restart with a full lifetime on purpose: shell restarts
      // are rare, and a full look after the restart flicker beats resuming
      // a toast with a second left on its clock. The reset is persisted as
      // an absolute deadline so a second restart while the toast is still
      // on screen judges it by the reset clock, not the original timestamp.
      if (duration > 0) {
        entry.deadline = now + duration
        persistPopupFile(entry)
        // deadline is persistence metadata, not a model role — fresh rows
        // never carry it, and ListModel roles must stay consistent.
        delete entry.deadline
      }
      live.push(entry)
    }
    if (live.length === 0) return

    Qt.callLater(function() {
      for (var j = 0; j < live.length; j++) {
        var restored = live[j]
        // A notification received while the restore was reading the dir can
        // already occupy this originalId with the same timestamp — then it
        // IS this entry, live with its own file, and must be left alone. A
        // different timestamp is indistinguishable between a genuine
        // cross-restart replaces_id and a new-generation id coincidence, so
        // show both: a briefly duplicated toast beats silently dropping a
        // restored critical alert.
        var duplicate = false
        for (var k = 0; k < popupModel.count; k++) {
          var row = popupModel.get(k)
          if (row && row.originalId === restored.originalId && row.timestamp === restored.timestamp) {
            duplicate = true
            break
          }
        }
        if (duplicate) continue
        // Append (entries are newest-first) so restored toasts stack in
        // their original order below anything that just arrived. Restored
        // popups have no liveRefs entry — the server object died with the
        // old shell — so dismissal and action fallbacks degrade gracefully.
        service.restoredPopups[NotificationLogic.popupFileName(restored)] = true
        popupModel.append(restored)
      }
    })
  }

  // ---------------------------------------------------- settings persistence

  FileView {
    id: settingsFile
    path: service.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadSettings(text())
    // First-run: the file doesn't exist yet. Without this branch,
    // `settingsLoaded` stays false forever and `scheduleSettingsSave` becomes
    // a no-op — so the file is never created and the DND preference vanishes
    // on shell restart.
    onLoadFailed: service.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: service.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!service.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  property bool settingsLoaded: false

  function loadSettings(raw) {
    // FileView can fire onLoaded more than once during startup — the implicit
    // preload when `path` resolves, plus the explicit `settingsFile.reload()`
    // in Component.onCompleted can both end up calling here.
    if (service.settingsLoaded) return

    var parsed = NotificationLogic.parseSettings(raw)
    if (parsed.error) console.warn("notifications: settings parse failed:", parsed.errorMessage || "")

    if (parsed.dnd !== null) {
      service._hydrating = true
      persisted.doNotDisturb = parsed.dnd
      service._hydrating = false
    }

    service.settingsLoaded = true
    // Versions before the history moved into its own directory kept every
    // notification in here. Rewrite once so that dead payload doesn't sit in
    // the file until the next DND toggle happens to clear it.
    if (parsed.legacy) service.scheduleSettingsSave()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({ version: 3, dnd: persisted.doNotDisturb }, null, 2) + "\n")
  }

  FileView {
    id: centerStateFile
    path: service.centerStatePath
    watchChanges: true
    // The center writes in place; an atomic rename would detach this watcher.
    atomicWrites: false
    printErrors: false
    onLoaded: service.loadCenterState(text())
    onLoadFailed: service.loadCenterState("")
    onFileChanged: reload()
  }

  function loadCenterState(raw) {
    var text = String(raw || "").trim()
    if (!text) return
    var placement = ""
    try {
      var parsed = JSON.parse(text)
      var candidate = String((parsed && parsed.placement) || "")
      if (/^(top|bottom|center)-(left|center|right)$/.test(candidate))
        placement = candidate
    } catch (e) {
      // Torn or half-written state file: keep the last known placement.
      return
    }
    if (placement) {
      if (placement.indexOf("center-") === 0)
        placement = "top-" + placement.slice(7)
      service.toastPlacement = placement
    }
    var selected = []
    if (parsed && Array.isArray(parsed.screens)) {
      for (var i = 0; i < parsed.screens.length && selected.length < 4; i++) {
        var name = String(parsed.screens[i] || "")
        if (name !== "" && selected.indexOf(name) === -1) selected.push(name)
      }
    } else if (parsed && parsed.screen) {
      selected.push(String(parsed.screen))
    }
    if (selected.length > 0) service.toastScreenNames = selected
  }

  // ---------------------------------------------------- archive loading

  FileView {
    id: archiveFile
    path: service.archivePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (service.archiveFileLoaded) return
      var raw = text()
      var flags = service.archiveMigrationFlags(raw)
      service.mergeArchiveRaw(raw)
      service.archiveFileLoaded = true
      if (flags.legacyMerged) service.legacyArchiveLoaded = true
      else service.requestLegacyArchive()
      if (flags.historyMerged) service.historyArchiveLoaded = true
      else service.startHistoryArchiveLoad()
      service.maybeFinalizeArchive()
    }
    onLoadFailed: {
      if (service.archiveFileLoaded) return
      service.archiveFileLoaded = true
      service.requestLegacyArchive()
      service.startHistoryArchiveLoad()
      service.maybeFinalizeArchive()
    }
  }

  FileView {
    id: legacyArchiveFile
    path: service.legacyArchivePath
    watchChanges: false
    printErrors: false
    onLoaded: {
      if (!service.legacyArchiveRequested || service.legacyArchiveLoaded) return
      service.mergeArchiveRaw(text())
      service.legacyArchiveLoaded = true
      service.maybeFinalizeArchive()
    }
    onLoadFailed: {
      if (!service.legacyArchiveRequested || service.legacyArchiveLoaded) return
      service.legacyArchiveLoaded = true
      service.maybeFinalizeArchive()
    }
  }

  Process {
    id: historyArchiveProc
    running: false
    stdout: StdioCollector {
      id: historyArchiveStdout
      waitForEnd: true
      onStreamFinished: {
        service.mergeArchiveRaw(text)
        service.historyArchiveLoaded = true
        service.maybeFinalizeArchive()
      }
    }
    onExited: {
      if (!service.historyArchiveLoaded) {
        service.mergeArchiveRaw(historyArchiveStdout.text)
        service.historyArchiveLoaded = true
      }
      service.maybeFinalizeArchive()
    }
  }

  Timer {
    id: archiveSaveTimer
    interval: 500
    repeat: false
    onTriggered: service.flushArchive()
  }

  function startArchiveLoad() {
    if (service.archiveLoadStarted) return
    service.archiveLoadStarted = true
    archiveFile.reload()
  }

  function requestLegacyArchive() {
    if (service.legacyArchiveRequested) return
    service.legacyArchiveRequested = true
    legacyArchiveFile.reload()
  }

  function startHistoryArchiveLoad() {
    if (service.historyArchiveLoaded || service.historyArchiveStarted) return
    service.historyArchiveStarted = true
    historyArchiveProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", service.historyDir]
    historyArchiveProc.running = true
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    // Once mkdir has had a tick, load the existing settings file. FileView
    // surfaces an empty string when the file doesn't exist; loadSettings
    // handles that path.
    Qt.callLater(function() {
      settingsFile.reload()
      // Re-show popups that were on screen when the previous shell died.
      // The glob-through-bash tolerates a missing/empty dir (first run).
      // awk 1 (not cat) so a torn file missing its trailing newline can't
      // glue itself onto the next file and take a valid popup down with it.
      restorePopupsProc.command = ["bash", "-c",
        "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", service.popupStateDir]
      restorePopupsProc.running = true
    })
  }

  // ---------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      var on = v === "true" || v === "1" || v === "on" || v === "yes"
      service.setDoNotDisturb(on)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    // The center is the history surface now. Fall back to the upstream toast
    // replay when the bar host is not reachable.
    function showHistory(): string {
      if (service.shell && typeof service.shell.summon === "function"
          && service.shell.summon("apach.notifications", "{}")) return "ok"
      return service.showRecentHistory()
    }

    // `clear` forgets the recorded history; the toasts on screen stay put.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    function dismissAll(): string {
      service.clearPopups()
      return "ok"
    }

    // Dismiss the most recent popup.
    function dismissOne(): string {
      if (popupModel.count === 0) return "none"
      service.dismissPopup(0)
      return "ok"
    }

    // Fire the default action on the most recent popup, then dismiss it.
    function invokeLast(): string {
      if (popupModel.count === 0) return "none"
      service.invokePopupDefault(0)
      return "ok"
    }

    // Take a toast off the screen by summary substring, used by the
    // first-run notifications once their action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var hit = false
      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismissPopup(i)
          hit = true
        }
      }
      return hit ? "ok" : "none"
    }

    function archiveCount(): string { return String(service.archiveEntries.length) }

    function archiveReady(): string { return service.archiveLoaded ? "yes" : "no" }

    function ping(): string { return "ok" }
  }

  // ---------------------------------------------------- server

  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) {
      service.handleNotification(notification)
    }
  }

  // -------------------------------------------------------------- popup UI
  //
  // One PanelWindow per output (Variants on Quickshell.screens) holding the
  // stacked toast cards. Layer is Overlay, exclusionMode Ignore, no
  // keyboard focus — popups are passive surfaces and must never steal input
  // from the focused application.

  Variants {
    model: service.toastScreens

    PanelWindow {
      id: popupWindow
      required property var modelData
      screen: modelData
      visible: popupModel.count > 0 && !service.centerOpen

      WlrLayershell.namespace: "apach-notifications"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      readonly property var popupPlacement: NotificationLogic.popupPlacement(
        service.toastPlacement, service.barPosition, service.barClearance, Style.gapsOut)

      // Full-screen, fixed-size surface (like the OSD overlay). Adding or
      // removing a toast changes only the content inside; the Wayland surface
      // never resizes, so the compositor can't briefly scale a stale buffer --
      // which is what stretched/squished the cards during count changes.
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep the surface click-through except over the toast column, so the
      // rest of the (invisible) full-screen overlay never eats input.
      mask: Region { item: popupColumn }

      ColumnLayout {
        id: popupColumn
        readonly property var placement: popupWindow.popupPlacement
        readonly property string horizontalSide: placement.horizontal
        width: implicitWidth
        height: implicitHeight
        x: {
          if (placement.horizontal === "left") return placement.margins.left
          if (placement.horizontal === "center") return Math.round((popupWindow.width - width) / 2)
          return popupWindow.width - width - placement.margins.right
        }
        y: placement.vertical === "top"
          ? placement.margins.top
          : popupWindow.height - height - placement.margins.bottom
        spacing: Style.space(8)

        Repeater {
          model: popupModel

          // The delegate is a slot Item that owns lifetime timer state. The
          // actual visuals live in NotificationCard, which the history panel
          // also reuses.
          delegate: Item {
            id: cardSlot
            required property int index
            required property string app
            required property string appIcon
            required property string summary
            required property string body
            required property string image
            required property string glyph
            required property int urgency
            required property double expireTimeout
            required property double timestamp

            // Each card sizes itself based on mode (text vs media); the slot
            // tracks the card so the column auto-fits to whichever is widest.
            Layout.preferredWidth: card.implicitWidth
            Layout.alignment: popupColumn.horizontalSide === "left"
              ? Qt.AlignLeft
              : (popupColumn.horizontalSide === "center" ? Qt.AlignHCenter : Qt.AlignRight)
            implicitHeight: card.implicitHeight

            readonly property real lifetime: service.durationFor(cardSlot.urgency, cardSlot.expireTimeout)
            property real remainingLifetime: 1.0
            readonly property bool ticking: cardSlot.lifetime > 0 && !card.hovered

            // A client updating this notification in place rewrites the row
            // under the card (see refreshPopup). New text deserves a full look,
            // so the countdown starts over instead of running out the clock the
            // superseded text was already most of the way through. Delegates
            // keep their own row as the model changes around them, so only a
            // real content change lands here.
            onSummaryChanged: cardSlot.remainingLifetime = 1.0
            onBodyChanged: cardSlot.remainingLifetime = 1.0
            onImageChanged: cardSlot.remainingLifetime = 1.0

            Timer {
              interval: 50
              repeat: true
              running: cardSlot.ticking
              onTriggered: {
                if (cardSlot.lifetime <= 0) return
                cardSlot.remainingLifetime -= 50.0 / cardSlot.lifetime
                if (cardSlot.remainingLifetime <= 0) {
                  cardSlot.remainingLifetime = 0
                  service.expirePopup(cardSlot.index)
                }
              }
            }

            NotificationCard {
              id: card
              anchors.right: parent.right
              app: cardSlot.app
              appIcon: cardSlot.appIcon
              summary: cardSlot.summary
              body: cardSlot.body
              image: cardSlot.image
              urgency: cardSlot.urgency
              timestamp: cardSlot.timestamp
              cornerRadius: service.cornerRadius
              fontFamily: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""
              glyph: cardSlot.glyph

              onCloseRequested: service.dismissPopup(cardSlot.index)
              onCardClicked: service.invokePopupDefault(cardSlot.index)
            }
          }
        }
      }
    }
  }
}
