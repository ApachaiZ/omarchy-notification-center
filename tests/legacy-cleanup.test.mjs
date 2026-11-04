import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

const legacy = "/home/u/.local/state/omarchy/notifications-center"

function row(image, appIcon = "") {
  return { image, appIcon }
}

test("legacy keep list contains only images referenced by retained rows", () => {
  const entries = [
    row("file://" + legacy + "/images/100-1-image",
      "file://" + legacy + "/images/100-1-appIcon"),
    row(legacy + "/images/101-2-image", "firefox"),
    row("file://" + legacy + "/images/102-3%20image", ""),
    row("file:///tmp/other.png", "https://tracker.example/icon.png"),
    row("file://" + legacy + "/images/../secret", "")
  ]
  assert.deepEqual(Model.legacyImageBasenames(entries, legacy).sort(),
    ["100-1-appIcon", "100-1-image", "101-2-image", "102-3 image"].sort())
})

test("legacy cleanup prunes unreferenced copies while other references survive", () => {
  const kept = row("file://" + legacy + "/images/100-1-image")
  const plan = Model.legacyCleanupPlan([kept], legacy, false, false, false)
  assert.equal(plan.action, "prune")
  assert.deepEqual(plan.keep, ["100-1-image"])
  // The deleted/expired row's copy is not in keep, so the prune command
  // removes it even though another legacy reference still exists.
  assert.equal(plan.keep.includes("99-9-image"), false)
})

test("legacy cleanup deletes the tree once the last reference disappears", () => {
  assert.deepEqual(Model.legacyCleanupPlan([], legacy, false, false, false), {
    action: "delete",
    keep: []
  })
})

test("legacy cleanup is recomputed when the engine is disabled", () => {
  const entries = [row("file://" + legacy + "/images/100-1-image")]
  assert.equal(Model.legacyCleanupPlan(entries, legacy, true, true, false).action, "delegate")
  assert.equal(Model.legacyCleanupPlan(entries, legacy, true, true, true).action, "done")
  // Whatever was delegated before must not latch when the engine is disabled.
  assert.equal(Model.legacyCleanupPlan(entries, legacy, false, false, true).action, "prune")
  // No current reference: the earlier wholesale removal still applies.
  assert.equal(Model.legacyCleanupPlan([], legacy, false, false, true).action, "delete")
})

test("legacy cleanup leaves migration recovery to enabled engines", () => {
  const entries = [row("file://" + legacy + "/images/100-1-image")]
  for (const list of [entries, []]) {
    assert.equal(Model.legacyCleanupPlan(list, legacy, true, true, false).action, "delegate")
    assert.equal(Model.legacyCleanupPlan(list, legacy, true, true, true).action, "done")
    assert.equal(Model.legacyCleanupPlan(list, legacy, true, false, false).action, "wait")
  }
})

test("prune argv passes kept names as arguments, never through the script", () => {
  const argv = Model.legacyPruneArgv(legacy, ["100-1-image", "-danger appIcon"])
  assert.equal(argv[0], "bash")
  assert.equal(argv[1], "-c")
  assert.equal(argv[3], "--")
  assert.equal(argv[4], legacy + "/images")
  assert.deepEqual(argv.slice(5), ["100-1-image", "-danger appIcon"])
  assert.doesNotMatch(argv[2], /100-1-image|-danger/)
  assert.match(argv[2], /rm -f -- "\$file"/)
  assert.equal(Model.legacyPruneArgv(legacy, []), null)
})

test("prune argv removes only unreferenced legacy images", () => {
  const root = mkdtempSync(join(tmpdir(), "legacy-prune-"))
  try {
    const dir = join(root, "legacy")
    const images = join(dir, "images")
    mkdirSync(images, { recursive: true })
    writeFileSync(join(images, "100-1-image"), "keep")
    writeFileSync(join(images, "100-1-appIcon"), "keep")
    writeFileSync(join(images, "99-9-image"), "orphan")
    writeFileSync(join(images, "98-8-appIcon"), "orphan")

    const argv = Model.legacyPruneArgv(dir, ["100-1-appIcon", "100-1-image"])
    const result = spawnSync(argv[0], argv.slice(1), { encoding: "utf8" })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(existsSync(join(images, "100-1-image")), true)
    assert.equal(existsSync(join(images, "100-1-appIcon")), true)
    assert.equal(existsSync(join(images, "99-9-image")), false)
    assert.equal(existsSync(join(images, "98-8-appIcon")), false)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("the store never latches a legacy cleanup skip and recomputes on sources", () => {
  const source = readFileSync(new URL("../components/StoreSingleton.qml", import.meta.url), "utf8")
  assert.equal(source.includes("legacyCleanupSkipped"), false)
  for (const hook of ["onLiveRead", "onHistoryRead", "onArchiveLoaded", "parseShellConfig"]) {
    const start = source.indexOf("function " + hook)
    assert.notEqual(start, -1, hook)
    const end = source.indexOf("\n  function ", start + 10)
    assert.match(source.slice(start, end === -1 ? source.length : end),
      /cleanupLegacyArchive\(\)/, hook)
  }
  assert.match(source, /function cleanupLegacyArchive[\s\S]*Model\.legacyCleanupPlan/)
})
