// Data helpers for the apach.notifications center.
//
// Entries are parsed from the same single-line JSON files the shell's
// notification service persists: live popups at the state root, archived
// ones under history/. File format owned by
// /usr/share/omarchy/shell/plugins/notifications/NotificationLogic.js.

// ---- body sanitizing -----------------------------------------------------
//
// Copied from NotificationLogic.js (the service's own sanitizer) so the
// center renders bodies exactly like the toasts do. The body renders as
// StyledText, and a remote <img src> would make the shell issue an
// unauthenticated GET — so image tags go before the renderer sees them.
// Do not "simplify": the whole-tag walk below is the conservative bound
// measured against Qt's own parser.

function isChromiumDerived(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return source.indexOf("chrom") >= 0 || source.indexOf("brave") >= 0 ||
         source.indexOf("vivaldi") >= 0 || source.indexOf("microsoft-edge") >= 0 ||
         source.indexOf("opera") >= 0
}

function isImageTag(tag) {
  var name = /^<[^A-Za-z0-9]*([A-Za-z0-9]+)/.exec(tag)
  return !!name && name[1].toLowerCase() === "img"
}

function stripImageTags(text) {
  var out = ""
  var i = 0

  while (i < text.length) {
    var open = text.indexOf("<", i)
    if (open === -1) {
      out += text.slice(i)
      break
    }

    out += text.slice(i, open)

    var close = text.indexOf(">", open)
    var tag = close === -1 ? text.slice(open) : text.slice(open, close + 1)

    if (!isImageTag(tag)) out += tag
    i = close === -1 ? text.length : close + 1
  }

  return out
}

// Values that can be loaded without a network request. See
// NotificationLogic.js in the shell's notification service: remote schemes are
// dropped so an untrusted notification cannot turn an image into a request.
function safeImageSource(value) {
  var s = String(value || "")
  if (!s) return ""
  if (s.indexOf("file://") === 0 || s.indexOf("image://") === 0) return s
  if (s.charAt(0) === "/") return s
  return ""
}

function safeAppIcon(value) {
  var s = String(value || "")
  if (!s) return ""
  if (s.indexOf("file://") === 0 || s.indexOf("image://") === 0) return s
  if (s.charAt(0) === "/") return s
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(s)) return ""
  return s
}

// The active service may be the stock one, or an older archive restored from
// disk. Either way the files are untrusted input, so bound what the center
// keeps in memory and draws. Same caps as the engine.
var MAX_APP_LENGTH = 256
var MAX_GLYPH_LENGTH = 16
var MAX_SUMMARY_LENGTH = 512
var MAX_BODY_LENGTH = 8192

function clipText(value, max) {
  var text = String(value || "").replace(/\u0000/g, "")
  return text.length > max ? text.slice(0, max) : text
}

function imageStem(timestamp, originalId) {
  var ts = Number(timestamp || 0)
  var id = Number(originalId || 0)
  if (!isFinite(ts) || ts < 0) ts = 0
  if (!isFinite(id) || id < 0) id = 0
  return String(Math.trunc(ts)) + "-" + String(Math.trunc(id))
}

function styledSanitizedBody(text) {
  return stripImageTags(String(text || "").replace(/\r\n|\r|\n/g, "<br/>"))
}

function styledBody(body, app, appIcon) {
  return styledSanitizedBody(sanitizeBody(body, app, appIcon))
}

function sanitizeBody(body, app, appIcon) {
  var text = stripImageTags(String(body || ""))
  if (!isChromiumDerived(app, appIcon)) return text

  return text
    .replace(/^\s*<a\b[^>]*>\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^<\s]*)?\s*<\/a>\s*/i, "")
    .replace(/^\s*(?:https?:\/\/|www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/\S*)?\s+/i, "")
}

// ---- entry parsing -------------------------------------------------------

function parseEntries(raw, source) {
  var lines = String(raw || "").split("\n")
  var entries = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var v = JSON.parse(line)
      if (!v || typeof v !== "object") continue
      var originalId = Number(v.originalId || v.id || 0)
      var timestamp = Number(v.timestamp || 0)
      var row = {
        id: Number(v.id || 0),
        originalId: originalId,
        app: clipText(v.app, MAX_APP_LENGTH),
        appIcon: safeAppIcon(v.appIcon || ""),
        summary: clipText(v.summary, MAX_SUMMARY_LENGTH),
        body: clipText(v.body, MAX_BODY_LENGTH),
        image: safeImageSource(v.image || ""),
        glyph: clipText(v.glyph, MAX_GLYPH_LENGTH),
        execArgv: String(v.execArgv || ""),
        urgency: typeof v.urgency === "number" ? v.urgency : 1,
        timestamp: timestamp,
        stem: imageStem(timestamp, originalId),
        source: source
      }
      row.sig = contentSignature(row)
      entries.push(row)
    } catch (e) {
      // Torn write from a crash mid-save — skip the line, keep the rest.
    }
  }
  return entries
}

