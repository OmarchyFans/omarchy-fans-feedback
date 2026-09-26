import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The Feedback issue list as a normal window: it stays open while you work, sits on its
// workspace, and tiles with the other windows (a toplevel, not an overlay; Hyprland tiles it
// unless a window rule floats class org.quickshell, title "Feedback").
//
// Host contract (kind "panel", loaded when summoned): the shell injects `shell` and `manifest`,
// calls open()/close() and reads `opened`; closing the window asks the shell to hide us, which
// unloads the plugin's panel. Open it with the popup's "Pop out" button or
// `omarchy-feedback window`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "fans.omarchy.feedback"
  readonly property string cli: Qt.resolvedUrl("bin/omarchy-feedback").toString().replace(/^file:\/\//, "")
  readonly property bool opened: window.visible
  property bool closingFromHost: false

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text

  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
  }
  function close() { closingFromHost = true; window.visible = false; closingFromHost = false }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else window.visible = false
  }

  // A report taken from here would only show this window: hide it (the shell unloads us), and
  // the CLI brings the window back once the report is saved or discarded (--source window).
  function capture(source) {
    Util.execArgv([root.cli, "capture", "--source", "window"])
    root.requestClose()
  }

  FloatingWindow {
    id: window
    visible: false
    title: "Feedback"
    color: root.background
    implicitWidth: 760
    implicitHeight: 860
    minimumSize: Qt.size(480, 420)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    Flickable {
      id: flick
      anchors.fill: parent
      anchors.margins: Style.space(18)
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
        fontFamily: Style.font.family
        active: window.visible
        canPopOut: false
        // Opening the viewer, a terminal or a web page leaves this window where it is.
        onLeaveRequested: {}
        onCaptureRequested: function(source) { root.capture(source) }
      }
    }
  }
}
