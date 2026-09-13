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
  moduleName: "io.github.kaz.omarchy-input-method"
  ipcTarget: "io.github.kaz.omarchy-input-method"

  // Raw base IM from fcitx5-remote -n, with keyboard-* mapped to "en".
  property string baseIM: ""
  // Last known Rime ascii-mode reading, kept across IM switches so
  // re-entering Rime shows the real mode instead of a 中 flash.
  property bool asciiOn: false
  // ascii_mode states from the active schema (["粵","英"]);
  // fallback 中/English when the schema can't be read (stock fcitx5-rime).
  property var asciiStates: []
  // "en" | "zh" | "ren" (rime ascii mode) | raw IM name | "" until first read
  readonly property string imState: baseIM === "rime" ? (asciiOn ? "ren" : "zh") : baseIM
  property bool basePending: false
  property var imList: []
  property var schemaList: []
  property string currentSchema: ""
  // Rime schema switches (full_shape, simplification, emoji, …), toggled live
  // via GetOption/SetOption on org.fcitx.Fcitx.Rime1. Only patched fcitx5-rime
  // builds expose those methods; probeProc feature-detects at panel open.
  property bool optionsApi: false
  property var optRows: []

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
  readonly property int schemaRowsCount: hasSchemaPicker ? schemaList.length : 0
  readonly property bool showOptions: rimeActive && optionsApi && optRows.length > 0

  readonly property color hoverFill: bar ? Style.hoverFillFor(fg, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(fg, Color.accent) : "transparent"

  // Flat cursor model shared by keyboard and mouse (audio/network pattern):
  // row visuals derive from hasCursor/current, never from containsMouse.
  readonly property var cursorTargets: {
    var t = []
    for (var i = 0; i < imList.length; i++) t.push({ kind: "im", value: imList[i] })
    if (hasSchemaPicker) for (var j = 0; j < schemaList.length; j++) t.push({ kind: "schema", value: schemaList[j] })
    if (rimeActive) t.push({ kind: "ascii" })
    if (showOptions) for (var k = 0; k < optRows.length; k++) t.push({ kind: "option", row: optRows[k] })
    if (mozcActive) t.push({ kind: "mozc" })
    return t
  }
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property int asciiIndex: imList.length + schemaRowsCount
  readonly property var optionGroups: buildOptionGroups(optRows)

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

  // Until the first input context is activated, fcitx5-remote -n prints
  // nothing and the widget would stay hidden until the user focuses a text
  // field. Seed the label from the group's first IM (fcitx5's own
  // no-focus fallback); the next real poll overwrites it.
  function queryDefault() {
    if (!listProc.running) listProc.running = true
  }

  Component.onCompleted: {
    queryBase()
    queryDefault()
  }

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
    else if (t.kind === "option") root.activateOptionRow(t.row)  // stays open for multi-toggle
    else if (t.kind === "mozc") bar.run("/usr/lib/mozc/mozc_tool --mode=config_dialog")
  }

  onOpenedChanged: {
    if (opened) {
      listProc.running = true
      schemaProc.running = true
      probeProc.running = true
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

  // ---- Rime schema switches (needs patched fcitx5-rime) ----
  // Option list comes from the compiled schema YAML (what rime actually
  // runs, patches merged); live state and toggling go through DBus.

  // Targeted parser for the `switches:` block: librime's compiled output
  // uses inline lists and scalars only.
  function parseSwitchesYaml(text) {
    var lines = String(text).split("\n")
    var res = []
    var i = 0
    while (i < lines.length && lines[i].indexOf("switches:") !== 0) i++
    if (i === lines.length) return res

    function unquote(s) {
      s = s.trim()
      if (s.length > 1 && (s.charAt(0) === "\"" || s.charAt(0) === "'") && s.charAt(s.length - 1) === s.charAt(0))
        s = s.slice(1, -1)
      return s
    }
    function val(v) {
      v = v.trim()
      if (v.length > 1 && v.charAt(0) === "[" && v.charAt(v.length - 1) === "]")
        return v.slice(1, -1).split(",").map(unquote).filter(function(s) { return s !== "" })
      return unquote(v)
    }

    var cur = null
    for (i++; i < lines.length; i++) {
      var line = lines[i]
      if (line.trim() === "" || line.trim().charAt(0) === "#") continue
      if (line.charAt(0) !== " ") break
      var m = line.match(/^\s*-\s*([\w-]+):?\s*(.*)$/)
      if (m) {
        if (cur) res.push(cur)
        cur = {}
        if (m[2] !== "") cur[m[1]] = val(m[2])
        continue
      }
      m = line.match(/^\s*([\w-]+):\s*(.*)$/)
      if (m && cur && m[2] !== "") cur[m[1]] = val(m[2])
    }
    if (cur) res.push(cur)
    return res
  }

  // Same skip rules as fcitx5-rime's own option actions: <2 states, or a
  // name switch without exactly 2 states, is ignored; ascii_mode is already
  // exposed as the English-mode row.
  function buildOptionRows(sws) {
    var rows = []
    for (var i = 0; i < sws.length; i++) {
      var sw = sws[i]
      if (!sw.states || sw.states.length < 2) continue
      if (sw.name) {
        if (sw.states.length !== 2 || sw.name === "ascii_mode") continue
        rows.push({ type: "toggle", option: sw.name, labels: sw.states, on: false })
      } else if (sw.options && sw.options.length === sw.states.length) {
        for (var j = 0; j < sw.options.length; j++)
          rows.push({ type: "select", option: sw.options[j], label: sw.states[j], group: sw.options.slice(), active: false })
      }
    }
    return rows
  }

  // Semantic segmentation: multi-way charset switches and the simplification
  // family are hanzi variants; shape, punctuation and emoji keep their own
  // groups; anything unknown falls into a catch-all.
  function optionGroupTitle(row) {
    if (row.type === "select") return "HANZI VARIANT"
    switch (row.option) {
      case "full_shape":
        return "SHAPE"
      case "ascii_punct":
        return "PUNCTUATION"
      default:
        if (/^(simplification|traditionalization|extended_charset|variants_|trad_)/.test(row.option)) return "HANZI VARIANT"
        if (row.option.indexOf("emoji") !== -1) return "SUGGESTIONS"
        return "OPTIONS"
    }
  }

  // Group rows by title, keeping first-appearance (schema) order. Toggles and
  // selects render as different row components, so each group tracks the
  // optRows index of its first row of each kind for the flat cursor numbering.
  function buildOptionGroups(rows) {
    var groups = []
    for (var i = 0; i < rows.length; i++) {
      var title = optionGroupTitle(rows[i])
      var g = null
      for (var k = 0; k < groups.length; k++)
        if (groups[k].title === title) { g = groups[k]; break }
      if (!g) {
        g = { title: title, toggles: [], selects: [], firstToggleIndex: -1, firstSelectIndex: -1 }
        groups.push(g)
      }
      if (rows[i].type === "toggle") {
        if (g.firstToggleIndex === -1) g.firstToggleIndex = i
        g.toggles.push(rows[i])
      } else {
        if (g.firstSelectIndex === -1) g.firstSelectIndex = i
        g.selects.push(rows[i])
      }
    }
    return groups
  }

  // Runs once both schemaProc and probeProc have landed for this open.
  function loadOptions() {
    if (!opened || !optionsApi || currentSchema === "" || optionsProc.running) return
    optionsProc.command = ["bash", "-c",
      "cat \"$HOME/.local/share/fcitx5/rime/build/" + currentSchema + ".schema.yaml\""]
    optionsProc.running = true
  }

  function refreshOptionStates() {
    var names = []
    for (var i = 0; i < optRows.length; i++)
      if (names.indexOf(optRows[i].option) === -1) names.push(optRows[i].option)
    optStateProc.command = ["bash", "-c",
      "for o in " + names.join(" ") + "; do v=$(busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 GetOption s \"$o\" 2>/dev/null); echo \"$o $v\"; done"]
    optStateProc.running = true
  }

  function applyOptionState(name, value) {
    for (var i = 0; i < optRows.length; i++) {
      var r = optRows[i]
      if (r.option === name) { if (r.type === "toggle") r.on = value; else r.active = value }
    }
    optRows = optRows.slice() // fresh array so the Repeater re-renders
  }

  function activateOptionRow(row) {
    if (!bar) return
    var call = "busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetOption sb "
    if (row.type === "toggle") {
      var nv = !row.on
      bar.run(call + row.option + (nv ? " true" : " false"))
      applyOptionState(row.option, nv)
    } else {
      // exclusive select, like rime's own switch menu: chosen true, rest false
      var cmd = call + row.option + " true"
      for (var i = 0; i < row.group.length; i++)
        if (row.group[i] !== row.option) cmd += "; " + call + row.group[i] + " false"
      bar.run(cmd)
      applyOptionState(row.option, true)
    }
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
        if (im === "") {
          // Nothing focused yet on a fresh boot: seed from the group default.
          if (root.baseIM === "") root.queryDefault()
          return
        }
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
        if (names.length > 0) {
          root.imList = names
          if (root.baseIM === "") {
            var im = names[0]
            root.baseIM = im.indexOf("keyboard-") === 0 ? "en" : im
          }
        }
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
        root.loadOptions()
      }
    }
  }

  // Does this fcitx5-rime expose SetOption/GetOption? (patched builds only)
  Process {
    id: probeProc
    command: ["bash", "-c", "busctl --user introspect org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.optionsApi = String(text).indexOf("SetOption") !== -1
        root.loadOptions()
      }
    }
  }

  Process {
    id: optionsProc
    command: ["bash", "-c", "true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var sws = root.parseSwitchesYaml(String(text))
        for (var i = 0; i < sws.length; i++) {
          var sw = sws[i]
          if (sw.name === "ascii_mode" && sw.states && sw.states.length === 2) {
            root.asciiStates = sw.states.slice()
            break
          }
        }
        root.optRows = root.buildOptionRows(sws)
        if (root.optRows.length > 0) root.refreshOptionStates()
      }
    }
  }

  Process {
    id: optStateProc
    command: ["bash", "-c", "true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).trim().split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split(" ")
          if (parts.length === 3) root.applyOptionState(parts[0], parts[2] === "true")
        }
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

          // ---- Rime (merged): schemas · English mode · segmented switches ----
          PanelSeparator {
            visible: root.rimeActive || root.mozcActive
            foreground: root.fg
          }

          Column {
            visible: root.rimeActive
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RIME"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            SubHeader {
              visible: root.hasSchemaPicker
              text: "SCHEMA"
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

            ToggleRow {
              flatIndex: root.asciiIndex
              offText: root.asciiStates.length === 2 ? root.asciiStates[0] : "中文"
              onText: root.asciiStates.length === 2 ? root.asciiStates[1] : "English"
              on: root.imState === "ren"
              onActivate: {
                root.close()
                if (root.bar) root.bar.run("busctl --user call org.fcitx.Fcitx5 /rime org.fcitx.Fcitx.Rime1 SetAsciiMode b " + (root.imState === "ren" ? "false" : "true"))
              }
            }

            Repeater {
              model: root.showOptions ? root.optionGroups : []

              delegate: Column {
                id: groupDelegate
                required property var modelData
                width: parent.width
                spacing: Style.space(6)

                SubHeader {
                  text: groupDelegate.modelData.title
                  extraTop: Style.space(8)
                }

                Repeater {
                  model: groupDelegate.modelData.toggles

                  delegate: ToggleRow {
                    required property var modelData
                    required property int index
                    flatIndex: root.imList.length + root.schemaRowsCount + 1 + groupDelegate.modelData.firstToggleIndex + index
                    offText: modelData.labels[0]
                    onText: modelData.labels[1]
                    on: modelData.on
                    onActivate: root.activateOptionRow(modelData)
                  }
                }

                Repeater {
                  model: groupDelegate.modelData.selects

                  delegate: PanelRow {
                    required property var modelData
                    required property int index
                    flatIndex: root.imList.length + root.schemaRowsCount + 1 + groupDelegate.modelData.firstSelectIndex + index
                    label: modelData.label
                    checked: modelData.active
                    onActivate: root.activateOptionRow(modelData)
                  }
                }
              }
            }
          }

          // ---- Mozc ----
          Column {
            visible: root.mozcActive
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MOZC"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            PanelRow {
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
      // No glyph → no reserved column and no leading gap: label rows align
      // flush with the row edge instead of drifting past a dead 22px box.
      spacing: row.glyph !== "" ? Style.space(8) : 0

      Text {
        textFormat: Text.PlainText
        text: row.glyph
        visible: row.glyph !== ""
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
        width: row.glyph !== "" ? parent.width - Style.space(22) - Style.space(8) : parent.width
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

  // Dimmed sub-group label inside a section (schema list, option groups):
  // regular weight + the section header's color language marks the hierarchy.
  component SubHeader: Text {
    // extraTop: breathing room before option-group headers, so a group
    // doesn't visually flow into the previous group's rows.
    property real extraTop: 0
    textFormat: Text.PlainText
    text: ""
    color: Qt.darker(root.fg, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    topPadding: Math.ceil(Style.font.caption * 0.15) + extraTop
    elide: Text.ElideRight
    width: parent.width
  }

  // Two-state switch row: both states are shown with the active one bold and
  // the other dimmed, so the row reads as a flip rather than a menu entry —
  // row-level checked styling (accent fill) would read as a selection list.
  component ToggleRow: CursorSurface {
    id: trow
    width: parent.width
    required property int flatIndex
    property string offText: ""
    property string onText: ""
    property bool on: false
    signal activate()

    hasCursor: root.cursorActive && root.cursorIndex === trow.flatIndex
    current: false
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: trowInner.implicitHeight + Style.spacing.xl

    Row {
      id: trowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: trow.offText
        opacity: trow.on ? 0.55 : 1
        color: root.fg
        font.family: root.cjkFamily
        font.pixelSize: Style.font.body
        font.bold: !trow.on
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "⇄"
        opacity: 0.55
        color: root.fg
        font.family: root.cjkFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: trow.onText
        opacity: trow.on ? 1 : 0.55
        color: root.fg
        font.family: root.cjkFamily
        font.pixelSize: Style.font.body
        font.bold: trow.on
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorIndex = trow.flatIndex
      }
      onClicked: trow.activate()
    }
  }
}
