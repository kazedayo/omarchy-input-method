import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar indicator + picker panel for the active fcitx5 input method.
// Follows the first-party panel pattern (network/audio): Panel lifecycle,
// KeyboardPanel popup, hero + section headers + CursorSurface rows driven by
// one keyboard/mouse cursor.
//
// Polls every 100ms: fcitx5 exposes no dbus change signal for the active IM
// (introspection shows method-only interfaces) or for Rime's ascii mode.
// A poll spawns fcitx5-remote (~1.7ms CPU); the Rime ascii check adds a
// busctl call (~1.7ms) but only runs while Rime is the active IM.
// ponytail: flat 100ms — raise to 200ms if battery matters more than latency.
Panel {
  id: root
  moduleName: "io.github.kaz.input-method"
  ipcTarget: "io.github.kaz.input-method"

  // Raw base IM from fcitx5-remote -n, with keyboard-* mapped to "en".
  property string baseIM: ""
  // Last known Rime ascii-mode reading, kept across IM switches so
  // re-entering Rime shows the real mode instead of a 中 flash.
  property bool asciiOn: false
  // "en" | "zh" | "ren" (rime ascii mode) | raw IM name | "" until first read
  readonly property string imState: baseIM === "rime" ? (asciiOn ? "ren" : "zh") : baseIM
  property bool basePending: false
  property var imList: []
  property var schemaList: []
  property string currentSchema: ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // One font for Latin and CJK labels; otherwise the CJK fallback's taller
  // line box makes glyphs jump vertically when switching IMs.
  readonly property string cjkFamily: "Noto Sans CJK JP"

  readonly property string label: {
    if (imState === "zh") return "中"
    if (imState === "mozc") return "あ"
    if (imState === "en" || imState === "ren") return "EN"
    return imState.toUpperCase().substring(0, 4)
  }
  readonly property string tip: {
    if (imState === "zh") return "中文 — Rime"
    if (imState === "mozc") return "日本語 — Mozc"
    if (imState === "ren") return "English — Rime (ascii mode)"
    if (imState === "en") return "English — US keyboard"
    return imState
  }

  readonly property bool rimeActive: baseIM === "rime"
  readonly property bool mozcActive: imState === "mozc"
  // Schema switcher only makes sense with more than one schema.
  readonly property bool hasSchemaPicker: rimeActive && schemaList.length > 1

  readonly property color hoverFill: bar ? Style.hoverFillFor(fg, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(fg, Color.accent) : "transparent"

  // Flat cursor model shared by keyboard and mouse (audio/network pattern):
  // row visuals derive from hasCursor/current, never from containsMouse.
  readonly property var cursorTargets: {
    var t = []
    for (var i = 0; i < imList.length; i++) t.push({ kind: "im", value: imList[i] })
    if (hasSchemaPicker) for (var j = 0; j < schemaList.length; j++) t.push({ kind: "schema", value: schemaList[j] })
    if (rimeActive) t.push({ kind: "ascii" })
    if (mozcActive) t.push({ kind: "mozc" })
    return t
  }
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property int asciiIndex: imList.length + (hasSchemaPicker ? schemaList.length : 0)

  visible: imState !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function queryBase() {
    // While the panel is open, input focus sits on the popup (a layer surface
    // with no text input), so fcitx5-remote -n falls back to the keyboard IM.
    // Freeze the polled state so the current row stays on the IM that was
    // actually active.
    if (opened) return
    // A query already in flight predates the IM change, so re-run once it lands.
    if (baseProc.running) {
      basePending = true
      return
    }
    basePending = false
    baseProc.running = true
  }

  // Rime ascii mode has no change signal; poll it only while Rime is active.
  // A busy ascii query is simply re-checked on the next tick.
  function queryAscii() {
    if (opened || asciiProc.running) return
    asciiProc.running = true
  }

  Component.onCompleted: queryBase()

  function moveCursor(delta) {
    cursorIndex = Math.max(0, Math.min(cursorTargets.length - 1, cursorIndex + delta))
  }

  function activateCursor() {
    var t = cursorTargets[cursorIndex]
    if (!t || !bar) return
    close()
    if (t.kind === "im") bar.run("fcitx5-remote -s " + t.value)
    else if (t.kind === "schema") bar.run("busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetSchema s " + t.value)
    else if (t.kind === "ascii") bar.run("busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetAsciiMode b " + (imState === "ren" ? "false" : "true"))
    else if (t.kind === "mozc") bar.run("/usr/lib/mozc/mozc_tool --mode=config_dialog")
  }

  onOpenedChanged: {
    if (opened) {
      listProc.running = true
      schemaProc.running = true
      cursorActive = false
      cursorIndex = 0
    }
  }

  // busctl renders a(ss) as a count followed by quoted (name, layout) pairs.
  function parseGroup(text) {
    var parts = (String(text).match(/"[^"]*"/g) || []).map(function(s) { return s.slice(1, -1) })
    var names = []
    for (var i = 1; i + 1 < parts.length; i += 2) if (parts[i]) names.push(parts[i])
    return names
  }

  function glyphFor(name) {
    if (name === "rime") return "中"
    if (name === "mozc") return "あ"
    if (name.indexOf("keyboard-") === 0) return "EN"
    return name.toUpperCase().substring(0, 4)
  }

  function labelFor(name) {
    if (name === "rime") return "中文 — Rime"
    if (name === "mozc") return "日本語 — Mozc"
    if (name.indexOf("keyboard-") === 0) return "English — " + name.substring(9)
    return name
  }

  function isActive(name) {
    if (name === "rime") return imState === "zh" || imState === "ren"
    if (name.indexOf("keyboard-") === 0) return imState === "en"
    return imState === name
  }

  function prettySchema(id) {
    return id.split("_").map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
  }

  Timer {
    interval: 100
    running: true
    repeat: true
    onTriggered: root.queryBase()
  }

  // Direct spawns, no bash: at 10 ticks/second the ~1.2ms bash startup the
  // combined script paid per tick is worth avoiding.
  Process {
    id: baseProc
    command: ["fcitx5-remote", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var im = String(text).trim()
        // Keep the last label on a failed read (fcitx5 restarting); it
        // recovers on the next tick.
        if (im === "") return
        if (im.indexOf("keyboard-") === 0) im = "en"
        root.baseIM = im
        if (im === "rime") root.queryAscii()
      }
    }
    onRunningChanged: {
      if (running) return
      if (root.basePending) root.queryBase()
    }
  }

  Process {
    id: asciiProc
    command: ["busctl", "--user", "call", "org.fcitx.Fcitx5", "/rime", "org.fcitx.Fcitx.Rime1", "IsAsciiMode"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // busctl prints "b true" / "b false"; an empty read (fcitx5
        // restarting) keeps the last known mode.
        var out = String(text).trim()
        if (out !== "") root.asciiOn = out.endsWith("true")
      }
    }
  }

  Process {
    id: listProc
    command: ["bash", "-c", "busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 InputMethodGroupInfo s Default 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = root.parseGroup(text)
        if (names.length > 0) root.imList = names
      }
    }
  }

  Process {
    id: schemaProc
    command: ["bash", "-c", "busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 ListAllSchemas 2>/dev/null ; busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 GetCurrentSchema 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).trim().split("\n")
        var m = lines[0] ? lines[0].match(/"[^"]*"/g) : null
        root.schemaList = m ? m.map(function(s) { return s.slice(1, -1) }) : []
        var c = lines.length > 1 ? lines[1].match(/"([^"]*)"/) : null
        root.currentSchema = c ? c[1] : ""
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    fontSize: Style.font.caption
    horizontalMargin: 6
    // One font for Latin and CJK labels; otherwise the CJK fallback's taller
    // line box makes the glyph jump vertically when switching IMs.
    fontFamily: "Noto Sans CJK JP"
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: root.tip
    onPressed: function(button) {
      if (button === Qt.RightButton) {
        if (root.bar) root.bar.run("fcitx5-remote -t")
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          if (dy >= 0) return
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: IM glyph · title · current IM ----------
          PanelHero {
            width: parent.width
            title: "Input Method"
            meta: root.tip
            foreground: root.fg
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.label
                color: root.fg
                font.family: root.cjkFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- Input methods ----
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "INPUT METHODS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.imList

              delegate: PanelRow {
                required property var modelData
                required property int index
                flatIndex: index
                glyph: root.glyphFor(modelData)
                label: root.labelFor(modelData)
                checked: root.isActive(modelData)
                onActivate: {
                  root.close()
                  if (root.bar) root.bar.run("fcitx5-remote -s " + modelData)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.hasSchemaPicker
            foreground: root.fg
          }

          Column {
            visible: root.hasSchemaPicker
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RIME SCHEMA"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.hasSchemaPicker ? root.schemaList : []

              delegate: PanelRow {
                required property var modelData
                required property int index
                flatIndex: root.imList.length + index
                label: root.prettySchema(modelData)
                checked: modelData === root.currentSchema
                onActivate: {
                  root.close()
                  if (root.bar) root.bar.run("busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetSchema s " + modelData)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.rimeActive || root.mozcActive
            foreground: root.fg
          }

          Column {
            visible: root.rimeActive || root.mozcActive
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: root.mozcActive ? "MOZC" : "RIME"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            PanelRow {
              visible: root.rimeActive
              flatIndex: root.asciiIndex
              glyph: "A"
              label: "English mode"
              checked: root.imState === "ren"
              onActivate: {
                root.close()
                if (root.bar) root.bar.run("busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetAsciiMode b " + (root.imState === "ren" ? "false" : "true"))
              }
            }

            PanelRow {
              visible: root.mozcActive
              flatIndex: root.imList.length
              glyph: "あ"
              label: "Mozc settings…"
              onActivate: {
                root.close()
                if (root.bar) root.bar.run("/usr/lib/mozc/mozc_tool --mode=config_dialog")
              }
            }
          }
        }
      }
    }
  }

  // Shared picker row: glyph column + label with the stock CursorSurface
  // chrome (hover/selected fills come from hasCursor/current, like audio).
  component PanelRow: CursorSurface {
    id: row
    width: parent.width
    required property int flatIndex
    property string glyph: ""
    property string label: ""
    property bool checked: false
    signal activate()

    hasCursor: root.cursorActive && root.cursorIndex === row.flatIndex
    current: row.checked
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: rowInner.implicitHeight + Style.spacing.xl

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.glyph
        color: root.fg
        font.family: root.cjkFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: row.label
        color: root.fg
        font.family: root.cjkFamily
        font.pixelSize: Style.font.body
        font.bold: row.checked
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorIndex = row.flatIndex
      }
      onClicked: row.activate()
    }
  }
}
