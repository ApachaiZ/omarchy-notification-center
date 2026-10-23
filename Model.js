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

function styledBody(body, app, appIcon) {
  return stripImageTags(sanitizeBody(body, app, appIcon).replace(/\r\n|\r|\n/g, "<br/>"))
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
      entries.push({
        id: Number(v.id || 0),
        originalId: originalId,
        app: String(v.app || ""),
        appIcon: String(v.appIcon || ""),
        summary: String(v.summary || ""),
        body: String(v.body || ""),
        image: String(v.image || ""),
        glyph: String(v.glyph || ""),
        execArgv: String(v.execArgv || ""),
        urgency: typeof v.urgency === "number" ? v.urgency : 1,
        timestamp: timestamp,
        stem: String(timestamp) + "-" + String(originalId),
        source: source
      })
    } catch (e) {
      // Torn write from a crash mid-save — skip the line, keep the rest.
    }
  }
  return entries
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

// Cheap change detector: a rebuild only happens when something the list
// draws actually changed.
function signature(entries) {
  var parts = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var body = String(e.summary) + "\u0001" + String(e.body) + "\u0001" +
               String(e.image) + "\u0001" + String(e.glyph) + "\u0001" +
               String(e.appIcon) + "\u0001" + String(e.app) + "\u0001" + e.urgency
    parts.push(e.stem + ":" + hash(body))
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
    marginX: 12, marginY: 12, padding: 12, cardSpacing: 10, confirmClear: true
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
    return {
      lastSeen: seen,
      placement: placement,
      mode: mode,
      marginX: clampInt(parsed && parsed.marginX, clampInt(legacyX, 12, 0, 64), 0, 64),
      marginY: clampInt(parsed && parsed.marginY, clampInt(legacyY, 12, 0, 64), 0, 64),
      padding: clampInt(parsed && parsed.padding, 12, 4, 32),
      cardSpacing: clampInt(parsed && parsed.cardSpacing, 10, 2, 24),
      confirmClear: confirmClear,
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

// Null-safe stand-in so detail-view bindings can read entry fields even when
// no notification is selected.
function emptyEntry() {
  return {
    id: 0, originalId: 0, app: "", appIcon: "", summary: "", body: "",
    image: "", glyph: "", execArgv: "", urgency: 1, timestamp: 0,
    stem: "", source: "history"
  }
}
