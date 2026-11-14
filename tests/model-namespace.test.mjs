import test from "node:test"
import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { spawnSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

// QML's `import "Model.js" as Model` exposes only the module's top-level
// declarations, never `module.exports`. A helper that exists only in the Node
// export block is invisible to the running shell, so this check reads the
// source itself instead of requiring the module (require would hide the bug).

const modelPath = fileURLToPath(new URL("../Model.js", import.meta.url))
const modelSource = readFileSync(modelPath, "utf8")

function qmlFiles() {
  const files = readdirSync(".").filter((name) => name.endsWith(".qml"))
  if (existsSync("components"))
    files.push(...readdirSync("components")
      .filter((name) => name.endsWith(".qml"))
      .map((name) => "components/" + name))
  return files
}

// Comments can mention Model.* without being calls, and the import line itself
// contains "Model.js". Both are removed before scanning; strings are kept
// because a real call is never inside one in this code base.
function codeOnly(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n")
    .replace(/^[ \t]*import\b[^\n]*\bModel\b[^\n]*$/gm, "")
}

function topLevelDeclarations() {
  const names = new Set()
  const pattern = /^(?:var|let|const|function)\s+([A-Za-z_$][\w$]*)/gm
  let match
  while ((match = pattern.exec(modelSource)) !== null) names.add(match[1])
  return names
}

test("every Model.<name> used in QML is a top-level declaration", () => {
  const declared = topLevelDeclarations()
  const used = new Set()
  for (const file of qmlFiles()) {
    const source = codeOnly(readFileSync(file, "utf8"))
    const pattern = /\bModel\.([A-Za-z_$][\w$]*)/g
    let match
    while ((match = pattern.exec(source)) !== null) used.add(match[1])
  }
  assert.ok(used.has("limits"), "expected StoreSingleton to read Model.limits")
  const missing = [...used].filter((name) => !declared.has(name)).sort()
  assert.deepEqual(missing, [],
    "Model identifiers used in QML but not exposed top-level: " + missing.join(", "))
})

test("Model.limits is a top-level table, not only a Node export", () => {
  assert.match(modelSource, /^var limits = \{/m)
  const block = modelSource.slice(modelSource.indexOf("var limits = {"),
    modelSource.indexOf("\n}", modelSource.indexOf("var limits = {")))
  assert.match(block, /liveEntries:\s*MAX_LIVE_ENTRIES/)
  assert.match(block, /archiveEntries:\s*MAX_ARCHIVE_ENTRIES/)
  assert.match(block, /mergedEntries:\s*MAX_MERGED_ENTRIES/)
})

function qmltestrunner() {
  const installed = "/usr/lib/qt6/bin/qmltestrunner"
  if (existsSync(installed)) return installed
  const probe = spawnSync("qmltestrunner", ["-help"], { encoding: "utf8" })
  return probe.error ? null : "qmltestrunner"
}

test("a real QML import resolves the Model namespace", (t) => {
  const runner = qmltestrunner()
  if (!runner) {
    t.skip("qmltestrunner is not installed")
    return
  }
  const dir = mkdtempSync(join(tmpdir(), "nc-model-namespace-"))
  try {
    writeFileSync(join(dir, "tst_modelnamespace.qml"), [
      "import QtTest",
      'import "' + pathToFileURL(modelPath).href + '" as Model',
      "",
      "TestCase {",
      '  name: "ModelNamespace"',
      "  function test_exposed() {",
      '    compare(typeof Model.limits, "object")',
      "    compare(Model.limits.liveEntries, 128)",
      "    compare(Model.limits.archiveEntries, 1000)",
      "    compare(Model.limits.mergedEntries, 1024)",
      '    compare(typeof Model.parseEntries, "function")',
      "  }",
      "}",
      ""
    ].join("\n"))
    const result = spawnSync(runner, ["-input", dir], {
      encoding: "utf8",
      timeout: 60000,
      env: { ...process.env, QT_QPA_PLATFORM: "offscreen" }
    })
    const output = String(result.stdout || "") + String(result.stderr || "")
    assert.equal(result.status, 0, output)
    assert.match(output, /Totals: 3 passed, 0 failed/, output)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
