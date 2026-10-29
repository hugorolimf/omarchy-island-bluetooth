import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import "../io.github.hugorolimf.kit/ui"
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "Strings.js" as Strings

Panel {
  id: root
  moduleName: "io.github.hugorolimf.bluetooth"
  ipcTarget: "omarchy.bluetooth"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the toggleBluetooth method below.
  manageIpc: false

  // Address -> "connecting" | "disconnecting" | "forgetting".
  // The actual Bluetooth sequencing lives in bin/omarchy-bluetooth-device;
  // this map only keeps the panel responsive while BlueZ catches up.
  property var pendingActions: ({})

  readonly property var adapter: Bluetooth.defaultAdapter

  // True while this instance owes BlueZ a StopDiscovery: set when it starts
  // discovery (or opens onto a session already running) and cleared once
  // discovery is confirmed down after close. Ownership, not state — BlueZ's
  // Discovering property also reflects sessions other clients hold, which are
  // never this panel's to stop.
  property bool owesDiscoveryStop: false
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var pipewireNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  property var pendingAudioOutputDevice: null
  property int pendingAudioOutputAttempts: 0

  function deviceLabel(device) {
    return Model.deviceLabel(device)
  }

  function isUuidLike(value) {
    return Model.isUuidLike(value)
  }

  function isAddressLike(value) {
    return Model.isAddressLike(value)
  }

  function hasHumanName(device) {
    return Model.hasHumanName(device)
  }

  readonly property var deviceGroups: Model.deviceLists(devices)
  readonly property var connectedDevices: deviceGroups.connected || []
  readonly property var knownDevices: deviceGroups.known || []
  readonly property var discoveredDevices: deviceGroups.discovered || []

  readonly property string icon: {
    if (!adapter) return ""
    if (!adapter.enabled) return "󰂲"
    if (connectedDevices.length > 0) return "󰂱"
    return "󰂯"
  }

  property int phraseIndex: 0
  readonly property var activePhrases: [
    Strings.T("Desembaraçando fios"),
    Strings.T("Transmitindo vikings"),
    Strings.T("Pareando mistérios"),
    Strings.T("Reunindo fones"),
    Strings.T("Domando rádios"),
    Strings.T("Convocando caixas de som"),
    Strings.T("Laçando codecs"),
    Strings.T("Polindo pacotes")
  ]
  readonly property bool rotatingPhrases: adapter && adapter.enabled
  readonly property string heroStatusText: {
    if (!adapter) return Strings.T("Sem adaptador")
    if (!adapter.enabled) return Strings.T("Desligado")
    return activePhrases[phraseIndex % activePhrases.length]
  }

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "connected"  — currently connected devices; Enter disconnects.
  //   "known"      — remembered devices; Enter connects.
  //   "discovered" — unremembered devices visible while scanning; Enter connects.
  // Visuals always come from CursorSurface (hasCursor / current),
  // never from containsMouse. Mouse hover updates root cursor state too,
  // guaranteeing one highlight on screen.
  property string focusSection: "connected"
  property int selectedIndex: 0
  property bool actionFocused: false
  property bool cursorActive: false

  // Stable identity for the focused device. Devices move between sections as
  // they connect, disconnect, pair, or get forgotten, so follow the BlueZ
  // address across section changes instead of preserving a stale row index.
  property string focusedDeviceAddress: ""

  // "header" is a virtual section for the hero Bluetooth on/off toggle; it
  // sits above the device sections so the adapter can be toggled by keyboard
  // even when it is off and no device rows exist.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property string toggleHint: root.adapter && root.adapter.enabled ? Strings.T("Desligar o Bluetooth") : Strings.T("Ligar o Bluetooth")

  // Anatomy stroke icon for the hero: slashed when off, blue once something
  // is connected (colour only for state, as in Island Bar).
  readonly property string heroIconPath: !adapter || !adapter.enabled
    ? Anatomy.icons.bluetooth + Anatomy.icons.slash
    : Anatomy.icons.bluetooth

  function kindIcon(kind) {
    var I = Anatomy.icons
    if (kind === "headphones") return I.headphones
    if (kind === "speaker") return I.speaker + I.wave1
    if (kind === "keyboard") return I.keyboard
    if (kind === "mouse") return I.mouse
    if (kind === "gamepad") return I.gamepad
    if (kind === "phone") return I.phone
    if (kind === "monitor") return I.monitor
    return I.bluetooth
  }

  function sectionCount(section) {
    if (section === "connected") return connectedDevices.length
    if (section === "known") return knownDevices.length
    if (section === "discovered") return discoveredDevices.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "connected") return connectedDevices.length > 0
    if (section === "known") return knownDevices.length > 0
    if (section === "discovered") return adapter && adapter.discovering && discoveredDevices.length > 0
    return false
  }

  readonly property var visibleSections: {
    return Model.visibleSections(deviceGroups, adapter && adapter.discovering)
  }

  function devicesForSection(section) {
    return Model.sectionDevices(deviceGroups, section)
  }

  // The scrollable half of the panel — remembered devices, then whatever the
  // scan turned up — flattened into one model so a ListView can own the
  // viewport. Each entry carries the section it came from, which is what lets
  // the delegate and the cursor keep working in section-relative terms.
  readonly property var scrollRows: {
    var rows = []
    for (var k = 0; k < knownDevices.length; k++)
      rows.push({ dev: Model.deviceRow(knownDevices[k]), section: "known", indexInSection: k })
    if (sectionVisible("discovered"))
      for (var d = 0; d < discoveredDevices.length; d++)
        rows.push({ dev: Model.deviceRow(discoveredDevices[d]), section: "discovered", indexInSection: d })
    return rows
  }

  // Connected devices render above the scroll area; same primitives-only
  // projection so those delegates never hold Device QObject wrappers either.
  readonly property var connectedRows: {
    var rows = []
    for (var i = 0; i < connectedDevices.length; i++)
      rows.push(Model.deviceRow(connectedDevices[i]))
    return rows
  }

  // Live BlueZ device behind a row. Rows carry primitives only, so actions
  // resolve the backend object here rather than holding a wrapper that can
  // dangle mid-incubation. `devices` is already the raw device array (see the
  // property declaration), so it is iterated directly.
  function deviceFor(row) {
    if (!row || !row.dev) return null
    var addr = row.dev.address || ""
    var devs = devices || []
    for (var i = 0; i < devs.length; i++) {
      if ((devs[i].address || "") === addr) return devs[i]
    }
    return null
  }

  // Flat position of the keyboard cursor, or -1 while it sits on the hero or
  // in the connected list (both of which live outside the scroll area).
  readonly property int scrollRowIndex: {
    if (focusSection !== "known" && focusSection !== "discovered") return -1
    for (var i = 0; i < scrollRows.length; i++)
      if (scrollRows[i].section === focusSection && scrollRows[i].indexInSection === selectedIndex) return i
    return -1
  }

  // A row opens a section when it is the first of its kind in the flat list.
  function scrollSectionTitle(index) {
    var rows = scrollRows
    if (index < 0 || index >= rows.length) return ""
    if (index > 0 && rows[index - 1].section === rows[index].section) return ""
    return rows[index].section === "known" ? Strings.T("CONHECIDOS") : Strings.T("ENCONTRADOS")
  }

  function audioSinks() {
    var sinks = []
    for (var i = 0; i < pipewireNodes.length; i++) {
      var node = pipewireNodes[i]
      if (node && node.isSink && !node.isStream) sinks.push(node)
    }
    return sinks
  }

  function bluetoothAudioSink(device) {
    var sinks = audioSinks()
    for (var i = 0; i < sinks.length; i++) {
      if (Model.bluetoothSinkMatchesDevice(sinks[i], device)) return sinks[i]
    }
    return null
  }

  function setDefaultAudioSink(sink) {
    if (!sink) return
    Pipewire.preferredDefaultAudioSink = sink
    if (sink.id !== undefined && sink.name) {
      Quickshell.execDetached([
        "omarchy-audio-output-set-default",
        String(sink.id),
        String(sink.name)
      ])
    }
  }

  function scheduleAudioOutputSwitch(device) {
    pendingAudioOutputDevice = {
      address: device && device.address ? device.address : "",
      name: device && device.name ? device.name : "",
      deviceName: device && device.deviceName ? device.deviceName : ""
    }
    pendingAudioOutputAttempts = 0
    audioSwitchTimer.restart()
  }

  function switchPendingAudioOutput() {
    if (!pendingAudioOutputDevice) return

    var sink = bluetoothAudioSink(pendingAudioOutputDevice)
    if (sink) {
      setDefaultAudioSink(sink)
      pendingAudioOutputDevice = null
      audioSwitchTimer.stop()
      return
    }

    pendingAudioOutputAttempts += 1
    if (pendingAudioOutputAttempts >= 8) {
      pendingAudioOutputDevice = null
      return
    }
    audioSwitchTimer.restart()
  }

  function deviceAt(section, index) {
    var list = devicesForSection(section)
    return index >= 0 && index < list.length ? list[index] : null
  }

  function cloneMap(map) {
    return Model.cloneMap(map)
  }

  function pendingAction(address) {
    return Model.pendingAction(pendingActions, address)
  }

  function setPendingAction(address, action) {
    if (!address) return
    pendingActions = Model.withPendingAction(pendingActions, address, action)
    if (action) pendingTimeout.restart()
  }

  function deviceCommand(action, address) {
    return ["omarchy-bluetooth-device", action, address]
  }

  function runDeviceAction(device, action, pending) {
    if (!device || !device.address) return
    setPendingAction(device.address, pending)
    Quickshell.execDetached(deviceCommand(action, device.address))
  }

  function connectDevice(device) {
    if (!device || device.connected) return
    if (device.paired || device.bonded || device.trusted) runDeviceAction(device, "connect", "connecting")
    else runDeviceAction(device, "pair", "connecting")
  }

  function disconnectDevice(device) {
    if (!device || !device.address) return
    if (!device.connected) return
    setPendingAction(device.address, "disconnecting")
    if (device.disconnect) device.disconnect()
    Quickshell.execDetached(deviceCommand("disconnect", device.address))
  }

  function forgetDevice(device) {
    if (!device || !device.address) return
    runDeviceAction(device, "forget", "forgetting")
  }

  function syncPendingActions() {
    var next = cloneMap(pendingActions)
    var changed = false

    for (var address in next) {
      var action = next[address]
      var found = null

      for (var i = 0; i < devices.length; i++) {
        var d = devices[i]
        if (d && d.address === address) {
          found = d
          break
        }
      }

      var finishedConnecting = action === "connecting" && found && found.connected
      if (finishedConnecting
          || (action === "disconnecting" && found && !found.connected)
          || (action === "forgetting" && (!found || (!found.paired && !found.bonded && !found.trusted)))) {
        if (finishedConnecting) scheduleAudioOutputSwitch(found)
        delete next[address]
        changed = true
      }
    }

    if (changed) pendingActions = next
  }

  // j/k navigates the hero toggle ("header") and the device sections
  // row-by-row.
  function moveCursor(delta) {
    var sections = visibleSections
    if (focusSection === "header") {
      if (delta > 0 && sections && sections.length > 0) {
        focusSection = sections[0]; selectedIndex = 0; actionFocused = false
      }
      return
    }
    if (!sections || sections.length === 0) { focusSection = "header"; actionFocused = false; return }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; actionFocused = false; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; actionFocused = false; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = 0
        actionFocused = false
      }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; actionFocused = false; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = sectionCount(focusSection) - 1
        actionFocused = false
      } else {
        focusSection = "header"; actionFocused = false
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    actionFocused = false
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev || !dev.address) return
    if (delta > 0) actionFocused = true
    else if (delta < 0) actionFocused = false
  }

  function activateCursor() {
    if (focusSection === "header") {
      toggleBluetooth()
      return
    }
    if (actionFocused) {
      deleteSelected()
      return
    }

    if (focusSection === "connected" || focusSection === "known") {
      var dev = deviceAt(focusSection, selectedIndex)
      if (!dev) return
      if (dev.connected) disconnectDevice(dev)
      else connectDevice(dev)
      return
    }
    if (focusSection === "discovered") {
      var d = discoveredDevices[selectedIndex]
      if (!d) return
      connectDevice(d)
    }
  }

  // 'x' forgets remembered devices. For connected devices this first
  // disconnects, then removes the BlueZ pairing record via omarchy-bluetooth-device.
  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    forgetDevice(dev)
  }

  onOpenedChanged: {
    if (opened) {
      // Adopt a discovery session that is already running — a popout handoff
      // from another monitor, or one leaked by an instance that could not
      // finish its own stop — so this close settles it either way.
      if (adapter !== null && adapter.discovering) owesDiscoveryStop = true
      if (connectedDevices.length > 0) { focusSection = "connected"; selectedIndex = 0 }
      else if (knownDevices.length > 0) { focusSection = "known"; selectedIndex = 0 }
      else if (discoveredDevices.length > 0) { focusSection = "discovered"; selectedIndex = 0 }
      else { focusSection = "header" }
      actionFocused = false
      cursorActive = false
    } else {
      tetherExpanded = false
    }
  }

  // Another per-monitor instance of this widget whose panel is open, if any.
  // All instances share the default adapter, and switching the popout to a
  // different monitor closes one instance as it opens the next, so the
  // closing side has to leave the scan alone for the side still on screen.
  function openSibling() {
    if (!bar || typeof bar.moduleWidgets !== "function") return null
    var items = bar.moduleWidgets(moduleName)
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && items[i].opened === true) return items[i]
    }
    return null
  }

  function updateFocusedAddress() {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? (d.address || "") : ""
  }

  function reselectFocusedDevice() {
    if (focusedDeviceAddress === "") {
      clampCursor()
      return
    }

    var sections = ["connected", "known", "discovered"]
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      if (!sectionVisible(section)) continue
      var list = devicesForSection(section)
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].address === focusedDeviceAddress) {
          focusSection = section
          selectedIndex = i
          clampCursor()
          return
        }
      }
    }

    clampCursor()
  }

  onSelectedIndexChanged: updateFocusedAddress()
  onFocusSectionChanged: updateFocusedAddress()
  onConnectedDevicesChanged: { reselectFocusedDevice(); syncPendingActions() }
  onKnownDevicesChanged: { reselectFocusedDevice(); syncPendingActions() }
  onDiscoveredDevicesChanged: { reselectFocusedDevice(); syncPendingActions() }
  onVisibleSectionsChanged: clampCursor()

  function clampCursor() {
    var sections = visibleSections
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: toggling the adapter empties and refills the device
    // lists, and clamping would knock the cursor off the hero switch every
    // time it is used.
    if (focusSection === "header") return
    if (!sections || !sections.length) {
      selectedIndex = 0
      return
    }
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = 0
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) {
      // Section emptied out — bounce to the previous visible one.
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = Math.max(0, sectionCount(focusSection) - 1)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  visible: adapter !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // BlueZ rejects StartDiscovery while the adapter is still powering up, and
  // discovery can also time out on its own. While the panel is open, keep
  // nudging it back on so an enabled adapter is always scanning.
  Timer {
    id: discoveryRetry
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.adapter !== null && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.owesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  // The way back down. The BlueZ discovery session behind adapter.discovering
  // is held by quickshell's D-Bus connection, so nothing ends it at close:
  // without this timer, one visit to the panel left the radio in inquiry
  // until the next shell restart, starving A2DP audio on the same controller
  // into stutters.
  //
  // A timer bound to the confirmed state rather than a write at close time:
  // quickshell only forwards a discovering write that differs from the last
  // state BlueZ reported, so a stop issued while a just-fired StartDiscovery
  // is still awaiting confirmation would be swallowed and leak the session.
  // Binding to adapter.discovering means a confirmation landing at any point
  // after close re-arms the stop, and a reopen inside the first interval
  // keeps the scan running uninterrupted. Attempts are bounded so a session
  // some other BlueZ client keeps up cannot draw StopDiscovery fire forever.
  Timer {
    id: discoveryStop
    interval: 1000
    repeat: true
    property int attempts: 0
    running: !root.opened && root.owesDiscoveryStop && root.adapter !== null && root.adapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      // The scan now serves the open panel, so the debt moves with it — B may
      // have opened before BlueZ confirmed A's start, in which case B's own
      // open-time adoption saw nothing to adopt.
      var sibling = root.openSibling()
      if (sibling) {
        sibling.owesDiscoveryStop = true
        root.owesDiscoveryStop = false
        return
      }
      attempts += 1
      if (attempts > 3) { root.owesDiscoveryStop = false; return }
      root.adapter.discovering = false
    }
  }

  // The debt is settled the moment BlueZ reports discovery down — whether
  // because the stop above landed or the session ended some other way — so a
  // stale claim never touches a scan another client starts later. While the
  // panel is open, discoveryRetry re-incurs it as it restarts the scan.
  Connections {
    target: root.adapter
    function onDiscoveringChanged() {
      if (!root.adapter.discovering) root.owesDiscoveryStop = false
    }
  }

  // A destroyed instance cannot wait for BlueZ confirmations, so it hands any
  // debt to a surviving sibling — whose declarative stop catches even a start
  // confirmed after this object is gone — and only writes the stop directly
  // when it is the last one standing.
  Component.onDestruction: {
    if (!owesDiscoveryStop) return
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root) { items[i].owesDiscoveryStop = true; return }
    }
    if (adapter !== null && adapter.discovering) adapter.discovering = false
  }

  Timer {
    id: pendingTimeout
    interval: 20000
    repeat: false
    onTriggered: root.pendingActions = ({})
  }

  Timer {
    id: audioSwitchTimer
    interval: 500
    repeat: false
    onTriggered: root.switchPendingAudioOutput()
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  // Not adapter.enabled: that writes BlueZ's Powered, which nothing persists, so
  // the adapter came back on at the next boot. omarchy-bluetooth-power moves the
  // rfkill soft block instead, which systemd-rfkill restores across reboots.
  // Powered still follows the block, so the switch and icon read it as before.
  //
  // Asking for a direction rather than a toggle: the helper runs detached and the
  // switch only moves once BlueZ catches up, so a second click inside that window
  // would re-read the old state and undo the first.
  function toggleBluetooth() {
    if (!adapter) return
    Quickshell.execDetached(["omarchy-bluetooth-power", adapter.enabled ? "off" : "on"])
  }

  // ---- Tether (Island iPhone) ----------------------------------------------
  // The iPhone Tether drives is the device_address in its bluetooth.json.
  // Its row gets a chevron that unfolds Island iPhone's TetherSettings below
  // it; without the Island iPhone plugin (or Tether) nothing changes here.
  property string tetherAddress: ""
  property bool tetherExpanded: false
  property bool tetherUiPresent: false
  readonly property url tetherUi: Qt.resolvedUrl("../io.github.hugorolimf.iphone/TetherSettings.qml")

  function isTetherDevice(dev) {
    return !!dev && tetherAddress !== "" && String(dev.address || "").toUpperCase() === tetherAddress
  }

  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") || "") + "/.config") + "/tether/bluetooth.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.tetherAddress = String(JSON.parse(text()).device_address || "").toUpperCase() }
      catch (e) { root.tetherAddress = "" }
    }
    onLoadFailed: root.tetherAddress = ""
  }

  FileView {
    path: String(root.tetherUi).replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: root.tetherUiPresent = true
    onLoadFailed: root.tetherUiPresent = false
  }

  IpcHandler {
    target: "omarchy.bluetooth"

    // Open with the iPhone's Tether section unfolded.
    function iphone() { root.tetherExpanded = true; root.open() }

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleBluetooth() { root.toggleBluetooth() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBluetooth()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.toggleBluetooth()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: Bluetooth icon · status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          // Status only — the switch owns toggling, mouse and keyboard alike.
          AnatomyIcon {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            path: root.heroIconPath
            size: Style.font.display
            strokeWidth: 1.3
            color: !root.adapter || !root.adapter.enabled ? Anatomy.mid
              : root.connectedDevices.length > 0 ? Anatomy.blue
              : Anatomy.hi
          }

          // Compact on/off switch on the trailing edge of the hero, and the
          // header's only cursor target.
          ToggleSwitch {
            id: powerSwitch
            visible: !!root.adapter
            checked: !!root.adapter && root.adapter.enabled
            hasCursor: root.headerHasCursor
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) { if (on) root.setHeaderCursor() }
            onToggled: root.toggleBluetooth()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.toggleHint
              fontFamily: Anatomy.sans
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Bluetooth"
              color: Anatomy.strong
              font.family: Anatomy.sans
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Anatomy.muted
              font.family: Anatomy.mono
              font.pixelSize: Style.font.caption
              font.weight: Font.DemiBold
              font.letterSpacing: Anatomy.labelSpacing
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // Scrollable device list — capped so a noisy neighborhood doesn't
        // grow the popup past the screen.
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          id: connectedList
          visible: root.connectedDevices.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: Strings.T("CONECTADOS")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.connectedRows
            Column {
              id: connectedEntry
              required property var modelData
              required property int index
              width: connectedList.width
              spacing: Style.space(10)

              DeviceRow {
                width: parent.width
                dev: connectedEntry.modelData
                rowIndex: connectedEntry.index
                sectionName: "connected"
                isDiscovered: false
              }
              TetherSlot { dev: connectedEntry.modelData }
            }
          }
        }

        PanelSeparator {
          visible: root.connectedDevices.length > 0 && root.scrollRows.length > 0
          foreground: root.bar.foreground
        }

        // ListView, not a Flickable: it owns the scroll position, so it keeps
        // the current row visible on j/k, re-clamps itself when discovery
        // shortens the list, and — because Contain only moves when a row is
        // actually clipped — never lurches under a hovering mouse.
        ListView {
          id: deviceListView
          width: parent.width
          height: Math.min(contentHeight, Style.space(400))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.scrollRows
          currentIndex: root.scrollRowIndex
          // Deferred by a turn. Called straight out of the signal the position
          // does not take — verified with the cursor six rows down and
          // contentY still 0 — because scrollRows is rebuilt every time
          // discovery reports, and swapping the model resets the view out from
          // under the call. Network's list is stable enough not to need this.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Item {
            required property var modelData
            required property int index
            readonly property string sectionTitle: root.scrollSectionTitle(index)

            width: ListView.view.width
            height: delegateColumn.implicitHeight

            Column {
              id: delegateColumn
              width: parent.width
              spacing: Style.space(10)

              PanelSeparator {
                visible: index > 0 && sectionTitle !== ""
                height: visible ? implicitHeight : 0
                foreground: root.bar.foreground
              }

              PanelSectionHeader {
                visible: sectionTitle !== ""
                height: visible ? implicitHeight : 0
                text: sectionTitle
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              DeviceRow {
                width: parent.width
                dev: modelData.dev
                rowIndex: modelData.indexInSection
                sectionName: modelData.section
                isDiscovered: modelData.section === "discovered"
              }
              TetherSlot { dev: modelData.dev }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.connectedDevices.length === 0 && root.scrollRows.length === 0
          text: !root.adapter ? Strings.T("Nenhum adaptador Bluetooth")
              : !root.adapter.enabled ? Strings.T("Ligue o Bluetooth para procurar aparelhos")
              : Strings.T("Procurando aparelhos…")
          color: Anatomy.muted
          font.family: Anatomy.sans
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }
    }
  }

  // Two-line device row showing name + live status. Pending state is owned
  // by the panel so it survives rows moving between sections.
  component DeviceRow: CursorSurface {
    id: row
    required property var dev
    required property int rowIndex
    required property string sectionName
    required property bool isDiscovered

    readonly property bool isConnected: dev && dev.connected
    readonly property int devState: dev && dev.state !== undefined ? dev.state : -1
    readonly property string action: root.pendingAction(dev ? dev.address : "")
    readonly property string actionTooltip: {
      if (!dev) return ""
      if (isConnected) return Strings.T("Desconectar")
      if (isDiscovered) return Strings.T("Parear")
      return Strings.T("Conectar")
    }

    readonly property bool rowSelected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property bool forgetAvailable: (sectionName === "known" || sectionName === "connected") && !isDiscovered
    readonly property bool showForgetButton: forgetAvailable && (rowMouse.containsMouse || rowSelected)
    readonly property bool isTether: root.tetherUiPresent && root.isTetherDevice(dev)

    hasCursor: rowSelected && !root.actionFocused
    current: isConnected
    foreground: Anatomy.text

    readonly property string statusText: {
      if (!dev) return ""
      if (action === "forgetting") return Strings.T("Esquecendo…")
      if (action === "disconnecting" || devState === 2) return Strings.T("Desconectando…")
      if (isConnected) {
        if (dev.batteryAvailable) return Strings.T("Bateria ") + Math.round(dev.battery * 100) + "%"
        return sectionName === "connected" ? "" : Strings.T("Conectado")
      }
      if (action === "connecting" || devState === 3 || dev.pairing === true) return Strings.T("Conectando…")
      if (isDiscovered) return ""
      return ""
    }

    readonly property color statusColor: {
      if (isConnected) return Anatomy.text
      if (action !== "" || devState === 3 || dev.pairing === true) return Anatomy.text
      return Anatomy.muted
    }

    // Battery colour only says something when it runs low.
    readonly property color batteryColor: {
      if (!dev || !dev.batteryAvailable) return statusColor
      var p = Math.round(dev.battery * 100)
      if (p < 10) return Anatomy.red
      if (p < 20) return Anatomy.amber
      return statusColor
    }

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: row.dev ? Qt.PointingHandCursor : Qt.ArrowCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = row.sectionName
        root.selectedIndex = row.rowIndex
        root.actionFocused = false
      }

      onClicked: function(mouse) {
        var dev = root.deviceFor(row)
        if (!dev) return
        if (mouse.button === Qt.RightButton) {
          if (row.isConnected) root.disconnectDevice(dev)
          else if (!row.isDiscovered) root.forgetDevice(dev)
          return
        }
        if (row.isConnected) root.disconnectDevice(dev)
        else root.connectDevice(dev)
      }
    }

    PanelToolTip {
      visible: row.actionTooltip !== "" && rowMouse.containsMouse && !root.actionFocused
      text: row.actionTooltip
      fontFamily: Anatomy.sans
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight, forgetBtn.implicitHeight)

      AnatomyIcon {
        id: deviceIcon
        path: root.kindIcon(Model.deviceKind(row.dev ? row.dev.icon : ""))
        size: Style.font.heading
        color: row.isConnected ? Anatomy.blue : Anatomy.hi
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: forgetBtn.visible ? forgetBtn.left : (tetherBtn.visible ? tetherBtn.left : parent.right)
        anchors.rightMargin: forgetBtn.visible || tetherBtn.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: root.deviceLabel(row.dev) || Strings.T("Aparelho")
          color: row.isConnected || row.hasCursor ? Anatomy.strong : Anatomy.text
          font.family: Anatomy.sans
          font.pixelSize: Style.font.body
          font.weight: row.isConnected ? Font.Medium : Font.Normal
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          visible: row.statusText !== ""
          text: row.statusText.toUpperCase()
          color: row.batteryColor
          font.family: Anatomy.mono
          font.pixelSize: Style.font.caption
          font.letterSpacing: Anatomy.labelSpacing / 2
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: tetherBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.isTether
        tooltipText: root.tetherExpanded ? Strings.T("Fechar ajustes do iPhone") : Strings.T("Ajustes do iPhone (Tether)")
        foreground: Anatomy.mid
        fontFamily: Anatomy.sans

        AnatomyIcon {
          anchors.centerIn: parent
          path: Anatomy.icons.chevronDown
          size: Style.font.subtitle
          color: tetherBtn._hot || root.tetherExpanded ? Anatomy.strong : Anatomy.mid
          rotation: root.tetherExpanded ? 180 : 0
          Behavior on rotation { NumberAnimation { duration: Anatomy.fast; easing.type: Easing.Bezier; easing.bezierCurve: Anatomy.ease } }
        }
        onClicked: root.tetherExpanded = !root.tetherExpanded
      }

      PanelActionButton {
        id: forgetBtn
        anchors.right: tetherBtn.visible ? tetherBtn.left : parent.right
        anchors.rightMargin: tetherBtn.visible ? Style.space(4) : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showForgetButton
        tooltipText: Strings.T("Esquecer")
        foreground: Anatomy.mid
        hoverColor: Anatomy.red
        fontFamily: Anatomy.sans
        hasCursor: row.rowSelected && root.actionFocused

        AnatomyIcon {
          anchors.centerIn: parent
          path: Anatomy.icons.close
          size: Style.font.subtitle
          color: forgetBtn._hot ? Anatomy.red : Anatomy.mid
        }
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse) root.actionFocused = false
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.actionFocused = true
        }
        onClicked: {
          var dev = root.deviceFor(row)
          if (!dev) return
          root.forgetDevice(dev)
        }
      }
    }
  }

  // Island iPhone's TetherSettings under the Tether iPhone's row, loaded by
  // URL so this panel still loads when Island iPhone is not installed.
  component TetherSlot: Loader {
    required property var dev
    width: parent ? parent.width : 0
    active: root.tetherExpanded && root.tetherUiPresent && root.isTetherDevice(dev)
    visible: active && status === Loader.Ready
    source: active ? root.tetherUi : ""
    onLoaded: if (item) item.showOpenPanel = true
  }
}
