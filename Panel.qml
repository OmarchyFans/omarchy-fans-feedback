import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Feedback: a bug chip in the bar and the issue list.
//
//   left click    open the issue list
//   middle click  report an issue right now (screenshot first, then the form)
//
// The chip keeps the recorder daemon alive (`omarchy-feedback daemon ensure`
// on load and every 30 s, detached so plugin reloads do not kill it) and reads
// its status.json for the armed-replay dot and the paused state.
//
// Everything shown comes from the CLI as JSON (list, handoff targets, handoff
// pending); every action is a fixed argv through Util.execArgv, so nothing read
// from disk reaches a shell as code. Hand-offs started here run directly: the
// click is the confirmation. Requests made in the web viewer show up under
// "Waiting for you" and run only after Confirm.
Panel {
  id: root
  moduleName: "fans.omarchy.feedback"
  ipcTarget: "fans.omarchy.feedback"
  manageIpc: false

  readonly property string cli: Qt.resolvedUrl("bin/omarchy-feedback").toString().replace(/^file:\/\//, "")
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-feedback"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var issues: []
  property var targets: null
  property var pending: []
  property string filter: "open"
  property bool loading: false
  property string error: ""
  property var daemon: null
  property double now: Date.now()
  property int deleteId: 0

  // updates: what `update-check` reported for this widget's version (docs/update-alerts.md)
  property string version: ""
  property var updateInfo: null
  readonly property bool updateAvailable: !!updateInfo && updateInfo.update_available === true
                                          && updateInfo.dismissed !== updateInfo.latest
  readonly property bool updateMismatch: !!updateInfo && updateInfo.mismatch === true
  // What the banner is about: the newer version, or "mismatch". Update… and Later
  // hide that key only, so the next version (or a new mismatch) shows again.
  readonly property string updateKey: updateAvailable ? String(updateInfo.latest) : (updateMismatch ? "mismatch" : "")
  property string updateHiddenKey: ""
  readonly property bool updatePending: updateKey !== "" && updateKey !== updateHiddenKey

  readonly property bool recorderUp: daemon !== null && daemon.running === true && now - daemon.heartbeat < 20000
  readonly property bool armed: recorderUp && daemon.replay && daemon.replay.armed === true
  readonly property bool logPaused: recorderUp && daemon.paused === true
  readonly property int newCount: issues.filter(function(i) { return i.status === "new" }).length

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { load(); checkUpdates() }
  Component.onCompleted: ensureDaemon()

  // ---- updates ----------------------------------------------------------------
  FileView {
    path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: {
      try { root.version = String(JSON.parse(text()).version || "") } catch (e) { root.version = "" }
      root.checkUpdates()
    }
  }
  function checkUpdates() {
    if (root.setting("update_check", true) === false || updateProc.running) return
    updateProc.command = [root.cli, "update-check", root.version]
    updateProc.running = true
  }
  Process {
    id: updateProc
    stdout: StdioCollector { id: updateOut; waitForEnd: true }
    stderr: StdioCollector { id: updateErr; waitForEnd: true }
    onExited: function(code) {
      var d = null
      try { d = JSON.parse(updateOut.text) } catch (e) { d = null }
      if (d) { root.updateInfo = d; return }
      // A helper older than this widget does not know update-check and says so.
      // Any other failure (a tool missing, a file mid-update) leaves things as they were.
      if (code !== 0 && String(updateErr.text || "").indexOf("unknown command") >= 0)
        root.updateInfo = { mismatch: true, update_available: false, latest: null, notes: [], dismissed: "", cli: "older" }
    }
  }
  Timer { interval: 6 * 3600 * 1000; running: true; repeat: true; onTriggered: root.checkUpdates() }
  function runUpdate() {
    root.updateHiddenKey = root.updateKey
    Util.execArgv([root.cli, "update-run", root.updateAvailable ? "all" : "install"])
  }
  function dismissUpdate() {
    root.updateHiddenKey = root.updateKey
    if (root.updateAvailable && root.updateInfo.latest) Util.execArgv([root.cli, "update-dismiss", String(root.updateInfo.latest)])
  }

  // ---- recorder -------------------------------------------------------------
  function ensureDaemon() { Util.execArgv([root.cli, "daemon", "ensure"]) }
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.ensureDaemon() }
  Timer { interval: 1000; running: root.opened || root.armed; repeat: true; onTriggered: root.now = Date.now() }

  FileView {
    id: statusFile
    path: root.runtimeDir + "/status.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.daemon = JSON.parse(text()); root.now = Date.now() } catch (e) { root.daemon = null }
    }
    onLoadFailed: function(err) { root.daemon = null }
  }
  // The daemon replaces status.json atomically (rename), which a file watch can
  // miss; re-read it every few seconds as well.
  Timer { interval: 5000; running: true; repeat: true; onTriggered: statusFile.reload() }

  // ---- data -------------------------------------------------------------------
  function load() {
    loading = true
    if (!listProc.running) {
      listProc.command = [root.cli, "list", "--json", "--status", root.filter]
      listProc.running = true
    }
    if (!targetsProc.running) targetsProc.running = true
    if (!pendingProc.running) pendingProc.running = true
  }
  Process {
    id: listProc
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) { root.error = listErr.text.trim() || ("list exited " + code); return }
      try { root.issues = JSON.parse(listOut.text); root.error = "" } catch (e) { root.error = "bad JSON from list" }
    }
  }
  Process {
    id: targetsProc
    command: [root.cli, "handoff", "targets", "--json"]
    stdout: StdioCollector { id: targetsOut; waitForEnd: true }
    onExited: function(code) { try { root.targets = JSON.parse(targetsOut.text) } catch (e) { root.targets = null } }
  }
  Process {
    id: pendingProc
    command: [root.cli, "handoff", "pending", "--json"]
    stdout: StdioCollector { id: pendingOut; waitForEnd: true }
    onExited: function(code) { try { root.pending = JSON.parse(pendingOut.text) } catch (e) { root.pending = [] } }
  }
  Timer { interval: 10000; running: root.opened; repeat: true; onTriggered: root.load() }
  Timer { id: reloadSoon; interval: 1200; onTriggered: root.load() }

  function act(argv) { Util.execArgv(argv); reloadSoon.restart() }
  function capture(source) {
    if (root.opened) root.close()
    Util.execArgv([root.cli, "capture", "--source", source])
  }
  function available(target) {
    return root.targets && root.targets[target] && root.targets[target].available === true
  }
  function reason(target) {
    return root.targets && root.targets[target] ? (root.targets[target].reason || "") : "checking…"
  }
  function ago(ms) {
    var s = Math.max(0, Math.floor((root.now - ms) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }
  function statusColor(st) {
    if (st === "new") return Color.accent
    if (st === "fixed" || st === "closed") return root.dim
    return root.foreground
  }
  function subjectText(i) {
    var kind = i.subject_type === "plugin" ? "Plugin" : (i.subject_type === "app" ? "App" : (i.subject_type === "omarchy" ? "Omarchy" : "Not sure"))
    var name = i.subject_name || i.subject_id || ""
    return kind + (name ? ": " + name : "") + (i.subject_version ? " " + i.subject_version : "")
  }
  function armedFor() {
    if (!root.armed) return ""
    var s = Math.max(0, Math.floor((root.now - root.daemon.replay.armedAt) / 1000))
    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
  }

  // ---- chip -------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃤"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: (!root.recorderUp ? "Feedback · recorder starting…"
      : (root.armed ? "Feedback · screen replay armed" : (root.logPaused ? "Feedback · event log paused" : "Feedback"))
      + " — middle-click to report")
      + (root.updateAvailable ? " · " + root.updateInfo.latest + " is available" : (root.updateMismatch ? " · finish updating" : ""))
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.capture("chip")
      else root.toggle()
    }
  }
  Rectangle {
    visible: root.armed
    width: Style.space(6); height: width; radius: width / 2
    color: Color.urgent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }
  Rectangle {
    visible: !root.armed && (root.newCount > 0 || root.updatePending)
    width: Style.space(6); height: width; radius: width / 2
    color: Color.accent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }

  // ---- panel ------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

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
            title: "Feedback"
            meta: !root.recorderUp ? "Recorder not running (it starts with the bar; check ~/.local/state and $XDG_RUNTIME_DIR/omarchy-feedback/daemon.log)"
              : (root.logPaused ? "Event log paused"
                 : ("Recording window focus and shortcuts, never typed text" + (root.daemon.locked ? " · paused while locked" : "")))
                + (root.armed ? " · screen replay armed on " + root.daemon.replay.monitor + " for " + root.armedFor() : "")
          }

          // ---- update banner (docs/update-alerts.md) ----
          Rectangle {
            id: updateBanner
            width: parent.width
            visible: root.updatePending
            height: visible ? updateRow.implicitHeight + Style.space(14) : 0
            radius: Style.space(6)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
            border.width: 1
            border.color: Color.accent
            Row {
              id: updateRow
              width: parent.width - Style.space(14)
              anchors.centerIn: parent
              spacing: Style.space(8)
              Column {
                id: updateCol
                width: parent.width - updateButtons.width - parent.spacing
                spacing: Style.space(2)
                Text {
                  width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                  text: root.updateAvailable
                        ? "Feedback " + root.updateInfo.latest + " is available (you have " + root.version + ")"
                        : "Finish updating Feedback: the widget is " + root.version + ", its helper is " + (root.updateInfo ? root.updateInfo.cli : "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                }
                Repeater {
                  model: root.updateAvailable ? root.updateInfo.notes.slice(0, 4) : []
                  delegate: Text {
                    required property var modelData
                    width: updateCol.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: "•  " + modelData
                    color: root.foreground; opacity: 0.8; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                  text: root.updateAvailable
                        ? "Update opens a terminal: omarchy plugin update shows the changes and asks, then install.sh asks, then the recorder restarts."
                        : "Run install.sh once so the helper matches. It asks before changing anything."
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
              }
              Column {
                id: updateButtons
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                Button {
                  text: root.updateAvailable ? "Update…" : "Finish update…"; foreground: Color.accent; fontFamily: root.fontFamily
                  onClicked: root.runUpdate()
                }
                Button { text: "Later"; foreground: root.dim; fontFamily: root.fontFamily; onClicked: root.dismissUpdate() }
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: "Report an issue"; iconText: "󰃤"; foreground: Color.accent; fontFamily: root.fontFamily
              tooltipText: "Screenshot, markup and the last 10 minutes of events (SUPER + ALT + B)"
              onClicked: root.capture("panel")
            }
            Button {
              text: root.armed ? "Stop replay" : "Arm screen replay"; iconText: root.armed ? "󰙧" : "󰑊"
              foreground: root.armed ? Color.urgent : root.foreground; fontFamily: root.fontFamily
              tooltipText: root.armed ? "Stop keeping the last 2 minutes of the screen in memory"
                : "Keep the last 2 minutes of this monitor in memory so a report can show what led up to it (off after 30 min)"
              onClicked: root.act(root.armed ? [root.cli, "disarm"] : [root.cli, "arm"])
            }
            Button {
              text: root.logPaused ? "Resume event log" : "Pause event log"; iconText: root.logPaused ? "󰐊" : "󰏤"
              foreground: root.dim; fontFamily: root.fontFamily
              onClicked: root.act(root.logPaused ? [root.cli, "resume"] : [root.cli, "pause"])
            }
            Button {
              text: "Viewer"; iconText: "󰖟"; foreground: root.foreground; fontFamily: root.fontFamily
              tooltipText: "Replays, markup and PDF / Markdown export in the local web viewer"
              onClicked: { root.close(); Util.execArgv([root.cli, "open"]) }
            }
          }

          // Requests made in the web viewer wait here (and in a notification).
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.pending.length > 0
            PanelSeparator { width: parent.width }
            PanelSectionHeader { width: parent.width; text: "Waiting for you" }
            Repeater {
              model: root.pending
              delegate: Row {
                required property var modelData
                spacing: Style.space(6)
                Text {
                  width: column.width - confirmBtn.width - declineBtn.width - Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  text: "Send #" + modelData.issue_id + " to " + (modelData.target === "rix" ? "Rix" : (modelData.target === "agent" ? "your coding agent" : "the author")) + ": " + modelData.title
                }
                Button { id: confirmBtn; text: "Confirm"; foreground: Color.accent; fontFamily: root.fontFamily
                         onClicked: root.act([root.cli, "handoff", "confirm", String(modelData.id)]) }
                Button { id: declineBtn; text: "Decline"; foreground: root.dim; fontFamily: root.fontFamily
                         onClicked: root.act([root.cli, "handoff", "decline", String(modelData.id)]) }
              }
            }
          }

          PanelSeparator { width: parent.width }
          Row {
            spacing: Style.space(6)
            PanelSectionHeader { anchors.verticalCenter: parent.verticalCenter; text: root.filter === "open" ? "Open issues" : "All issues" }
            Button {
              text: root.filter === "open" ? "Show all" : "Open only"; foreground: root.dim; fontFamily: root.fontFamily
              onClicked: { root.filter = root.filter === "open" ? "all" : "open"; root.load() }
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            visible: root.error !== "" || (!root.loading && root.issues.length === 0)
            color: root.error !== "" ? Color.urgent : root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.error !== "" ? root.error : "Nothing here. Press SUPER + ALT + B (or middle-click the bug) when something goes wrong or you have an idea."
          }

          Repeater {
            model: root.issues
            delegate: Column {
              id: row
              required property var modelData
              width: column.width
              spacing: Style.space(3)

              Row {
                width: parent.width
                spacing: Style.space(6)
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: pill.implicitWidth + Style.space(10); height: pill.implicitHeight + Style.space(2)
                  radius: height / 2
                  color: "transparent"
                  border.width: 1; border.color: root.statusColor(row.modelData.status)
                  Text {
                    id: pill; anchors.centerIn: parent; textFormat: Text.PlainText
                    color: root.statusColor(row.modelData.status); font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    text: row.modelData.status
                  }
                }
                Text {
                  width: parent.width - x - ageText.width - Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                  text: "#" + row.modelData.id + "  " + (row.modelData.kind === "feature" ? "✦ " : "") + row.modelData.title
                }
                Text {
                  id: ageText
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  text: root.ago(row.modelData.created_at)
                }
              }
              Text {
                width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: root.subjectText(row.modelData)
                  + (row.modelData.attachment_kinds.indexOf("replay") >= 0 ? " · replay" : "")
                  + " · " + row.modelData.event_count + " events"
                  + (row.modelData.pending_handoffs > 0 ? " · waiting for you" : "")
              }
              Text {
                visible: row.modelData.secrets_open > 0
                width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                text: "󰌾 " + (row.modelData.secrets_open === 1 ? "A possible secret was" : row.modelData.secrets_open + " possible secrets were")
                  + " captured and masked. It may be compromised: rotate it as soon as possible. Open for details."
              }
              Flow {
                width: parent.width
                spacing: Style.space(4)
                Button {
                  text: "Open"; iconText: "󰖟"; foreground: root.foreground; fontFamily: root.fontFamily
                  tooltipText: "Replay, timeline, markup and export in the viewer"
                  onClicked: { root.close(); Util.execArgv([root.cli, "open", String(row.modelData.id)]) }
                }
                Button {
                  text: "Rix"; iconText: "󱚝"; fontFamily: root.fontFamily
                  foreground: root.available("rix") ? root.foreground : root.dim
                  tooltipText: root.available("rix") ? "Rix triages it as a worker job in Agent Launcher" : root.reason("rix")
                  onClicked: if (root.available("rix")) root.act([root.cli, "handoff", "rix", String(row.modelData.id)])
                }
                Button {
                  text: root.targets && root.targets.agent && root.targets.agent.name ? root.targets.agent.name : "Coding agent"
                  iconText: "󰘦"; fontFamily: root.fontFamily
                  foreground: root.available("agent") ? root.foreground : root.dim
                  tooltipText: root.available("agent") ? "Open your coding agent in the project folder with this issue" : root.reason("agent")
                  onClicked: if (root.available("agent")) { root.close(); root.act([root.cli, "handoff", "agent", String(row.modelData.id)]) }
                }
                Button {
                  readonly property bool ok: row.modelData.repo_url && !(row.modelData.secrets_open > 0)
                  text: "Author"; iconText: "󰊤"; fontFamily: root.fontFamily
                  foreground: ok ? root.foreground : root.dim
                  tooltipText: row.modelData.secrets_open > 0 ? "Rotate the captured secret and mark it rotated before sending this anywhere public"
                    : (row.modelData.repo_url ? "Open a prefilled issue at " + row.modelData.repo_url + " (you review and submit)" : "No project link for this subject")
                  onClicked: if (ok) { root.close(); root.act([root.cli, "handoff", "author", String(row.modelData.id)]) }
                }
                Button {
                  visible: row.modelData.secrets_open > 0
                  text: "Rotated"; iconText: "󰌾"; foreground: Color.urgent; fontFamily: root.fontFamily
                  tooltipText: "I have rotated (changed or revoked) the captured secrets"
                  onClicked: root.act([root.cli, "secrets", "rotated", String(row.modelData.id)])
                }
                Button {
                  visible: row.modelData.secrets_open > 0 && row.modelData.attachment_kinds.indexOf("replay") >= 0
                  text: "Delete replay"; iconText: "󰕧"; foreground: Color.urgent; fontFamily: root.fontFamily
                  tooltipText: "A secret cannot be cut out of the video: delete the screen replay of this issue"
                  onClicked: root.act([root.cli, "delete-replay", String(row.modelData.id)])
                }
                Button {
                  visible: row.modelData.status !== "fixed" && row.modelData.status !== "closed"
                  text: "Fixed"; iconText: "󰄬"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "set", String(row.modelData.id), "status", "fixed"])
                }
                Button {
                  visible: row.modelData.status !== "closed"
                  text: "Close"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "set", String(row.modelData.id), "status", "closed"])
                }
                Button {
                  visible: row.modelData.status === "fixed" || row.modelData.status === "closed"
                  text: "Reopen"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: root.act([root.cli, "set", String(row.modelData.id), "status", "triaged"])
                }
                Button {
                  text: ""; iconText: "󰆴"; tooltipText: "Delete this issue and its files"; foreground: root.dim; fontFamily: root.fontFamily
                  onClicked: { root.deleteId = row.modelData.id; deleteDialog.opened = true }
                }
              }
              PanelSeparator { width: parent.width; strength: 0.06 }
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: deleteDialog
      anchors.fill: parent
      z: 10
      message: "Delete issue #" + root.deleteId + " with its screenshots, replay and event log?"
      cancelText: "Keep"
      confirmText: "Delete"
      onConfirmed: { opened = false; root.act([root.cli, "delete", String(root.deleteId)]) }
      onCanceled: opened = false
    }
  }
}
