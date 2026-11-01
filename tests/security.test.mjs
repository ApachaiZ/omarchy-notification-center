import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

test("remote notification images are dropped", () => {
  assert.equal(Model.safeImageSource("https://tracker.example/pixel.png"), "")
  assert.equal(Model.safeImageSource("http://tracker.example/pixel.png"), "")
  assert.equal(Model.safeImageSource("data:image/png;base64,AAAA"), "")
  assert.equal(Model.safeImageSource("file:///tmp/a.png"), "file:///tmp/a.png")
  assert.equal(Model.safeImageSource("/tmp/a.png"), "/tmp/a.png")
  assert.equal(Model.safeImageSource("image://provider/a"), "image://provider/a")
})

test("safe app icons keep themed names and local files only", () => {
  assert.equal(Model.safeAppIcon("firefox"), "firefox")
  assert.equal(Model.safeAppIcon("org.gnome.Nautilus"), "org.gnome.Nautilus")
  assert.equal(Model.safeAppIcon("file:///tmp/icon.png"), "file:///tmp/icon.png")
  assert.equal(Model.safeAppIcon("https://tracker.example/icon.png"), "")
  assert.equal(Model.safeAppIcon("data:image/png;base64,AAAA"), "")
})

test("image stems are numeric and cannot escape the image directory", () => {
  assert.equal(Model.imageStem(123, 4), "123-4")
  assert.equal(Model.imageStem("x", "../bad"), "0-0")
  assert.equal(Model.imageStem("../x", "1/2"), "0-0")
})

test("persisted rows are sanitized when parsed", () => {
  const raw = JSON.stringify({
    id: 1, originalId: 2, timestamp: 3,
    image: "https://tracker.example/pixel.png",
    appIcon: "https://tracker.example/icon.png",
    summary: "s", body: "b"
  }) + "\n"
  const [row] = Model.parseEntries(raw, "live")
  assert.equal(row.image, "")
  assert.equal(row.appIcon, "")
  assert.equal(row.stem, "3-2")
})

test("engine archive JSON parses like history rows", () => {
  const raw = JSON.stringify({
    version: 1,
    entries: [{
      id: 7, originalId: 8, timestamp: 9,
      image: "https://tracker.example/pixel.png",
      appIcon: "firefox", summary: "s", body: "b"
    }]
  })
  const [row] = Model.parseArchive(raw)
  assert.equal(row.image, "")
  assert.equal(row.appIcon, "firefox")
  assert.equal(row.stem, "9-8")
  assert.deepEqual(Model.parseArchive("not json"), [])
  assert.deepEqual(Model.parseArchive(""), [])
})

test("captureToasts defaults on and can be disabled", () => {
  assert.equal(Model.parseCenterState("").captureToasts, true)
  assert.equal(Model.parseCenterState("{}").captureToasts, true)
  assert.equal(Model.parseCenterState(JSON.stringify({ captureToasts: false })).captureToasts, false)
  assert.equal(Model.parseCenterState(JSON.stringify({ captureToasts: true })).captureToasts, true)
})

test("oversized persisted rows are clipped when parsed", () => {
  const raw = JSON.stringify({
    app: "a".repeat(400), summary: "s".repeat(2000), body: "b".repeat(20000),
    glyph: "g".repeat(40), timestamp: 1, originalId: 2
  }) + "\n"
  const [row] = Model.parseEntries(raw, "history")
  assert.equal(row.app.length, Model.limits.app)
  assert.equal(row.summary.length, Model.limits.summary)
  assert.equal(row.body.length, Model.limits.body)
  assert.equal(row.glyph.length, Model.limits.glyph)
  assert.equal(Model.clipText("a\u0000b", 10), "ab")
})

test("engine action and DND policies default on and can be turned off", () => {
  assert.equal(Model.parseCenterState("").allowExecActions, true)
  assert.equal(Model.parseCenterState("").dndBypass, true)
  assert.equal(Model.parseCenterState("{}").allowExecActions, true)
  assert.equal(Model.parseCenterState("{}").dndBypass, true)
  assert.equal(Model.parseCenterState(JSON.stringify({ allowExecActions: false })).allowExecActions, false)
  assert.equal(Model.parseCenterState(JSON.stringify({ dndBypass: false })).dndBypass, false)
  assert.equal(Model.parseCenterState(JSON.stringify({ allowExecActions: true })).allowExecActions, true)
})

test("legacy cleanup follows the engine enabled state, not its directory", () => {
  const engine = "apach.notification-engine"
  const enabled = JSON.stringify({ plugins: [{ id: engine }] })
  const disabled = JSON.stringify({ plugins: [{ id: engine }], disabledPlugins: [engine] })
  assert.equal(Model.engineEnabledFromShellConfig(enabled, engine), true)
  assert.equal(Model.engineEnabledFromShellConfig(JSON.stringify({ plugins: [engine] }), engine), true)
  assert.equal(Model.engineEnabledFromShellConfig(JSON.stringify({ plugins: [] }), engine), false)
  assert.equal(Model.engineEnabledFromShellConfig(disabled, engine), false)
  assert.equal(Model.engineEnabledFromShellConfig(JSON.stringify({ disabledPlugins: [engine] }), engine), false)
  assert.equal(Model.engineEnabledFromShellConfig("not json", engine), false)
  assert.equal(Model.engineEnabledFromShellConfig(enabled, "other.plugin"), false)
})

test("legacy cleanup waits for old engines instead of deleting their images", () => {
  const d = Model.legacyCleanupAction
  // No engine can reference the tree: delete once, then stay done.
  assert.equal(d(false, false, false, false), "delete")
  assert.equal(d(false, false, true, false), "done")
  // Safe engine owns the migration: delegate once, then stay done.
  assert.equal(d(true, true, false, false), "delegate")
  assert.equal(d(true, true, false, true), "done")
  // Enabled but older engine still references legacy images and may not have
  // merged the archive yet: never delete, wait instead.
  assert.equal(d(true, false, false, false), "wait")
  assert.equal(d(true, false, false, true), "wait")
  assert.equal(d(true, false, true, false), "wait")
  // Transitions change the decision: old engine updated to a safe version
  // delegates, then disabling it wipes the tree.
  assert.equal(d(true, true, false, false), "delegate")
  assert.equal(d(false, false, false, true), "delete")
})

test("engine versions are compared numerically", () => {
  assert.equal(Model.versionAtLeast("1.0.5", "1.0.5"), true)
  assert.equal(Model.versionAtLeast("1.0.6", "1.0.5"), true)
  assert.equal(Model.versionAtLeast("1.0.10", "1.0.5"), true)
  assert.equal(Model.versionAtLeast("1.1.0", "1.0.5"), true)
  assert.equal(Model.versionAtLeast("1.0.4", "1.0.5"), false)
  assert.equal(Model.versionAtLeast("", "1.0.5"), false)
  assert.equal(Model.manifestVersion('{"version":"1.0.5"}'), "1.0.5")
  assert.equal(Model.manifestVersion("not json"), "")
})
