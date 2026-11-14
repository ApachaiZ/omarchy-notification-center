// Pure limits and helpers for bounded helpers, clipboard reads and queues.
// No QML or shell access, so the functions here are covered by
// tests/bounds.test.mjs. The QML side (components/BoundedProcess.qml) applies
// these values; keeping them here makes the numeric contract testable.

// Producer caps are always one byte above the consumer cap so a payload that
// exactly fits is accepted and anything larger is detectable, never parsed as
// if it were complete.
var LIMITS = {
  clipboardBytes: 65536,
  clipboardErrBytes: 4096,
  searchChars: 200,
  // Live/history and the engine archive: 16 MiB covers 1000 entries whose
  // fields are all at the Model caps (about 13 KiB each, ~13 MiB) plus JSON
  // syntax and escaping. A bigger file is refused whole and the previous
  // in-memory state is kept, so an oversized history is frozen rather than
  // partially parsed. The read is transient, so this also bounds memory.
  stateBytes: 16777216,
  settingsBytes: 65536,
  centerStateBytes: 65536,
  shellConfigBytes: 1048576,
  manifestBytes: 65536,
  archiveBytes: 16777216,
  helperOutBytes: 65536,
  helperErrBytes: 8192,
  probeOutBytes: 1024,
  probeErrBytes: 1024,
  probeQueueItems: 16,
  queueItems: 64,
  fileTooLargeCode: 3,
  actionTimeoutSeconds: 30,
  installTimeoutSeconds: 300,
  clearTimeoutSeconds: 60
}

// UTF-8 byte length without TextEncoder: QML's JS engine has no TextEncoder,
// and a raw `.length` would undercount every non-ASCII character.
function utf8ByteLength(text) {
  var value = String(text === undefined || text === null ? "" : text)
  var bytes = 0
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i)
    if (code < 0x80) {
      bytes += 1
    } else if (code < 0x800) {
      bytes += 2
    } else if (code >= 0xd800 && code <= 0xdbff) {
      var next = i + 1 < value.length ? value.charCodeAt(i + 1) : 0
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4
        i++
      } else {
        bytes += 3
      }
    } else {
      bytes += 3
    }
  }
  return bytes
}

// Wrap an argv vector so the producer itself is bounded on both streams:
// `timeout` enforces an absolute deadline, `head -c` stops stdout one byte
// past the consumer cap, and a second bounded reader caps stderr at its own
// producer cap. The stderr reader is a synchronous pipeline member: bash waits
// for every pipeline member before it exits, so the complete (bounded)
// diagnostic is in the pipe when `exited` fires. The reader drains past its
// cap into /dev/null so a chatty producer is never killed by SIGPIPE on
// stderr. The reader stage reports success so the producer's exit status (124
// on timeout, 127 when the tool is missing) is what reaches the caller. The
// shell script is a constant; the command and its arguments travel as
// positional parameters, so no caller value can become shell syntax.
function producerCommand(argv, maxBytes, timeoutSeconds, maxErrBytes) {
  var list = []
  for (var i = 0; i < (argv || []).length; i++) list.push(String(argv[i]))
  if (list.length === 0) return []
  var outCap = Math.max(1, Math.floor(Number(maxBytes) || 0)) + 1
  var errLimit = maxErrBytes === undefined ? maxBytes : maxErrBytes
  var errCap = Math.max(1, Math.floor(Number(errLimit) || 0)) + 1
  var seconds = Math.max(1, Math.ceil(Number(timeoutSeconds) || 2))
  // The reader gets one extra second past the producer deadline; the QML
  // deadline can be shorter and escalates first, so this is only a backstop
  // for a grandchild that keeps the stderr pipe open past the producer.
  var readerSeconds = seconds + 1
  var script = "set -o pipefail; { timeout -k 1 " + seconds +
    ' "$@" 2>&1 1>&3 | { timeout -k 1 ' + readerSeconds +
    ' bash -c "head -c ' + errCap + ' >&2; cat > /dev/null"; true; }; } 3>&1 | head -c ' + outCap
  return ["bash", "-c", script, "bash"].concat(list)
}

