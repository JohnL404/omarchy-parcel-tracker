import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Parcel Tracker bar pill: a box glyph with the count of parcels still
// in play, lighting up when something needs attention. Clicking opens the
// management panel hosted in Panel.qml.
BarWidget {
  id: root
  moduleName: "johnl404.parcel-tracker"

  readonly property string pillGlyph: "󰏓" // nf-md-package (verified via font glyph table)

  // Mirrored out of the panel so the pill paints even while it loads.
  readonly property int pillCount: panelLoader.item ? panelLoader.item.activeCount : 0
  readonly property bool pillUrgent: panelLoader.item ? panelLoader.item.urgent : false
  readonly property bool pillErrored: panelLoader.item ? panelLoader.item.errored : false

  function refresh() {
    if (panelLoader.item && panelLoader.item.refreshAll) panelLoader.item.refreshAll(true)
  }

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "johnl404.parcel-tracker"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.pillUrgent
    text: root.vertical
      ? root.pillGlyph
      : root.pillGlyph + (root.pillCount > 0 ? " " + root.pillCount : "")
    tooltipText: "Parcels — " + root.pillCount + " in transit"

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