// Parse the engine's single archive JSON. It can be a bare array or an object
// with an `entries` array; both are normalized through parseEntries so the
// center applies the same sanitizing and numeric stem rules as for stock
// history files.
function parseArchive(raw) {
  var text = String(raw || "").trim()
  if (!text) return []
  try {
    var parsed = JSON.parse(text)
    var list = Array.isArray(parsed) ? parsed
      : (parsed && Array.isArray(parsed.entries) ? parsed.entries : [])
    var lines = []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && typeof list[i] === "object") lines.push(JSON.stringify(list[i]))
    }
    return parseEntries(lines.join("\n"), "history")
  } catch (e) {
    return []
  }
}

// Merge live popups and archived history, newest first. A file can exist in
// both locations for an instant while the service archives it; the live
// copy wins so a dismissal always targets the on-screen toast.
function mergeEntries(live, history) {
  var byStem = {}
  for (var i = 0; i < history.length; i++) byStem[history[i].stem] = history[i]
  for (var j = 0; j < live.length; j++) byStem[live[j].stem] = live[j]

  var out = []
  for (var k in byStem) out.push(byStem[k])
  out.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return out
}

// Hash only once per parsed row. The store reuses these entries across
// rebuilds, so the change detector becomes a cheap join instead of re-hashing
// every body on every notification.
function contentSignature(e) {
  var v = e || {}
  var body = String(v.summary) + "\u0001" + String(v.body) + "\u0001" +
             String(v.image) + "\u0001" + String(v.glyph) + "\u0001" +
             String(v.appIcon) + "\u0001" + String(v.app) + "\u0001" + v.urgency
  return hash(body)
}

function signature(entries) {
  var parts = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var sig = e.sig !== undefined ? e.sig : contentSignature(e)
    parts.push(e.stem + ":" + sig)
  }
  return parts.join(",")
}

function hash(s) {
  var h = 5381
  for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) & 0x7fffffff
  return h
}

// ---- settings ------------------------------------------------------------

function parseSettings(raw) {
  var text = String(raw || "").trim()
  if (!text) return { dnd: false }
  try {
    var parsed = JSON.parse(text)
    return { dnd: !!(parsed && parsed.dnd) }
  } catch (e) {
    return { dnd: false }
  }
}

function parseCenterState(raw) {
  var text = String(raw || "").trim()
  var fallback = {
    lastSeen: 0, placement: "top-right", mode: "window",
    marginX: 12, marginY: 12, padding: 12, cardSpacing: 10, confirmClear: true,
    screens: [], screensLegacy: false, captureToasts: true,
    allowExecActions: true, dndBypass: true
  }
  function clampInt(value, fallbackValue, min, max) {
    var n = Number(value)
    if (!isFinite(n)) n = fallbackValue
    return Math.max(min, Math.min(max, Math.round(n)))
  }
  if (!text) return fallback
  try {
    var parsed = JSON.parse(text)
    var seen = Number(parsed && parsed.lastSeen)
    if (!isFinite(seen) || seen < 0) seen = 0
    var placement = String((parsed && parsed.placement) || "")
    if (!/^(top|bottom|center)-(left|center|right)$/.test(placement)) placement = "top-right"
    var mode = String((parsed && parsed.mode) || "")
    if (["window", "horizontal", "vertical"].indexOf(mode) === -1) mode = "window"
    // Older files only carried one edgeMargin; use it for every side.
    var legacy = (parsed && parsed.edgeMargin !== undefined) ? parsed.edgeMargin : 12
    var legacyX = (parsed && parsed.marginLeft !== undefined) ? parsed.marginLeft : legacy
    var legacyY = (parsed && parsed.marginTop !== undefined) ? parsed.marginTop : legacy
    var confirmClear = !(parsed && parsed.confirmClear === false)
    var screens = []
    var screensLegacy = false
    if (parsed && Array.isArray(parsed.screens)) {
      for (var i = 0; i < parsed.screens.length; i++)
        if (typeof parsed.screens[i] === "string" && parsed.screens[i] !== "")
          screens.push(parsed.screens[i])
    } else if (parsed && typeof parsed.screen === "string" && parsed.screen !== "") {
      screens.push(parsed.screen)
      screensLegacy = true
    }
    return {
      lastSeen: seen,
      placement: placement,
      mode: mode,
      screens: screens,
      screensLegacy: screensLegacy,
      marginX: clampInt(parsed && parsed.marginX, clampInt(legacyX, 12, 0, 64), 0, 64),
      marginY: clampInt(parsed && parsed.marginY, clampInt(legacyY, 12, 0, 64), 0, 64),
      padding: clampInt(parsed && parsed.padding, 12, 4, 32),
      cardSpacing: clampInt(parsed && parsed.cardSpacing, 10, 2, 24),
      confirmClear: confirmClear,
      captureToasts: !(parsed && parsed.captureToasts === false),
      allowExecActions: !(parsed && parsed.allowExecActions === false),
      dndBypass: !(parsed && parsed.dndBypass === false),
      enterOpens: (parsed && parsed.enterOpens === "detail") ? "detail" : "app",
      shortcutBar: !(parsed && parsed.shortcutBar === false),
      hideBodies: !!(parsed && parsed.hideBodies === true),
      showPreviews: !(parsed && parsed.showPreviews === false),
      showBadge: !(parsed && parsed.showBadge === false),
      searchKey: (parsed && parsed.searchKey === "ctrl+f") ? "ctrl+f" : "/",
      dndKey: (parsed && parsed.dndKey === "D") ? "D" : "d",
      detailKey: (parsed && parsed.detailKey === "I") ? "I" : "i",
      helpKey: (parsed && parsed.helpKey === "F1") ? "F1" : "?"
    }
  } catch (e) {
    return fallback
  }
}

