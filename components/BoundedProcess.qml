// A Process wrapper with hard resource and lifetime bounds.
//
// Quickshell's Process has no timeout, no output cap and no kill escalation;
// a missing binary never emits `exited`, only `runningChanged`. This component
// owns those guarantees once so every helper in the plugin shares them:
//
// - stdout/stderr are captured by StdioCollector, which stores the raw bytes
//   and decodes them once into a QString. This is deliberate: splitting the
//   stream into chunks with SplitParser and decoding each chunk separately
//   corrupts a multi-byte UTF-8 character that straddles two reads.
// - stdout and stderr are both bounded at the producer. A single constant
//   bash pipeline runs the helper under `timeout -k 1 N`, pipes stdout through
//   `head -c capOut+1`, and pipes stderr through a synchronous reader that
//   emits at most `capErr+1` bytes and drains the rest to /dev/null. Both
//   stages are pipeline members, so bash cannot exit before the bounded
//   stderr is written: nothing races the finalize. (A process substitution is
//   not waited for by bash and would reintroduce that race.)
// - The byte caps are also enforced on every chunk, before the buffer grows.
//   `StdioCollector` is configured with `waitForEnd: false`, so `dataChanged`
//   fires per read and `_watchStream` terminates the helper once the
//   accumulated text crosses the cap (at most one in-flight chunk beyond it).
//   The final result recomputes the exact UTF-8 byte length and marks
//   `overflow`. A partial payload is never handed to a parser as if it were
//   complete. This receiver guard is defence in depth behind the producer.
// - the QML deadline sends SIGTERM, then SIGKILL 500 ms later, and finally
//   settles by force if the process still never reports `exited`.
// - a failed start (binary missing) is detected through `runningChanged`.
// - exactly one `finished(result)` is emitted per run with
//   { ok, code, out, err, overflow, timedOut, startFailed, canceled, tag }.
// - `cancel()` is idempotent; a late result after cancellation is ignored by
//   the caller's generation/tag check.
// - `start()` while a run is active supersedes it: the request goes into a
//   bounded FIFO (8 entries) and the running process is terminated. A request
//   started from an `onFinished` handler begins immediately; any queued
//   request runs after it, so a handler cannot silently drop the queue. When
//   the FIFO is full, `start()` returns false instead of losing a request.
//   If a run had to be force-settled while its QProcess was still alive, the
//   queue waits for that process's `runningChanged`, so a late signal from
//   the abandoned process can never settle a newer run.

import QtQuick
import Quickshell.Io
import "../js/Bounds.js" as Bounds