// Bounded file read without a shell: a `stat` size check refuses an oversized
// file before any content is produced (exit 3), then `head` bounds the actual
// read. Checking the size up front matters: a `head -c cap+1` cut can land in
// the middle of a UTF-8 sequence, and the decoded text would then be too short
// to trip the receiver's byte check. The path is an argv element, never
// interpolated.
function fileReadCommand(path, maxBytes) {
  var limit = Math.max(1, Math.floor(Number(maxBytes) || 0))
  var script = 'bytes=$(stat -c %s -- "$1") || exit 1\n' +
    'if [ "$bytes" -gt ' + limit + ' ]; then exit ' + LIMITS.fileTooLargeCode + '; fi\n' +
    'head -c ' + (limit + 1) + ' -- "$1"'
  return ["bash", "-c", script, "bash", String(path || "")]
}

function clipboardCommand(primary) {
  var argv = ["wl-paste", "--no-newline"]
  if (primary === true) argv.push("--primary")
  return producerCommand(argv, LIMITS.clipboardBytes, 2, LIMITS.clipboardErrBytes)
}

// Classify a file before deciding what a failed read may do. The script is
// constant and the path is a positional parameter: exit 0 readable, 1 absent,
// 2 present but unreadable. `timeout` keeps the probe bounded.
function fileStateCommand(path) {
  return ["timeout", "-k", "1", "2", "bash", "-c",
    'if [ -e "$1" ]; then if [ -r "$1" ]; then exit 0; else exit 2; fi; else exit 1; fi',
    "bash", String(path || "")]
}

// -1 = unknown (probe failed), 0 = readable, 1 = absent, 2 = unreadable.
// The probe exits non-zero for "absent" and "unreadable", so this reads the
// code even when `ok` is false; only overflow/timeout/failed start/cancel are
// treated as an unknown probe.
function fileStateFromExit(result) {
  if (!result) return -1
  if (result.overflow || result.timedOut || result.startFailed || result.canceled) return -1
  var code = Number(result.code)
  if (code === 0) return 0
  if (code === 1) return 1
  if (code === 2) return 2
  return -1
}

// A read that failed may only create defaults when the file is provably
// absent. Timeouts, overflows, failed starts, permission errors and an
// unknown probe state all keep the file untouched.
function readFailurePolicy(fileState) {
  return fileState === 1 ? "absent" : "refuse"
}

// Queue admission that refuses the newest item when the cap is reached. An
// action that was already accepted must still run, and a silently dropped
// destructive action would be worse than an explicit refusal.
function enqueueBounded(queue, item, limit) {
  var list = (queue || []).slice()
  var max = Math.max(1, Math.floor(Number(limit) || 1))
  if (list.length >= max) return { queue: list, accepted: false }
  list.push(item)
  return { queue: list, accepted: true }
}

// Per-chunk cap decision used by BoundedProcess._watchStream. `length` is the
// UTF-16 length of the text accumulated so far; bytes >= UTF-16 units, so
// crossing this limit is certain to cross the byte cap too. Computing it per
// chunk (rather than only at stream end) is what keeps memory bounded.
function chunkOverflow(length, cap) {
  return (Number(length) || 0) > Math.max(0, Math.floor(Number(cap) || 0))
}

// Stale-result guard for async reads: a result is usable only when its tag is
// the generation that is still current. A new request, focus loss or close
// increments the generation, so a late result is discarded.
function isCurrentGeneration(tag, current) {
  if (tag === null || tag === undefined) return false
  return tag === current
}

// A single-line filter never receives embedded newlines or tabs from a paste.
function singleLine(text) {
  return String(text === undefined || text === null ? "" : text).replace(/[\r\n\t]+/g, " ")
}

// Accept only text that fits both the byte contract and the field's remaining
// characters. The caller refuses (with a log) instead of truncating silently.
function insertionVerdict(text, currentLength, maxChars, maxBytes) {
  var value = singleLine(text)
  if (utf8ByteLength(value) > Math.max(0, Number(maxBytes) || 0))
    return { ok: false, reason: "tooLarge" }
  var room = Math.max(0, Number(maxChars) || 0) - Math.max(0, Number(currentLength) || 0)
  if (value.length > room) return { ok: false, reason: "tooLong" }
  return { ok: true, text: value }
}

if (typeof module !== "undefined") {
  module.exports = {
    LIMITS: LIMITS,
    utf8ByteLength: utf8ByteLength,
    producerCommand: producerCommand,
    fileReadCommand: fileReadCommand,
    clipboardCommand: clipboardCommand,
    fileStateCommand: fileStateCommand,
    fileStateFromExit: fileStateFromExit,
    readFailurePolicy: readFailurePolicy,
    enqueueBounded: enqueueBounded,
    chunkOverflow: chunkOverflow,
    isCurrentGeneration: isCurrentGeneration,
    singleLine: singleLine,
    insertionVerdict: insertionVerdict
  }
}
