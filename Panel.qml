import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Feedback: a bug chip in the bar and the issue list.
//
//   left click    open the issue list (a popup; "Pop out" moves it into a tiled window)
//   middle click  report an issue right now (screenshot first, then the form)
//
// The chip keeps the recorder daemon alive (`omarchy-feedback daemon ensure` on load and every
// 30 s, detached so plugin reloads do not kill it). The list itself lives in IssueList.qml,
// shared with the window (Window.qml, the plugin's "panel" entry point).
Panel {
  id: root
  moduleName: "fans.omarchy.feedback"
  ipcTarget: "fans.omarchy.feedback"
  manageIpc: false

  readonly property string cli: Qt.resolvedUrl("bin/omarchy-feedback").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function ensureDaemon() { Util.execArgv([root.cli, "daemon", "ensure"]) }
  Component.onCompleted: ensureDaemon()
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.ensureDaemon() }

  function capture(source) {
    root.close()
    Util.execArgv([root.cli, "capture", "--source", source])
  }

  // The window is the plugin's panel: the shell owns it (summon/hide/toggle over IPC).
  function popOut() {
    root.close()
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") root.bar.shell.summon("fans.omarchy.feedback", "{}")
    else Util.execArgv([root.cli, "window"])
  }

  // ---- chip -------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃤"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: (!list.recorderUp ? "Feedback · recorder starting…"
      : (list.armed ? "Feedback · screen replay armed" : (list.logPaused ? "Feedback · event log paused" : "Feedback"))
      + " — middle-click to report")
      + (list.updateAvailable ? " · " + list.updateInfo.latest + " is available" : (list.updateMismatch ? " · finish updating" : ""))
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.capture("chip")
      else root.toggle()
    }
  }
  Rectangle {
    visible: list.armed
    width: Style.space(6); height: width; radius: width / 2
    color: Color.urgent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }
  Rectangle {
    visible: !list.armed && (list.newCount > 0 || list.updatePending)
    width: Style.space(6); height: width; radius: width / 2
    color: Color.accent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }

  // ---- popup --------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(list.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: list.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        IssueList {
          id: list
          width: flick.width
          cli: root.cli
          foreground: root.foreground
          fontFamily: root.fontFamily
          active: root.opened
          canPopOut: true
          updateCheckOff: root.setting("update_check", true) === false
          onLeaveRequested: root.close()
          onPopOutRequested: root.popOut()
          onCaptureRequested: function(source) { root.capture(source) }
        }
      }
    }
  }
}
