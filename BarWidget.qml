import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar host for the notification center: the bell icon, the unread badge and
// the DND state, all fed by the always-loaded Panel (Panel.qml owns the data).
//
// Left click toggles the center; right click toggles Do Not Disturb.
BarWidget {
  id: root
  moduleName: "apach.notifications"

  // Data lives in Store.qml (always loaded, cheap); the panel UI in
  // Panel.qml is instantiated on first use so an unanswered center costs no
  // QML widget tree per screen.
  property bool panelActive: false
  property string pendingAction: ""

  // The merged plugin's service owns the NotificationServer and the live
  // toast model. The scoped bar API exposes our own service directly, so the
  // center does not have to re-read state files for live entries.
  property var service: null

  readonly property var hostWindow: QsWindow.window
  readonly property string hostScreenName: hostWindow && hostWindow.screen
    ? String(hostWindow.screen.name || "") : ""

  readonly property var store: storeLoader.item
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool dnd: store ? store.dnd === true : false
  readonly property int unseen: store ? (store.unseenCount || 0) : 0

  readonly property string bellGlyph: root.dnd ? "󰂜" : "󰂞"

  readonly property string tooltipText: root.dnd
    ? "Notifications — silenced"
    : (root.unseen > 0
      ? root.unseen + " unread notification" + (root.unseen > 1 ? "s" : "")
      : "Notifications")

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity, same contract as omarchy.clock / omarchy.weather.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function siblings() {
    return root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : [root]
  }

  function closeSelf() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function anyOpen() {
    var items = root.siblings()
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i].opened === true) return true
    return false
  }

  // One panel instance hosts every selected screen. Opening from another bar
  // therefore closes the previous host first, so the Repeater never builds a
  // second set of center windows. Closing is broadcast so an IPC call routed
  // to a different bar instance still tears the visible center down.
  function closeAll() {
    var items = root.siblings()
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (item && typeof item.closeSelf === "function") item.closeSelf()
    }
  }

  function open() {
    root.closeAll()
    request("open")
  }

  function close() { root.closeAll() }

  function toggle() {
    if (root.anyOpen()) root.closeAll()
    else root.open()
  }

  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function toggleDnd() {
    if (root.service) {
      root.service.setDoNotDisturb(!root.service.doNotDisturb)
      return
    }
    if (root.store) root.store.toggleDnd()
  }

  // Load the UI on demand, then replay the requested action. Toggling a
  // freshly loaded panel opens it, which is what the caller expects.
  function request(action) {
    if (panelLoader.item) {
      panelLoader.item[action]()
      return
    }
    root.pendingAction = action
    root.panelActive = true
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("store" in target) target.store = root.store
    if ("service" in target) target.service = root.service
    if ("hostScreenName" in target) target.hostScreenName = root.hostScreenName
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function injectService() {
    if (storeLoader.item && "service" in storeLoader.item)
      storeLoader.item.service = root.service
    if (panelLoader.item && "service" in panelLoader.item)
      panelLoader.item.service = root.service
  }

  function resolveService() {
    if (root.service) return
    var api = root.bar ? root.bar.shell : null
    var target = api && typeof api.serviceFor === "function"
      ? api.serviceFor("apach.notifications") : null
    if (target) root.service = target
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: resolveService()
  onBarChanged: {
    resolveService()
    injectPanel()
    injectService()
  }
  onSettingsChanged: injectPanel()
  onServiceChanged: injectService()

  // The service is created by the shell after the bar mounts. One short probe
  // bridges that startup window; it stops as soon as the object is available.
  Timer {
    interval: 250
    repeat: true
    running: root.service === null
    onTriggered: root.resolveService()
  }

  // Reclaim the panel's QML tree while the center is closed; the store keeps
  // the badge live. The delay leaves time for the bar to release this widget
  // as the active popout before the object is destroyed.
  Timer {
    id: unloadTimer
    interval: 30000
    repeat: false
    onTriggered: if (!panelLoader.item || !panelLoader.item.opened) root.panelActive = false
  }

  onOpenedChanged: {
    if (root.opened) unloadTimer.stop()
    else if (root.panelActive) unloadTimer.restart()
  }

  Loader {
    id: storeLoader
    active: true
    source: Qt.resolvedUrl("Store.qml")
    visible: false
    onLoaded: {
      root.injectService()
      root.injectPanel()
    }
  }

  Loader {
    id: panelLoader
    active: root.panelActive
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      var action = root.pendingAction
      root.pendingAction = ""
      if (action !== "" && panelLoader.item)
        panelLoader.item[action]()
    }
  }

  IpcHandler {
    target: "apach.notifications"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void {
      if (panelLoader.item) {
        panelLoader.item.openSettings()
        return
      }
      root.pendingAction = "openSettings"
      root.panelActive = true
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.bellGlyph
    slotSize: Style.bar.statusSlot
    tooltipText: root.tooltipText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleDnd()
      else root.toggle()
    }
  }

  // Unread count badge, GNOME-style dot with the number of unseen entries.
  Rectangle {
    id: badge
    anchors.top: button.top
    anchors.right: button.right
    anchors.topMargin: Style.space(0)
    anchors.rightMargin: Style.space(0)
    visible: root.unseen > 0 && (!root.store || root.store.showBadge !== false)
    height: Style.space(13)
    width: Math.max(height, badgeText.implicitWidth + Style.space(7))
    radius: height / 2
    color: root.bar ? root.bar.urgent : Commons.Color.urgent

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.unseen > 9 ? "9+" : String(root.unseen)
      color: "#ffffff"
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
