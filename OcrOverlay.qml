import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Click-to-action OCR overlay. The bar glyph is just a launcher;
// this holds the four capture modes, the last result, and history.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool windowed: false
  property bool busy: false
  property bool copied: false
  property string pendingMode: ""
  property string filterText: ""
  property string resultText: ""
  property string resultLangs: ""
  property string resultError: ""
  property int resultChars: 0
  property string langs: "eng"
  property int historySize: 20
  property bool upscale: true
  property var history: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: windowed ? 720 : Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
  property int cardHeight: windowed ? 560 : Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

  readonly property string helper: {
    var u = Qt.resolvedUrl("ocr.py").toString()
    if (u.indexOf("file://") === 0) {
      var path = u.substring(7)
      if (path.charAt(0) !== "/") path = "/" + path
      try { return decodeURIComponent(path) } catch (e) { return path }
    }
    return u
  }

  function applyPayload(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.langs) root.langs = String(payload.langs)
    if (payload.historySize) root.historySize = Number(payload.historySize) || 20
    if (payload.upscale !== undefined) {
      var up = payload.upscale
      root.upscale = !(up === false || up === "false" || up === 0 || up === "0")
    }
  }

  function open(payloadJson) {
    if (root.busy) return
    root.applyPayload(payloadJson)
    root.opened = true
    root.copied = false
    root.reloadHistory()
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.guts444.ocr")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function python() {
    return "/usr/bin/python3"
  }

  function ocrCommand(mode) {
    var cmd = [python(), helper, mode, "--langs", root.langs, "--history-size", String(root.historySize)]
    cmd.push(root.upscale ? "--upscale" : "--no-upscale")
    return cmd
  }

  function startOcr(mode) {
    if (ocrProc.running) return
    root.busy = true
    root.resultError = ""
    root.copied = false
    root.pendingMode = mode
    // Re-hide for capture modes: a glyph click during the 180ms window or
    // mid-slurp must not re-open the overlay into the capture.
    if (mode !== "clip") root.opened = false
    ocrProc.command = ocrCommand(mode)
    ocrProc.running = true
  }

  function runMode(mode) {
    root.pendingMode = mode
    if (mode === "clip") {
      startOcr(mode)
      return
    }
    // Hide so grim/slurp see the real screen, not this overlay.
    root.opened = false
    hideThenRun.restart()
  }

  function applyOcrOutput(raw, exitCode) {
    root.busy = false
    var data = null
    try { data = JSON.parse(String(raw || "").trim()) } catch (e) { data = null }
    if (!data || typeof data !== "object") {
      root.resultError = exitCode === 0 ? "bad helper output" : "ocr helper failed"
      root.resultText = ""
      root.resultChars = 0
      root.opened = true
      return
    }
    if (data.ok) {
      root.resultText = String(data.text || "")
      root.resultChars = Number(data.chars) || root.resultText.length
      root.resultLangs = String(data.langs || root.langs)
      root.resultError = ""
      root.copied = true
      copiedOff.restart()
    } else {
      root.resultError = String(data.error || "ocr failed")
      if (!root.resultText) {
        root.resultChars = 0
        root.resultLangs = String(data.langs || root.langs)
      }
    }
    root.opened = true
    root.reloadHistory()
  }

  function reloadHistory() {
    if (histProc.running) return
    histProc.command = [python(), helper, "history", "list"]
    histProc.running = true
  }

  function applyHistory(raw) {
    var data = null
    try { data = JSON.parse(String(raw || "").trim()) } catch (e) { data = null }
    if (!data || data.ok !== true || !data.items) {
      root.history = []
      rebuildDisplay()
      return
    }
    root.history = data.items
    rebuildDisplay()
  }

  function rebuildDisplay() {
    var q = String(root.filterText || "").toLowerCase()
    displayModel.clear()
    var items = root.history || []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      var text = String(it.text || "")
      if (q && text.toLowerCase().indexOf(q) === -1) continue
      var preview = text.replace(/\s+/g, " ")
      if (preview.length > 90) preview = preview.substring(0, 87) + "…"
      displayModel.append({
        itemId: String(it.id || ""),
        preview: preview,
        fullText: text,
        langs: String(it.langs || ""),
        chars: Number(it.chars) || text.length
      })
    }
  }

  function setFilter(next) {
    root.filterText = next
    rebuildDisplay()
  }

  function recopyId(itemId) {
    if (!itemId || copyProc.running) return
    copyProc.command = [python(), helper, "history", "copy", itemId]
    copyProc.running = true
  }

  function deleteId(itemId) {
    if (!itemId || delProc.running) return
    delProc.command = [python(), helper, "history", "delete", itemId]
    delProc.running = true
  }

  ListModel { id: displayModel }

  Timer {
    id: hideThenRun
    interval: 180
    repeat: false
    onTriggered: root.startOcr(root.pendingMode)
  }

  Timer {
    id: copiedOff
    interval: 1400
    repeat: false
    onTriggered: root.copied = false
  }

  Process {
    id: ocrProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.applyOcrOutput(stdout.text, exitCode) }
  }

  Process {
    id: histProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.history = []; root.rebuildDisplay(); return }
      root.applyHistory(stdout.text)
    }
  }

  Process {
    id: copyProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) { root.copied = true; copiedOff.restart() }
    }
  }

  Process {
    id: delProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyHistory(stdout.text)
      else root.reloadHistory()
    }
  }

  // Live shell: fullscreen layer-shell overlay (clipboard/emojis pattern).
  // Scratch/smoke: a regular FloatingWindow so it can be screenshotted
  // without covering the desktop or disappearing as a layer surface.
  FloatingWindow {
    id: floatWin
    visible: root.opened && root.windowed
    title: "OCR"
    implicitWidth: 760
    implicitHeight: 600
    color: root.background

    Loader {
      anchors.fill: parent
      anchors.margins: 12
      active: root.opened && root.windowed
      sourceComponent: cardComp
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened && !root.windowed
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-ocr"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Loader {
      anchors.centerIn: parent
      width: root.cardWidth
      height: root.cardHeight
      active: root.opened && !root.windowed
      sourceComponent: cardComp
    }
  }

  Component {
    id: cardComp
    BorderSurface {
      id: card
      width: parent ? parent.width : root.cardWidth
      height: parent ? parent.height : root.cardHeight
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        Row {
          id: titleRow
          width: parent.width
          spacing: Style.spacing.md

          Text {
            text: "OCR"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.busy ? "working…" : (root.copied ? "copied" : "")
            color: root.copied ? root.selectedText : root.foreground
            opacity: root.busy || root.copied ? 1 : 0
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          id: modeRow
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: [
              { id: "region", label: "Select region" },
              { id: "clip", label: "Clipboard image" },
              { id: "screen", label: "Full screen" },
              { id: "window", label: "Window" }
            ]

            Rectangle {
              required property var modelData
              width: (parent.width - Style.space(8) * 3) / 4
              height: Math.max(Style.space(32), Style.font.body + Style.spacing.controlPaddingY * 2)
              radius: root.cornerRadius
              color: modeArea.containsMouse ? root.selectedBackground : "transparent"
              border.color: root.border
              border.width: 1

              Text {
                anchors.centerIn: parent
                text: parent.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              MouseArea {
                id: modeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.runMode(parent.modelData.id)
              }
            }
          }
        }

        Rectangle {
          id: resultBox
          width: parent.width
          height: Math.max(Style.space(120), parent.height * 0.28)
          radius: root.cornerRadius
          color: "transparent"
          border.color: root.border
          border.width: 1
          clip: true

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(6)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: root.resultError ? "error" : (root.resultText ? (root.resultChars + " chars") : "no result yet")
                color: root.resultError ? Color.urgent : root.foreground
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: root.resultLangs.length > 0 && root.resultText.length > 0
                text: root.resultLangs
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: parent.width
              height: parent.height - Style.font.caption - Style.space(6)
              text: root.resultError ? root.resultError : (root.resultText || "Pick a capture mode.")
              color: root.foreground
              opacity: root.resultText ? 1 : 0.6
              wrapMode: Text.Wrap
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Rectangle {
          id: filterBox
          width: parent.width
          height: Math.max(Style.space(32), Style.font.body + Style.spacing.controlPaddingY * 2)
          radius: root.cornerRadius
          color: "transparent"
          border.color: root.border
          border.width: 1

          TextInput {
            id: filterField
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: Text.AlignVCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            focus: true
            text: root.filterText
            onTextChanged: root.setFilter(text)
            Keys.onEscapePressed: root.dismiss()
          }

          Text {
            anchors.fill: filterField
            verticalAlignment: Text.AlignVCenter
            text: "Search history…"
            color: root.foreground
            opacity: 0.45
            visible: filterField.text.length === 0 && !filterField.activeFocus
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        ListView {
          id: historyList
          width: parent.width
          height: Math.max(0, parent.height - titleRow.height - modeRow.height - resultBox.height - filterBox.height - Style.spacing.md * 4)
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          model: displayModel

          delegate: Rectangle {
            required property int index
            required property string itemId
            required property string preview
            required property string langs
            required property int chars

            width: historyList.width
            height: Math.max(Style.space(36), Style.font.body + Style.spacing.rowPaddingX)
            radius: root.cornerRadius
            color: rowArea.containsMouse ? root.selectedBackground : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                width: parent.width - delBtn.width - Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: preview + "  ·  " + chars
                color: root.foreground
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Rectangle {
                id: delBtn
                width: Style.space(28)
                height: Style.space(24)
                anchors.verticalCenter: parent.verticalCenter
                radius: root.cornerRadius
                color: "transparent"
                border.color: root.border
                border.width: 1

                Text {
                  anchors.centerIn: parent
                  text: "×"
                  color: root.foreground
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.deleteId(itemId)
                }
              }
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              anchors.rightMargin: delBtn.width + Style.space(8)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.recopyId(itemId)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: displayModel.count === 0
            text: root.filterText ? "No matches" : "History is empty"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
