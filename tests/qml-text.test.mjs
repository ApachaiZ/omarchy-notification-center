import test from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync, readdirSync } from "node:fs"

// Notification text is untrusted (any local process can send a notification),
// so every Text element must choose its format explicitly. AutoText would let
// a sender turn a summary into rich text, and a body that is not the sanitized
// one must never reach StyledText.
const files = readdirSync(".")
  .filter((name) => name.endsWith(".qml"))
  .concat(
    existsSync("components")
      ? readdirSync("components").filter((name) => name.endsWith(".qml")).map((name) => "components/" + name)
      : []
  )

function blockEnd(source, openBrace) {
  let depth = 0
  for (let i = openBrace; i < source.length; i++) {
    const ch = source[i]
    if (ch === "/" && source[i + 1] === "/") {
      const newline = source.indexOf("\n", i)
      i = newline === -1 ? source.length : newline
      continue
    }
    if (ch === "/" && source[i + 1] === "*") {
      const close = source.indexOf("*/", i + 2)
      i = close === -1 ? source.length : close + 1
      continue
    }
    if (ch === '"' || ch === "'") {
      const quote = ch
      for (i++; i < source.length; i++) {
        if (source[i] === "\\") {
          i++
          continue
        }
        if (source[i] === quote) break
      }
      continue
    }
    if (ch === "{") depth++
    else if (ch === "}") {
      depth--
      if (depth === 0) return i
    }
  }
  return -1
}

function textBlocks(file) {
  const source = readFileSync(file, "utf8")
  const blocks = []
  const pattern = /^[ \t]*Text[ \t]*\{[ \t]*$/gm
  let match
  while ((match = pattern.exec(source)) !== null) {
    const open = source.indexOf("{", match.index)
    const close = blockEnd(source, open)
    if (close === -1) continue
    blocks.push({
      file,
      line: source.slice(0, match.index).split("\n").length,
      text: source.slice(match.index, close + 1)
    })
  }
  return blocks
}

const blocks = files.flatMap(textBlocks)

test("every Text element chooses a text format explicitly", () => {
  const failures = blocks
    .filter((block) => !/^\s*textFormat\s*:\s*Text\.(PlainText|StyledText)\s*$/m.test(block.text))
    .map((block) => `${block.file}:${block.line}`)
  assert.deepEqual(failures, [], "Text elements must set Text.PlainText or Text.StyledText")
})

test("styled text is only the sanitized notification body", () => {
  for (const block of blocks) {
    if (!/textFormat\s*:\s*Text\.StyledText/.test(block.text)) continue
    assert.match(block.text, /text:\s*root\.bodyText\(/, `${block.file}:${block.line}`)
  }
})

test("rich text is never requested explicitly", () => {
  for (const file of files) {
    const source = readFileSync(file, "utf8")
    assert.equal(/Text\.(AutoText|RichText)/.test(source), false, file)
  }
})
