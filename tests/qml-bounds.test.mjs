import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

// Static invariants for the bounded-helper, bounded-file-read and clipboard
// work. Each assertion fails when the property that makes the code safe is
// removed.

const panel = readFileSync("Panel.qml", "utf8")
const store = readFileSync("components/StoreSingleton.qml", "utf8")
const wrapper = readFileSync("components/BoundedProcess.qml", "utf8")
const allQml = panel + "\n" + store + "\n" + wrapper

function findBlocks(text, opener) {
  const blocks = []
  let from = 0
  for (;;) {
    const start = text.indexOf(opener, from)
    if (start < 0) return blocks
    const open = text.indexOf("{", start)
    let depth = 0
    let end = open
    for (; end < text.length; end++) {
      const ch = text[end]
      if (ch === "/" && text[end + 1] === "/") {
        const newline = text.indexOf("\n", end)
        end = newline === -1 ? text.length : newline
        continue
      }
      if (ch === '"' || ch === "'") {
        const quote = ch
        for (end++; end < text.length; end++) {
          if (text[end] === "\\") { end++; continue }
          if (text[end] === quote) break
        }
        continue
      }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) { end++; break }
      }
    }
    blocks.push(text.slice(start, end))
    from = end
  }
}

function functionBlock(source, signature) {
  const start = source.indexOf(signature)
  if (start < 0) return ""
  const open = source.indexOf("{", start)
  let depth = 0
  for (let i = open; i < source.length; i++) {
    const ch = source[i]
    if (ch === '"' || ch === "'") {
      const quote = ch
      for (i++; i < source.length; i++) {
        if (source[i] === "\\") { i++; continue }
        if (source[i] === quote) break
      }
      continue
    }
    if (ch === "{") depth++
    else if (ch === "}") {
      depth--
      if (depth === 0) return source.slice(start, i + 1)
    }
  }
  return source.slice(start)
}

