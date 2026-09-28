import QtQuick
import Quickshell.Io

// Runs the status script with a cap on what it may print and a hard deadline.
// done(payload) receives the parsed JSON document, or null when the script
// failed, printed more than maxChars, ran past timeoutMs or printed something
// that is not JSON. Output is read in raw chunks, so the cap applies before
// any line or document is assembled.
Process {
  id: proc

  property int maxChars: 262144
  property int timeoutMs: 120000
  property string buf: ""
  property bool killed: false

  signal done(var payload)

  function stop() {
    if (!running) return
    killed = true
    buf = ""
    signal(15)
    killTimer.restart()
  }

  stdout: SplitParser {
    splitMarker: ""
    onRead: function(chunk) {
      if (proc.killed) return
      proc.buf += chunk
      if (proc.buf.length > proc.maxChars) proc.stop()
    }
  }

  onStarted: {
    buf = ""
    killed = false
    deadline.restart()
  }

  onExited: {
    deadline.stop()
    killTimer.stop()
    var text = buf
    buf = ""
    var payload = null
    if (!killed) {
      try { payload = JSON.parse(text) } catch (e) { payload = null }
    }
    done(payload)
  }

  property Timer deadline: Timer {
    interval: proc.timeoutMs
    onTriggered: proc.stop()
  }
  property Timer killTimer: Timer {
    interval: 2000
    onTriggered: proc.signal(9)
  }
}
