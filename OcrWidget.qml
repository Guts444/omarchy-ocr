import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OCR launcher + last-result status. Click toggles the overlay
// (same summon path as omarchy.menu → its overlay/menu).
BarWidget {
  id: root
  moduleName: "io.github.guts444.ocr"

  property int lastChars: 0
  property bool lastOk: false
  property bool hasStatus: false
  property bool working: false
  property string lastError: ""

  readonly property string glyph: "A▤"
  readonly property string statusText: {
    if (working) return glyph + "…"
    if (!hasStatus) return glyph
    if (!lastOk) return glyph + " · !"
    if (lastChars > 0) return glyph + " · " + lastChars
    return glyph
  }
  readonly property string tooltipText: {
    if (working) return "OCR — working…"
    if (!hasStatus) return "OCR — click to grab text"
    if (!lastOk) return "OCR failed" + (lastError ? ": " + lastError : "")
    return "OCR · " + lastChars + " chars — click to open"
  }

  function applyStatus(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    if (data.state === "working") {
      root.working = true
      return
    }
    root.working = false
    hasStatus = true
    lastOk = data.ok === true
    lastChars = Number(data.chars) || 0
    lastError = String(data.error || "")
  }

  function toggleOverlay() {
    var langs = String(setting("langs", "eng"))
    var hist = Number(setting("historySize", 20))
    var upRaw = setting("upscale", true)
    var up = !(upRaw === false || upRaw === "false" || upRaw === 0 || upRaw === "0")
    var payload = JSON.stringify({ langs: langs, historySize: hist, upscale: up })
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function") {
      root.bar.shell.toggle(root.moduleName, payload)
      return
    }
    if (root.bar && typeof root.bar.run === "function") {
      var quoted = (typeof root.bar.shellQuote === "function") ? root.bar.shellQuote(payload) : ("'" + payload.replace(/'/g, "'\\''") + "'")
      root.bar.run("omarchy-shell shell toggle " + root.moduleName + " " + quoted)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: statusFile
    path: Quickshell.env("HOME") + "/.cache/omarchy/ocr/status.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onLoadFailed: { root.hasStatus = false; root.lastChars = 0; root.lastError = ""; root.working = false }
    onFileChanged: reload()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.statusText
    fontFamily: "monospace"
    fontSize: Style.font.caption
    horizontalMargin: 6
    dimmed: !root.hasStatus
    active: root.hasStatus && !root.lastOk
    tooltipText: root.tooltipText
    onPressed: root.toggleOverlay()
  }
}