test("only the bounded wrapper instantiates a raw Process", () => {
  assert.equal(/(^|\n)\s*Process\s*\{/.test(panel), false)
  assert.equal(/(^|\n)\s*Process\s*\{/.test(store), false)
  assert.equal((wrapper.match(/(^|\n)\s*Process\s*\{/g) || []).length, 1)
  // Streams are collected once, inside the wrapper only.
  assert.equal(panel.includes("StdioCollector"), false)
  assert.equal(store.includes("StdioCollector"), false)
  assert.equal((wrapper.match(/^\s+waitForEnd:\s*false/gm) || []).length, 2)
  assert.equal(/waitForEnd:\s*true/.test(wrapper), false)
  assert.match(wrapper, /Bounds\.producerCommand\(list, maxOutBytes,/)
  assert.match(wrapper, /Bounds\.chunkOverflow\(text\.length, cap\)/)
})

test("a run without output reports an empty payload, not the previous one", () => {
  // StdioCollector keeps its last text when a new run writes nothing, so each
  // run must record whether it actually received data.
  assert.match(wrapper, /property bool _outChanged: false/)
  assert.match(wrapper, /property bool _errChanged: false/)
  assert.match(wrapper, /_outChanged = false\s*\n\s*_errChanged = false/)
  assert.match(wrapper, /onDataChanged: \{\s*\n\s*root\._outChanged = true/)
  assert.match(wrapper, /onDataChanged: \{\s*\n\s*root\._errChanged = true/)
  assert.match(wrapper, /var outText = _outChanged \? _collectorText\(outCollector\) : ""/)
  assert.match(wrapper, /var errText = _errChanged \? _collectorText\(errCollector\) : ""/)
  // A force-settled run must not let its late QProcess signals settle a newer
  // run or start the queue on its behalf.
  assert.match(wrapper, /_deferredGeneration = generation/)
  assert.match(wrapper, /if \(processAlive\) return/)
  assert.match(wrapper, /if \(_active \|\| _deferredGeneration >= 0 \|\| proc\.running \|\| _queue\.length === 0\) return/)
})

test("every helper declares a deadline and both byte caps", () => {
  const blocks = findBlocks(allQml, "BoundedProcess {")
    .filter((block) => !block.startsWith("BoundedProcess {\n  id: root"))
  assert.ok(blocks.length >= 11, "expected every former Process to be wrapped")
  for (const block of blocks) {
    const head = block.slice(0, 240)
    assert.match(block, /timeoutMs:/, head)
    assert.match(block, /maxOutBytes:/, head)
    assert.match(block, /maxErrBytes:/, head)
  }
})

test("a FileView only watches and writes, it never loads file content", () => {
  const blocks = findBlocks(store, "FileView {")
  assert.ok(blocks.length >= 7, "expected every watched file")
  for (const block of blocks) {
    assert.match(block, /preload:\s*false/)
    assert.equal(/onLoaded|onLoadFailed/.test(block), false, block.slice(0, 80))
    assert.equal(/\.text\(\)|\.reload\(\)/.test(block), false, block.slice(0, 80))
  }
  // The patched state comes from the bounded raw snapshot, not FileView.text().
  assert.match(store, /JSON\.parse\(String\(store\.centerStateRaw \|\| ""\)\.trim\(\)\)/)
  assert.equal(store.includes("centerStateFile.text()"), false)
})

test("every file read goes through a capped bounded helper", () => {
  for (const [path, cap] of [
    ["settingsPath", "settingsBytes"],
    ["centerStatePath", "centerStateBytes"],
    ["shellConfigPath", "shellConfigBytes"],
    ["archivePath", "archiveBytes"]
  ]) {
    assert.match(store, new RegExp("Bounds\\.fileReadCommand\\(store\\." + path +
      ", Bounds\\.LIMITS\\." + cap + "\\)"), path)
  }
  assert.match(store, /Bounds\.fileReadCommand\(store\.engineDir \+ "\/manifest\.json", Bounds\.LIMITS\.manifestBytes\)/)
  // A read failure is classified by a bounded probe before any default.
  assert.match(store, /Bounds\.fileStateCommand\(path\)/)
  assert.match(store, /Bounds\.readFailurePolicy\(state\) === "absent"/)
  assert.match(store, /Number\(result\.code\) === Bounds\.LIMITS\.fileTooLargeCode/)
  assert.match(store, /function applyMissingFile\(kind\)/)
  // The awk reads keep their raw argv and are bounded by the wrapper.
  assert.match(store, /store\.startRead\(liveReadProc, \["bash", "-c",/)
  assert.match(store, /store\.startRead\(historyReadProc, \["bash", "-c",/)
  assert.match(store, /id:\s*liveReadProc[\s\S]{0,180}maxOutBytes:\s*Bounds\.LIMITS\.stateBytes/)
  assert.match(store, /id:\s*historyReadProc[\s\S]{0,180}maxOutBytes:\s*Bounds\.LIMITS\.stateBytes/)
  // 16 MiB reads pay a per-chunk collection cost: their deadline must leave
  // several seconds of margin on a slow machine while staying finite.
  const helperBlocks = findBlocks(store, "BoundedProcess {")
  for (const id of ["liveReadProc", "historyReadProc", "archiveReadProc"]) {
    const block = helperBlocks.find((candidate) =>
      new RegExp("id:\\s*" + id + "\\b").test(candidate))
    assert.ok(block, id)
    assert.match(block, /producerTimeoutSeconds:\s*20/, id)
    assert.match(block, /timeoutMs:\s*21000/, id)
  }
})

test("the action queue refuses the newest request and never blocks on start failure", () => {
  assert.match(store, /Bounds\.enqueueBounded\(store\.actionQueue, item, Bounds\.LIMITS\.queueItems\)/)
  assert.match(store, /if \(!queued\.accepted\) \{[\s\S]{0,140}?console\.warn/)
  const run = functionBlock(store, "function runNextAction()")
  assert.match(run, /actionProc\.start\(item\.argv, item\.tag\)/)
  assert.match(run, /store\.runNextAction\(\)/)
  assert.match(run, /actionProc\.producerTimeoutSeconds = seconds/)
  // The legacy sweep and the install action are bounded and tagged.
  assert.match(store, /legacyCleanupProc\.start\(\["bash", "-c",/)
  assert.match(store, /Bounds\.LIMITS\.installTimeoutSeconds, "install"\)/)
})

test("the engine is never updated automatically", () => {
  assert.equal(store.includes("engineUpdateProc"), false)
  assert.equal(store.includes("engineUpdateAttempted"), false)
  // No argv vector updates the plugin outside the confirmed install flow.
  assert.equal(/"omarchy",\s*"plugin",\s*"update"/.test(store), false)
  const maybe = functionBlock(store, "function maybeUpdateEngine()")
  assert.match(maybe, /store\.engineUpdateRecommended = !store\.engineVersionSafe/)
  assert.equal(/\.start\(|\.running\s*=\s*true/.test(maybe), false)
})

test("clipboard paste is intercepted and generation-guarded", () => {
  // The native context menu carries a window-wide PasteAction shortcut, so it
  // must be removed, not merely hidden behind a right-click swallow.
  assert.match(panel, /^import QtQuick\.Templates as T$/m)
  assert.match(panel, /T\.ContextMenu\.menu: null/)
  assert.equal((panel.match(/ContextMenu\.menu\s*:/g) || []).length, 1)
  assert.match(panel, /event\.key === Qt\.Key_Menu/)
  assert.match(panel, /event\.key === Qt\.Key_F10 && \(event\.modifiers & Qt\.ShiftModifier\)/)
  assert.match(panel, /maximumLength: Bounds\.LIMITS\.searchChars/)
  assert.match(panel, /Keys\.priority: Keys\.BeforeItem/)
  assert.match(panel, /event\.matches\(StandardKey\.Paste\)/)
  assert.match(panel, /Qt\.Key_Insert && \(event\.modifiers & Qt\.ShiftModifier\)/)
  assert.match(panel, /acceptedButtons: Qt\.MiddleButton/)
  assert.match(panel, /root\.pasteFromClipboard\(true\)/)
  assert.match(panel, /Bounds\.clipboardCommand\(primary === true\)/)
  assert.match(panel, /Bounds\.isCurrentGeneration\(result\.tag, root\.pasteGeneration\)/)
  assert.match(panel, /Bounds\.insertionVerdict\(result\.out, field\.text\.length - selected,/)
  assert.match(panel, /field\.remove\(field\.selectionStart, field\.selectionEnd\)/)
  assert.match(panel, /field\.insert\(field\.cursorPosition, verdict\.text\)/)
  assert.match(panel, /result\.code === 124/)
  assert.match(panel, /result\.startFailed \|\| result\.code === 126 \|\| result\.code === 127/)
  assert.match(panel, /result\.overflow/)
  // Cancellation on close, search close and focus loss.
  assert.match(functionBlock(panel, "function close()"), /root\.cancelPaste\(\)/)
  assert.match(functionBlock(panel, "function closeSearch()"), /root\.cancelPaste\(\)/)
  assert.match(panel, /onActiveFocusChanged: if \(!activeFocus\) root\.cancelPaste\(\)/)
  assert.match(panel, /onSearchOpenChanged: if \(!root\.searchOpen\) root\.cancelPaste\(\)/)
  // Opening the search field never reads the clipboard.
  assert.equal(/function openSearch\(\)[\s\S]{0,400}?paste/.test(panel), false)
})

test("focus activation is bounded and always clears its pending entry", () => {
  assert.match(panel, /id:\s*focusAppProc[\s\S]{0,180}timeoutMs:\s*3000/)
  assert.match(panel, /id:\s*barMoveProc[\s\S]{0,180}timeoutMs:\s*8000/)
  const finish = functionBlock(panel, "function finishActivation(result)")
  assert.match(finish, /if \(!Bounds\.isCurrentGeneration\(result\.tag, root\.activationGeneration\)\) return/)
  assert.match(finish, /root\.pendingActivation = null/)
  assert.match(functionBlock(panel, "function activateEntry(entry)"),
    /if \(!focusAppProc\.start\(\["omarchy-hyprland-focus-app", app\],/)
})
