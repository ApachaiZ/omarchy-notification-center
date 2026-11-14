import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"

const require = createRequire(import.meta.url)
const Bounds = require("../js/Bounds.js")
const Model = require("../Model.js")

test("utf8ByteLength counts UTF-8 bytes, not UTF-16 units", () => {
  for (const sample of ["", "abc", "é", "€", "😀", "aé€😀z", "\uD800"])
    assert.equal(Bounds.utf8ByteLength(sample), Buffer.byteLength(sample, "utf8"), sample)
})

test("producerCommand bounds both streams and keeps the command in argv", () => {
  const command = Bounds.producerCommand(["wl-paste", "--no-newline; rm -rf /"], 65536, 2, 4096)
  assert.equal(command[0], "bash")
  assert.equal(command[1], "-c")
  assert.match(command[2], /set -o pipefail/)
  assert.match(command[2], /head -c 65537$/)
  assert.match(command[2], /head -c 4097 >&2/)
  assert.match(command[2], /timeout -k 1 2 /)
  assert.equal(command[2].includes("--no-newline; rm -rf /"), false)
  assert.deepEqual(command.slice(4), ["wl-paste", "--no-newline; rm -rf /"])
  assert.deepEqual(Bounds.producerCommand([], 100, 2), [])
})

test("fileReadCommand refuses an oversized file before reading it", () => {
  const command = Bounds.fileReadCommand("/tmp/a b;$(x).json", 65536)
  assert.equal(command[0], "bash")
  assert.equal(command[1], "-c")
  assert.match(command[2], /stat -c %s -- "\$1"/)
  assert.match(command[2], /-gt 65536 \]; then exit 3/)
  assert.match(command[2], /head -c 65537 -- "\$1"/)
  assert.equal(command[2].includes("/tmp/a b"), false)
  assert.deepEqual(command.slice(4), ["/tmp/a b;$(x).json"])
})

test("fileReadCommand reads a bounded file and reports absence and overflow", () => {
  const root = mkdtempSync(join(tmpdir(), "bounded-read-"))
  try {
    const small = join(root, "small.json")
    const large = join(root, "large.json")
    writeFileSync(small, "0123456789")
    writeFileSync(large, "x".repeat(100))
    const run = (argv) => spawnSync(argv[0], argv.slice(1), { encoding: "utf8" })

    const ok = run(Bounds.fileReadCommand(small, 64))
    assert.equal(ok.status, 0)
    assert.equal(ok.stdout, "0123456789")

    const overflow = run(Bounds.fileReadCommand(large, 64))
    assert.equal(overflow.status, Bounds.LIMITS.fileTooLargeCode)
    assert.equal(overflow.stdout, "")

    const absent = run(Bounds.fileReadCommand(join(root, "missing.json"), 64))
    assert.equal(absent.status, 1)
    assert.equal(absent.stdout, "")
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("clipboardCommand adds --primary only for the PRIMARY selection", () => {
  const normal = Bounds.clipboardCommand(false)
  const primary = Bounds.clipboardCommand(true)
  assert.deepEqual(normal.slice(4), ["wl-paste", "--no-newline"])
  assert.deepEqual(primary.slice(4), ["wl-paste", "--no-newline", "--primary"])
  assert.equal(normal[2], primary[2])
})

test("a failed read only applies defaults when the probe proves the file absent", () => {
  assert.equal(Bounds.fileStateFromExit({ ok: true, code: 0 }), 0)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 1 }), 1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 2 }), 2)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 1, timedOut: true }), -1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, code: 1, overflow: true }), -1)
  assert.equal(Bounds.fileStateFromExit({ ok: false, startFailed: true }), -1)
  assert.equal(Bounds.fileStateFromExit(null), -1)
  assert.equal(Bounds.readFailurePolicy(1), "absent")
  assert.equal(Bounds.readFailurePolicy(0), "refuse")
  assert.equal(Bounds.readFailurePolicy(2), "refuse")
  assert.equal(Bounds.readFailurePolicy(-1), "refuse")
})

test("the action queue refuses the newest item when full", () => {
  let queue = []
  for (let i = 0; i < 3; i++) {
    const result = Bounds.enqueueBounded(queue, i, 3)
    assert.equal(result.accepted, true)
    queue = result.queue
  }
  const refused = Bounds.enqueueBounded(queue, 99, 3)
  assert.equal(refused.accepted, false)
  assert.deepEqual(refused.queue, [0, 1, 2])
  // A clamp of a nonsense limit still admits one item, never zero.
  assert.equal(Bounds.enqueueBounded([], "x", 0).accepted, true)
})

test("a paste is single-line, byte-capped and character-capped", () => {
  assert.equal(Bounds.singleLine("a\nb\tc\rd"), "a b c d")
  assert.equal(Bounds.insertionVerdict("abc", 0, 200, 65536).ok, true)
  assert.equal(Bounds.insertionVerdict("a".repeat(201), 0, 200, 65536).reason, "tooLong")
  assert.equal(Bounds.insertionVerdict("a".repeat(190), 20, 200, 65536).reason, "tooLong")
  assert.equal(Bounds.insertionVerdict("é".repeat(10), 0, 200, 10).reason, "tooLarge")
})

test("the per-chunk cap triggers exactly past the limit", () => {
  assert.equal(Bounds.chunkOverflow(64, 64), false)
  assert.equal(Bounds.chunkOverflow(65, 64), true)
})

test("parseEntries stops parsing at its entry cap", () => {
  const line = JSON.stringify({ timestamp: 1, originalId: 1, app: "a" })
  const raw = new Array(20).fill(line).join("\n")
  assert.equal(Model.parseEntries(raw, "live", 5).length, 5)
  assert.equal(Model.parseEntries(raw, "live").length,
    Model.limits.archiveEntries > 20 ? 20 : Model.limits.archiveEntries)
  // Invalid lines are skipped without consuming the cap.
  const mixed = ["not json", line, "", line, line].join("\n")
  assert.equal(Model.parseEntries(mixed, "live", 2).length, 2)
  // A payload padded with blank lines is bounded without splitting it first.
  const padded = "\n".repeat(5000) + [line, line, line].join("\n") + "\n".repeat(5000)
  assert.equal(Model.parseEntries(padded, "live", 2).length, 2)
  assert.deepEqual(Model.parseEntries("", "live", 2), [])
})

test("parseArchive stops parsing entries past its cap", () => {
  const entries = []
  for (let i = 0; i < 30; i++) entries.push({ timestamp: i + 1, originalId: i, app: "a" })
  assert.equal(Model.parseArchive(JSON.stringify(entries), 4).length, 4)
  assert.equal(Model.parseArchive(JSON.stringify({ entries }), 4).length, 4)
  assert.equal(Model.parseArchive(JSON.stringify(entries)).length, 30)
})

test("mergeEntries keeps the newest rows and is capped", () => {
  const live = []
  const history = []
  for (let i = 0; i < 10; i++) {
    history.push({ stem: "h" + i, timestamp: 100 + i })
    live.push({ stem: "l" + i, timestamp: 200 + i })
  }
  const merged = Model.mergeEntries(live, history, 4)
  assert.equal(merged.length, 4)
  assert.deepEqual(merged.map((row) => row.timestamp), [209, 208, 207, 206])
  // Live still wins a same-stem merge under the cap.
  const same = Model.mergeEntries(
    [{ stem: "1-2", timestamp: 1, summary: "live" }],
    [{ stem: "1-2", timestamp: 1, summary: "history" }], 10)
  assert.equal(same.find((row) => row.stem === "1-2").summary, "live")
})
