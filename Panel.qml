import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Beta Feedback: a bug chip in the bar and a panel listing the plugins you are
// beta-testing, the reports you filed and where they stand, and one-click
// "Update now" / "Back to stable" / "It works" actions when a fix lands.
//
// Everything comes from `omarchy-beta-feedback info` (JSON); every action is a
// fixed argv passed to the CLI (nothing parsed from disk reaches a shell as
// code). An hourly timer runs `poll`, which is what fires the "fix ready to
// test" notification — so no systemd unit is needed.
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) load()
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃤"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.updates > 0 ? (root.updates + " beta update(s) ready") : "Beta feedback"
    onPressed: root.toggle()
  }
  Rectangle {
    visible: root.updates > 0
    width: Style.space(6); height: width; radius: width / 2
    color: Color.accent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
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
                  : (!root.info || root.info.plugins.length === 0 ? "You are not beta-testing any plugin yet. Enrolled plugins ask you from their own panel."
                  : root.info.enrolled + " enrolled · " + root.updates + " update(s) ready"))
          }

          Repeater {
            model: root.info ? root.info.plugins : []
            delegate: Column {
              required property var modelData
              width: column.width
              spacing: Style.space(4)

              PanelSectionHeader { width: parent.width; title: modelData.plugin }
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
}