// ---- presentation --------------------------------------------------------

function timeAgo(ts, now) {
  var diff = Math.max(0, Number(now) - Number(ts))
  if (diff < 45000) return "just now"
  var m = Math.floor(diff / 60000)
  if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h ago"
  var d = Math.floor(h / 24)
  if (d < 7) return d + "d ago"
  var date = new Date(Number(ts))
  return date.getDate() + " " + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][date.getMonth()]
}

// Whether the optional engine is enabled according to shell.json. The engine
// is a service, so it is enabled when its id appears in plugins[] and is not
// listed in disabledPlugins[]. This is deliberately independent of whether the
// plugin directory exists: an installed-but-disabled engine must not keep the
// pre-3.0 data alive, because it will never run its migration.
function engineEnabledFromShellConfig(raw, engineId) {
  var id = String(engineId || "")
  if (id === "") return false
  try {
    var config = JSON.parse(String(raw || "{}"))
    var disabled = config && Array.isArray(config.disabledPlugins) ? config.disabledPlugins : []
    if (disabled.indexOf(id) !== -1) return false
    var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
    for (var i = 0; i < plugins.length; i++) {
      var entry = plugins[i]
      var entryId = entry && typeof entry === "object" ? String(entry.id || "") : String(entry || "")
      if (entryId === id) return true
    }
  } catch (e) {
  }
  return false
}

// Null-safe stand-in so detail-view bindings can read entry fields even when
// no notification is selected.
function emptyEntry() {
  return {
    id: 0, originalId: 0, app: "", appIcon: "", summary: "", body: "",
    image: "", glyph: "", execArgv: "", urgency: 1, timestamp: 0,
    stem: "", source: "history"
  }
}

// Node test hook. QML's JS engine has no `module`, so this block is inert in
// the running plugin; it lets the pure helpers be unit-tested with node --test.
if (typeof module !== "undefined") {
  module.exports = {
    isChromiumDerived: isChromiumDerived,
    isImageTag: isImageTag,
    stripImageTags: stripImageTags,
    sanitizeBody: sanitizeBody,
    safeImageSource: safeImageSource,
    safeAppIcon: safeAppIcon,
    imageStem: imageStem,
    engineEnabledFromShellConfig: engineEnabledFromShellConfig,
    styledSanitizedBody: styledSanitizedBody,
    styledBody: styledBody,
    parseEntries: parseEntries,
    parseArchive: parseArchive,
    clipText: clipText,
    limits: {
      app: MAX_APP_LENGTH,
      glyph: MAX_GLYPH_LENGTH,
      summary: MAX_SUMMARY_LENGTH,
      body: MAX_BODY_LENGTH
    },
    mergeEntries: mergeEntries,
    signature: signature,
    hash: hash,
    parseSettings: parseSettings,
    parseCenterState: parseCenterState,
    timeAgo: timeAgo,
    emptyEntry: emptyEntry
  }
}