Item {
  id: root
  visible: false
  width: 0
  height: 0

  // Configured per instance by the caller.
  property int maxOutBytes: Bounds.LIMITS.helperOutBytes
  property int maxErrBytes: Bounds.LIMITS.helperErrBytes
  property int timeoutMs: 4000
  property int producerTimeoutSeconds: 2
  readonly property int maxQueue: 8

  readonly property bool running: _active

  signal finished(var result)

  property bool _active: false
  property bool _settled: false
  property bool _started: false
  property bool _overflow: false
  property bool _timedOut: false
  property bool _startFailed: false
  property bool _canceled: false
  property bool _outChanged: false
  property bool _errChanged: false
  property var _tag: null
  property var _queue: []
  // Incremented for every run. A force-settled run leaves its QProcess alive
  // for a moment; signals from that abandoned process must never settle a
  // newer run or start a queued one on its behalf.
  property int _generation: 0
  property int _deferredGeneration: -1

  function start(argv, tag) {
    var list = []
    for (var i = 0; i < (argv || []).length; i++) list.push(String(argv[i]))
    if (list.length === 0) return false
    var label = tag === undefined ? null : tag
    if (_active || _deferredGeneration >= 0) {
      if (_queue.length >= maxQueue) {
        console.warn("notifications: BoundedProcess queue full; refusing a request")
        return false
      }
      _queue.push({ command: list, tag: label })
      // A newer request supersedes the running one: terminate it and let the
      // queue start once the process has actually stopped. Its result is
      // marked canceled and ignored by the caller's tag check. With no active
      // run, the queue waits for the abandoned process's `runningChanged`.
      if (_active && !_canceled) {
        _canceled = true
        _terminate()
      }
      return true
    }
    _begin(list, label)
    return true
  }

  function cancel() {
    // A cancellation (close, watchdog) also drops queued requests: a stale
    // read must not start after its consumer is gone.
    _queue = []
    if (!_active || _settled) return
    _canceled = true
    _terminate()
  }

  // Alias used by callers that think in terms of a watchdog.
  function terminate() {
    cancel()
  }

  function _begin(list, tag) {
    _generation++
    _overflow = false
    _timedOut = false
    _startFailed = false
    _canceled = false
    _settled = false
    _started = false
    // A StdioCollector keeps its last `text` when a new run produces no
    // bytes, so remember whether this run wrote anything; a run without
    // output must report an empty string, not the previous payload.
    _outChanged = false
    _errChanged = false
    _tag = tag
    _active = true
    proc.command = Bounds.producerCommand(list, maxOutBytes,
      producerTimeoutSeconds, maxErrBytes)
    // Arm the deadline before starting: a failed start can settle
    // synchronously from `runningChanged`, and the deadline must not be
    // restarted on an already-settled run afterwards.
    deadline.interval = Math.max(100, Number(timeoutMs) || 0)
    deadline.restart()
    proc.running = true
  }

  function _collectorText(collector) {
    return String(collector ? collector.text || "" : "")
  }

  // Cheap per-chunk guard. Reading `text.length` is O(1); an exact UTF-8 byte
  // count is only computed once, at the end. Because bytes >= UTF-16 units, a
  // text longer than the cap is certainly over the byte cap; a shorter text
  // may still be over and is caught by the exact check at finalize.
  function _watchStream(collector, cap) {
    if (_settled || _overflow) return
    var text = _collectorText(collector)
    if (Bounds.chunkOverflow(text.length, cap)) {
      _overflow = true
      _terminate()
    }
  }

  function _terminate() {
    if (!_active || _settled) return
    if (proc.running) {
      proc.signal(15)
      killTimer.restart()
    } else {
      _finalize(-1)
    }
  }

  function _finalize(code) {
    if (_settled) return
    _settled = true
    deadline.stop()
    killTimer.stop()
    forceTimer.stop()
    _active = false
    var outText = _outChanged ? _collectorText(outCollector) : ""
    var errText = _errChanged ? _collectorText(errCollector) : ""
    if (!_overflow && Bounds.utf8ByteLength(outText) > maxOutBytes) _overflow = true
    if (!_overflow && Bounds.utf8ByteLength(errText) > maxErrBytes) _overflow = true
    var exitCode = Number(code)
    if (!isFinite(exitCode)) exitCode = -1
    // The producer wrapper's `timeout` exits 124. Surface that as the same
    // timeout flag the QML deadline sets, for callers that branch on it.
    if (exitCode === 124 && !_startFailed) _timedOut = true
    var result = {
      ok: !_overflow && !_timedOut && !_startFailed && !_canceled && exitCode === 0,
      code: _startFailed ? -1 : exitCode,
      out: outText,
      err: errText,
      overflow: _overflow,
      timedOut: _timedOut,
      startFailed: _startFailed,
      canceled: _canceled,
      tag: _tag
    }
    // Normal exits null the Quickshell Process before `exited` is emitted, so
    // the queue can start immediately. A force-settled run can leave the
    // QProcess alive; starting now would let its late `exited` settle the new
    // run, so wait for that process's `runningChanged` instead. The deferral
    // is flagged before `finished` so a handler that starts the next request
    // queues it rather than racing the abandoned process.
    var generation = _generation
    var processAlive = proc.running
    if (processAlive) _deferredGeneration = generation
    finished(result)
    if (processAlive) return
    _beginNext()
  }

  // FIFO: a handler that started a run from `onFinished` is already active, so
  // the next queued request waits for that run instead of being dropped. No
  // run may start while an abandoned QProcess is still alive.
  function _beginNext() {
    if (_active || _deferredGeneration >= 0 || proc.running || _queue.length === 0) return
    var item = _queue.shift()
    _begin(item.command, item.tag)
  }

  Process {
    id: proc
    stdout: StdioCollector {
      id: outCollector
      // false: dataChanged fires per chunk, so the cap is enforced before the
      // buffer can grow. The text is complete when the process exits.
      waitForEnd: false
      onDataChanged: {
        root._outChanged = true
        root._watchStream(outCollector, root.maxOutBytes)
      }
    }
    stderr: StdioCollector {
      id: errCollector
      waitForEnd: false
      onDataChanged: {
        root._errChanged = true
        root._watchStream(errCollector, root.maxErrBytes)
      }
    }
    onStarted: function() { root._started = true }
    onExited: function(code, status) {
      // The collectors hold the complete text when `exited` is emitted.
      // Finalize synchronously: a deferred finalize could run after a new
      // start and settle the next run with the previous code/text.
      root._finalize(code)
    }
    onRunningChanged: {
      if (proc.running) return
      if (root._deferredGeneration >= 0) {
        // The abandoned run's QProcess has now fully stopped. A stale
        // notification whose generation is no longer current cannot start
        // anything; the token keeps a late signal from acting for a newer run.
        var deferred = root._deferredGeneration
        root._deferredGeneration = -1
        if (deferred === root._generation && !root._active) root._beginNext()
        return
      }
      // QProcess failed to start: it never emits `exited`, so settling only
      // on onExited would block the caller forever.
      if (!root._active || root._settled) return
      if (root._started) return
      root._startFailed = true
      root._finalize(-1)
    }
  }

  Timer {
    id: deadline
    repeat: false
    onTriggered: {
      root._timedOut = true
      root._terminate()
    }
  }

  Timer {
    id: killTimer
    interval: 500
    repeat: false
    onTriggered: {
      if (proc.running) proc.signal(9)
      forceTimer.restart()
    }
  }

  // SIGKILL should always end the process, but if the compositor or a stuck
  // child keeps Quickshell from reporting `exited`, settle anyway so queues,
  // callbacks and timers can move on. The still-live QProcess is then written
  // off: `_finalize` defers the queue until its `runningChanged`.
  Timer {
    id: forceTimer
    interval: 700
    repeat: false
    onTriggered: {
      if (proc.running) proc.running = false
      root._finalize(-1)
    }
  }
}
