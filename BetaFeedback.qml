import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// BetaFeedback — vendored by `omarchy-beta-feedback author init`.
//
// Drop it in as a DIRECT CHILD of your KeyboardPanel (a sibling of
// PanelKeyCatcher), e.g.
//
//   KeyboardPanel {
//     id: panel
//     ...
//     BetaFeedback { pluginId: root.moduleName; opened: panel.open }
//   }
//
// It renders nothing unless the user has the Beta Feedback plugin
// (fans.omarchy.beta-feedback) installed. When they do, it asks once whether
// they want to join your beta program, and while they are enrolled it shows a
// small bug button in the corner of your panel. Pressing it grabs an image of
// THIS panel only (never the desktop), remembers the last 10 mouse presses
// inside the panel (never key presses or text), and hands both to the CLI,
// which opens the annotate-and-submit flow in a floating terminal.
//
// Optional: forward key events so the opt-in dialog can be answered from the
// keyboard: in your PanelKeyCatcher, `if (betaFeedback.handleKey(event)) return`.
Item {
  id: root

  property string pluginId: ""
  property bool opened: false
  property Item target: parent           // KeyboardPanel's contentHolder; its parent is the card
  property string cornerGlyph: "󰃤"

  z: 100000
  anchors.fill: parent
  visible: status !== null && status.status === "enrolled"

  readonly property string home: Quickshell.env("HOME")
  readonly property string cli: home + "/.config/omarchy/plugins/fans.omarchy.beta-feedback/bin/omarchy-beta-feedback"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy-beta-feedback"
  readonly property string sourceDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string branch: String(head.text()).replace(/^ref: refs\/heads\//, "").trim()

  property var status: null              // null = feedback plugin not installed
  property var presses: []
  property bool askedThisSession: false

  onOpenedChanged: if (opened) probe.running = true
  Component.onCompleted: if (opened) probe.running = true

  FileView { id: head; path: root.sourceDir + "/.git/HEAD"; onLoadFailed: function(e) {} }

  // exit 127 = CLI not installed → stay invisible.
  Process {
    id: probe
    command: ["bash", "-c", 'test -x "$0" && exec "$0" "$@"; exit 127', root.cli, "status", root.pluginId]
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { root.status = null; return }
      try { root.status = JSON.parse(probeOut.text) } catch (e) { root.status = null; return }
      if (root.status.status === "unknown" && root.status.hasRepo && !root.askedThisSession) {
        root.askedThisSession = true
        consent.opened = true
      }
    }
  }

  Process {
    id: answer
    property var argv: []
    command: argv
    onExited: function() { probe.running = true }
  }
  function enroll(yes) {
    answer.argv = yes ? [root.cli, "enroll", root.pluginId] : [root.cli, "unenroll", root.pluginId, "--declined"]
    answer.running = true
  }

  function describe(item, x, y) {
    var path = []
    var depth = 0
    while (item && depth < 12) {
      if (item !== root) {
        var n = String(item).replace(/_QMLTYPE_\d+/, "").replace(/\(0x[0-9a-f]+\)$/, "").replace(/QQuick/, "")
        if (item.objectName) n += "#" + item.objectName
        if ("text" in item && item.text) n += "[" + String(item.text).slice(0, 24) + "]"
        else if ("iconText" in item && item.iconText) n += "[" + item.iconText + "]"
        path.push(n)
      }
      var next = item.childAt(x, y)
      if (!next || next === root) break
      var p = item.mapToItem(next, x, y); x = p.x; y = p.y; item = next; depth++
    }
    return path.join(" > ")
  }

  // Transparent press logger: hoverEnabled stays false (it would steal hover
  // from every button underneath) and there is no onWheel.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    enabled: root.visible
    onPressed: function(m) {
      var p = mapToItem(root.target, m.x, m.y)
      root.presses = root.presses.concat([{ t: Date.now(), b: m.button, at: root.describe(root.target, p.x, p.y) }]).slice(-10)
      m.accepted = false
    }
  }

  Button {
    id: bug
    anchors { right: parent.right; bottom: parent.bottom }
    iconText: root.cornerGlyph
    text: ""
    tooltipText: "Report a bug or request a feature (beta program)"
    onClicked: root.report()
  }

  function report() {
    var shot = root.stateDir + "/shots/" + root.pluginId + "-" + Date.now() + ".png"
    var trace = JSON.stringify(root.presses)
    bug.visible = false
    var card = root.target && root.target.parent ? root.target.parent : root.target
    var started = card.grabToImage(function(result) {
      bug.visible = true
      var ok = false
      try { ok = result.saveToFile(shot) } catch (e) { ok = false }
      Util.execArgv([root.cli, "report", "--plugin", root.pluginId, "--branch", root.branch,
                     "--shot", ok ? shot : "", "--context", trace])
    })
    if (!started) {
      bug.visible = true
      Util.execArgv([root.cli, "report", "--plugin", root.pluginId, "--branch", root.branch, "--shot", "", "--context", trace])
    }
  }

  ConfirmDialog {
    id: consent
    anchors.fill: parent
    z: 10
    visible: opened
    message: "Join the beta program for this plugin?\n\nWhile enrolled you get a bug button here. A report sends the author: a picture of THIS panel (which you can edit first), the last 10 clicks inside it, plugin and Omarchy versions, and a shell log excerpt. Never key presses, never other windows. Enrollment ends after " + (root.status ? root.status.betaDays : 5) + " days of use; opt out any time from the Beta Feedback bar chip."
    cancelText: "No thanks"
    confirmText: "Join"
    onConfirmed: { opened = false; root.enroll(true) }
    onCanceled: { opened = false; root.enroll(false) }
  }
  function handleKey(e) { return consent.handleKey(e) }
}
