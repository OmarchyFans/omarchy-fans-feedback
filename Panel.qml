import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Beta Feedback: a bug chip in the bar and a panel with the troubleshooting
// recording, the plugins you are beta-testing, the betas you can join, the
// reports you filed and where they stand, and one-click "Update now" /
// "Back to stable" / "It works" actions when a fix lands.
//
// Everything comes from `omarchy-beta-feedback info` (JSON); every action is a
// fixed argv passed to the CLI (nothing parsed from disk reaches a shell as
// code). An hourly timer runs `poll`, which is what fires the "fix ready to
// test" notification — so no systemd unit is needed.
//
// While a troubleshooting recording runs, lib/keylog.py keeps overlay.json in
// XDG_RUNTIME_DIR current. This widget reads it to turn the chip red and, on
// the recorded monitor only, to draw the last key combinations at the bottom
// of the screen so they end up in the video.
Panel {
  id: root
  moduleName: "fans.omarchy.beta-feedback"
  ipcTarget: "fans.omarchy.beta-feedback"
  manageIpc: false

  readonly property string cli: Qt.resolvedUrl("bin/omarchy-beta-feedback").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var info: null
  property bool loading: false
  property string error: ""
  readonly property int updates: info && info.updates ? info.updates.length : 0

  // ---- troubleshooting recording state (from overlay.json)
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-beta-feedback"
  property var overlay: null
  property double now: Date.now()
  readonly property bool recording: overlay !== null && overlay.recording === true && now - overlay.heartbeat < 5000
  readonly property var recentKeys: recording && overlay.items
    ? overlay.items.filter(function(i) { return root.now - i.at < 2500 }).slice(-5) : []
  readonly property var hostScreen: button.QsWindow.window ? button.QsWindow.window.screen : null
  readonly property bool overlayHere: recording && overlay.showKeys === true
    && (!overlay.monitor || (hostScreen !== null && hostScreen.name === overlay.monitor))
  property bool showKeysOnScreen: true
  property bool includeAllKeys: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) load()
  onRecordingChanged: if (opened) load()
  Component.onCompleted: pollProc.running = true

  function load() {
    if (infoProc.running) return
    loading = true
    infoProc.command = [root.cli, "info"]
    infoProc.running = true
  }
  Process {
    id: infoProc
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    stderr: StdioCollector { id: infoErr; waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) { root.error = infoErr.text.trim() || ("info exited " + code); return }
      try { root.info = JSON.parse(infoOut.text); root.error = "" } catch (e) { root.error = "bad JSON from info" }
    }
  }
  Process {
    id: pollProc
    command: [root.cli, "poll"]
    onExited: function() { if (root.opened) root.load() }
  }
  Timer { interval: 60 * 60 * 1000; running: true; repeat: true; onTriggered: pollProc.running = true }

  // Fixed-argv actions. Channel switches run detached: the resulting checkout
  // makes the shell reload plugins, which would kill an attached Process.
  function act(argv) { Util.execArgv(argv); reload.restart() }
  Timer { id: reload; interval: 1500; onTriggered: root.load() }

  FileView {
    id: overlayFile
    path: root.runtimeDir + "/overlay.json"
    printErrors: false
    onLoaded: { try { root.overlay = JSON.parse(text()) } catch (e) { root.overlay = null } }
    onLoadFailed: function(error) { root.overlay = null }
  }
  // 10 Hz while recording (the key display), once a second otherwise, so a
  // recording started from the CLI still turns the chip red.
  Timer {
    interval: root.recording ? 100 : 1000
    running: true
    repeat: true
    onTriggered: { root.now = Date.now(); overlayFile.reload() }
  }

  function elapsed() {
    if (!recording) return ""
    var s = Math.max(0, Math.floor((now - overlay.startedAt) / 1000))
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
  }
  // The panel closes first so it is not in the first frames of the video.
  function startRecording() {
    var argv = [root.cli, "record", "start"]
    if (root.includeAllKeys) argv.push("--all-keys")
    if (!root.showKeysOnScreen) argv.push("--no-overlay")
    startLater.argv = argv
    root.close()
    startLater.restart()
  }
  Timer { id: startLater; interval: 400; property var argv: []; onTriggered: Util.execArgv(argv) }
  function stopRecording(report) {
    root.close()
    Util.execArgv(report ? [root.cli, "record", "stop"] : [root.cli, "record", "stop", "--no-report"])
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃤"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.recording ? ("Troubleshooting recording " + root.elapsed() + ": click to stop")
               : root.updates > 0 ? (root.updates + " beta update(s) ready") : "Beta feedback"
    onPressed: root.toggle()
  }
  Rectangle {
    visible: root.updates > 0 && !root.recording
    width: Style.space(6); height: width; radius: width / 2
    color: Color.accent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }
  Rectangle {
    visible: root.recording
    width: Style.space(7); height: width; radius: width / 2
    color: Color.urgent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
    SequentialAnimation on opacity {
      running: root.recording
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 700 }
      NumberAnimation { to: 1; duration: 700 }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: "Beta feedback"
            meta: root.loading ? "Reading…" : (root.error ? root.error
                  : (!root.info || root.info.plugins.length === 0 ? "You are not beta-testing any plugin yet. Join one below, or record a bug in the desktop itself."
                  : root.info.enrolled + " enrolled · " + root.updates + " update(s) ready"))
          }

          // ---- troubleshooting recording
          PanelSectionHeader { width: parent.width; text: "Troubleshooting recording" }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            color: root.recording ? Color.urgent : root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.recording
              ? ("Recording " + root.elapsed()
                 + (root.overlay.paused ? " · key log paused while the screen is locked" : "")
                 + (root.overlay.allKeys ? " · every key is logged" : " · letters and digits hidden"))
              : "Records the focused screen together with your key presses and window, workspace and keyboard-layout events, so a shortcut that does nothing can be seen exactly. It stays on this machine until you choose to send it, pauses while the screen is locked, and stops by itself after 20 minutes."
          }
          Toggle {
            visible: !root.recording
            width: parent.width
            label: "Show keys on screen"
            description: "Draws each key combination at the bottom of the recorded screen, so the video shows it."
            checked: root.showKeysOnScreen
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showKeysOnScreen = !root.showKeysOnScreen
          }
          Toggle {
            visible: !root.recording
            width: parent.width
            label: "Include letters and digits"
            description: "Off: typed text is logged as •, while shortcuts with Ctrl, Alt or Super stay readable. Turn it on only when the bug is about typing, and do not type passwords while recording."
            checked: root.includeAllKeys
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.includeAllKeys = !root.includeAllKeys
          }
          Row {
            spacing: Style.space(6)
            Button {
              visible: !root.recording
              text: "Record focused screen"; iconText: "󰑊"; foreground: Color.urgent; fontFamily: root.fontFamily
              onClicked: root.startRecording()
            }
            Button {
              visible: root.recording
              text: "Stop and report"; iconText: "󰓛"; foreground: Color.urgent; fontFamily: root.fontFamily
              onClicked: root.stopRecording(true)
            }
            Button {
              visible: root.recording
              text: "Stop and save only"; foreground: root.dim; fontFamily: root.fontFamily
              onClicked: root.stopRecording(false)
            }
          }

          // ---- plugins you are (or were) testing
          Repeater {
            model: root.info ? root.info.plugins : []
            delegate: Column {
              required property var modelData
              width: column.width
              spacing: Style.space(4)

              PanelSectionHeader { width: parent.width; text: modelData.plugin }
              Text {
                width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: (modelData.status === "enrolled"
                        ? "Enrolled · day " + modelData.daysUsed + " of " + modelData.betaDays
                        : modelData.status)
                      + " · " + modelData.channel + " channel (" + modelData.branch + " @ " + modelData.sha + ")"
                      + (modelData.updateAvailable ? "\nA fix is ready on the beta channel (" + modelData.updateSha + ")." : "")
              }
              Row {
                spacing: Style.space(6)
                Button {
                  visible: modelData.updateAvailable
                  text: "Update now"; iconText: "󰚰"; foreground: Color.accent; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "update", modelData.plugin, "--channel", "beta"])
                }
                Button {
                  visible: modelData.channel === "beta"
                  text: "Back to stable"; iconText: "󰜉"; foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "update", modelData.plugin, "--channel", "stable"])
                }
                Button {
                  visible: modelData.status === "enrolled"
                  text: "Leave beta"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "unenroll", modelData.plugin])
                }
                Button {
                  visible: modelData.status !== "enrolled" && modelData.hasRepo
                  text: "Re-enroll"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "enroll", modelData.plugin])
                }
              }
              Repeater {
                model: modelData.reports
                delegate: Row {
                  required property var modelData
                  spacing: Style.space(6)
                  width: column.width
                  Text {
                    width: parent.width - actions.width - Style.space(6)
                    wrapMode: Text.WordWrap; textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 2
                    color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    text: (modelData.issue ? "#" + modelData.issue + " " : "") + modelData.title
                          + "  ·  " + modelData.status + (modelData.confirmed ? " · you said: " + modelData.confirmed : "")
                  }
                  Row {
                    id: actions
                    spacing: Style.space(4)
                    Button {
                      visible: !!modelData.url
                      iconText: "󰖟"; text: ""; tooltipText: "Open the issue"; foreground: root.dim; fontFamily: root.fontFamily
                      onClicked: Util.execArgv(["xdg-open", modelData.url])
                    }
                    Button {
                      visible: modelData.status === "fixed-in-beta" && modelData.issue && !modelData.confirmed
                      text: "It works"; iconText: "󰄬"; foreground: Color.accent; fontFamily: root.fontFamily
                      onClicked: root.act([root.cli, "confirm", modelData.plugin, String(modelData.issue), "--works"])
                    }
                    Button {
                      visible: modelData.status === "fixed-in-beta" && modelData.issue && !modelData.confirmed
                      text: "Still broken"; iconText: "󰅖"; foreground: Color.urgent; fontFamily: root.fontFamily
                      onClicked: root.act([root.cli, "confirm", modelData.plugin, String(modelData.issue), "--broken"])
                    }
                  }
                }
              }
            }
          }

          // ---- betas you can join (or, as the author, set up)
          PanelSectionHeader {
            visible: root.info !== null && (root.info.available || []).length > 0
            width: parent.width
            text: "Beta programs"
          }
          Repeater {
            model: root.info && root.info.available ? root.info.available : []
            delegate: Row {
              required property var modelData
              width: column.width
              spacing: Style.space(6)
              Text {
                width: parent.width - joinActions.width - Style.space(6)
                wrapMode: Text.WordWrap; textFormat: Text.PlainText
                color: modelData.beta ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: modelData.name + " · "
                      + (modelData.beta ? "beta open; reports go to github.com/" + modelData.repo
                         : modelData.source !== "" ? "no beta yet; its source is on this machine, so you can set one up"
                         : "no beta program (its author has not set one up)")
              }
              Row {
                id: joinActions
                spacing: Style.space(4)
                Button {
                  visible: modelData.beta
                  text: modelData.status === "unknown" ? "Join beta" : "Re-join"
                  iconText: "󰃤"; foreground: Color.accent; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "enroll", modelData.plugin])
                }
                Button {
                  visible: !modelData.beta && modelData.source !== ""
                  text: "Set up beta…"; foreground: root.dim; fontFamily: root.fontFamily
                  tooltipText: "Opens a terminal running `author init` on " + modelData.source
                  onClicked: {
                    root.close()
                    Util.execArgv(["omarchy-launch-tui", "--app-id=TUI.float", root.cli, "author", "init", modelData.source])
                  }
                }
              }
            }
          }

          // ---- reports about the desktop itself
          PanelSectionHeader {
            visible: root.info !== null && (root.info.desktopReports || []).length > 0
            width: parent.width
            text: "Desktop reports"
          }
          Repeater {
            model: root.info && root.info.desktopReports ? root.info.desktopReports.slice(0, 5) : []
            delegate: Row {
              required property var modelData
              width: column.width
              spacing: Style.space(6)
              Text {
                width: parent.width - openIssue.width - Style.space(6)
                wrapMode: Text.WordWrap; textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 2
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: (modelData.issue ? "#" + modelData.issue + " " : "") + modelData.title + "  ·  " + modelData.status
              }
              Button {
                id: openIssue
                visible: !!modelData.url
                iconText: "󰖟"; text: ""; tooltipText: "Open the issue"; foreground: root.dim; fontFamily: root.fontFamily
                onClicked: Util.execArgv(["xdg-open", modelData.url])
              }
            }
          }

          PanelSeparator { width: parent.width }
          Row {
            spacing: Style.space(6)
            Button { text: "Check for fixes now"; iconText: "󰑐"; foreground: root.foreground; fontFamily: root.fontFamily; onClicked: pollProc.running = true }
            Button { text: "Author inbox"; iconText: "󰇮"; foreground: root.foreground; fontFamily: root.fontFamily
                     onClicked: Util.execArgv(["omarchy-launch-tui", "--app-id=TUI.float", root.cli, "author", "inbox"]) }
            Button { text: "Reload"; foreground: root.dim; fontFamily: root.fontFamily; onClicked: root.load() }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.info ? "Reporter id " + root.info.reporter + " · v" + root.info.version : ""
          }
        }
      }
    }

    // The SDK exercised on ourselves: it stays invisible unless this clone has
    // a GitHub origin, so it costs nothing but proves the file loads.
    BetaFeedback { pluginId: root.moduleName; opened: panel.open }
  }

  // ---- on-screen keys: one click-through strip on the recorded monitor, drawn
  // by the widget instance whose bar lives there. Visual only: no keyboard
  // focus, empty input region.
  PanelWindow {
    id: keyOverlay
    visible: root.overlayHere
    screen: root.hostScreen
    anchors { left: true; right: true; bottom: true }
    implicitHeight: Style.space(160)
    color: "transparent"
    WlrLayershell.namespace: "fans-omarchy-beta-feedback-keys"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(48)
      spacing: Style.space(8)
      Repeater {
        model: root.recentKeys
        delegate: Rectangle {
          required property var modelData
          required property int index
          radius: Style.cornerRadius
          color: Util.alpha(Color.background, 0.92)
          border.color: index === root.recentKeys.length - 1 ? Color.accent : Util.alpha(Color.foreground, 0.35)
          border.width: Math.max(1, Style.space(2))
          width: keyLabel.implicitWidth + Style.space(28)
          height: keyLabel.implicitHeight + Style.space(14)
          Text {
            id: keyLabel
            anchors.centerIn: parent
            text: modelData.text
            color: Color.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
        }
      }
    }
    Text {
      anchors { left: parent.left; bottom: parent.bottom; leftMargin: Style.space(16); bottomMargin: Style.space(16) }
      text: "󰑊 keys" + (root.overlay && root.overlay.paused ? " paused" : "")
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
