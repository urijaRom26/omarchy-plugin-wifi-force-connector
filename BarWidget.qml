import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Ui

// WiFi Force Connector — a recovery button for the "saved profile has a stale
// passphrase" failure that keeps biting the Legion Go.
//
// The bar button shows connection state only. Clicking it opens the panel,
// which has one big CONNECT button plus a passphrase field; submitting calls
// Network.connectWithPsk(), which makes NetworkManager create/overwrite the
// profile and activate it in one step. That is deliberately the same path the
// first-party omarchy.network panel uses, and the same command that fixed
// this machine by hand (`nmcli device wifi connect ...`).
//
// The passphrase NEVER reaches argv: argv is world-readable through /proc, and
// the first-party plugin documents that rule for exactly this operation. Going
// through the NM client also avoids the "no secrets agent" dead end a bare
// `nmcli connection up` hits in a non-interactive shell.
//
// All state lives here; the panel is a pure viewer of hostWidget, so the bar
// label and the panel can never disagree.

BarWidget {
  id: root
  moduleName: "urija.wifi-force-connector"

  readonly property color foreground: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.5)
  readonly property color okColor: "#a3be8c"
  readonly property color danger: root.bar ? root.bar.urgent : Color.urgent

  // ---- network state ------------------------------------------------------
  readonly property bool nmAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: {
    var devices = root.networkDevices
    for (var i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].type === DeviceType.Wifi) return devices[i]
    }
    return null
  }
  readonly property var wifiNetworks: root.wifiDevice && root.wifiDevice.networks
    ? root.wifiDevice.networks.values : []

  // ---- target network -----------------------------------------------------
  // The SSID this widget rescues. Default: the first non-Open network in
  // range, so the plugin ships with no hardcoded modem. An explicit choice is
  // remembered in the panel's own state file; WIFI_RESCUE_SSID overrides both.
  readonly property string ssidOverride: Quickshell.env("WIFI_RESCUE_SSID") || ""

  readonly property string savedSsid: {
    if (!configFile.loaded) return ""
    // FileView exposes contents through the text() METHOD, not a text
    // property -- `configFile.text` yields the function object itself (it
    // stringifies to "function text() { [native code] }"). Call it.
    return String(configFile.text() || "").trim()
  }

  readonly property string targetSsid: root.ssidOverride !== ""
    ? root.ssidOverride
    : (root.savedSsid !== "" ? root.savedSsid : root.defaultSsid)

  // Best-effort default so the button is useful with zero configuration: the
  // strongest encrypted network currently in range.
  readonly property string defaultSsid: {
    var nets = root.wifiNetworks
    var best = ""
    var bestSignal = -1
    for (var i = 0; i < nets.length; i++) {
      var n = nets[i]
      if (!n) continue
      var s = Math.round((n.signalStrength || 0) * 100)
      if (n.security === undefined || s <= bestSignal) continue
      // Skip open networks: they need no passphrase, so this widget is useless.
      if (n.security === WifiSecurityType.None || n.security === WifiSecurityType.Owe) continue
      best = n.name
      bestSignal = s
    }
    return best
  }

  function rememberSsid(ssid) {
    if (ssid === "") return
    root._pendingSsid = ssid
    if (configFile.loaded) {
      configFile.setText(ssid)
      root._pendingSsid = ""
      return
    }
    // File doesn't exist yet, so FileView has nothing loaded to write into.
    // Create the file, then flush the pending value once the view is live.
    root.ensureConfigFile()
  }

  // FileView cannot create missing parent directories, and `loaded` stays
  // FALSE for a file that does not exist -- so gating the first write on
  // `loaded` deadlocks it. `install -D /dev/null <path>` creates every
  // leading dir AND an empty regular file in ONE fixed argv (no shell string,
  // no per-request createObject). `mkdir -p <path>` is the trap: it happily
  // creates the FILE ITSELF as a directory, and setText then fails to save
  // while still reading back correct in memory.
  function ensureConfigFile() {
    root._mkdirRan = true
    var base = Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") || "") + "/.local/state"
    mkdirProc.command = ["install", "-D", "/dev/null", base + "/urija.wifi-force-connector/ssid"]
    mkdirProc.running = true
  }

  function flushPendingSsid() {
    if (root._pendingSsid === "" || !configFile.loaded) return
    configFile.setText(root._pendingSsid)
    root._pendingSsid = ""
  }

  readonly property var targetNetwork: {
    var nets = root.wifiNetworks
    for (var i = 0; i < nets.length; i++) {
      if (nets[i] && nets[i].name === root.targetSsid) return nets[i]
    }
    return null
  }

  readonly property var connectedNetwork: {
    var nets = root.wifiNetworks
    for (var i = 0; i < nets.length; i++) {
      if (nets[i] && nets[i].connected === true) return nets[i]
    }
    return null
  }

  readonly property bool wifiEnabled: Networking.wifiEnabled
  readonly property bool isConnectedToTarget: root.connectedNetwork
    ? root.connectedNetwork.name === root.targetSsid : false
  readonly property bool anyWifiConnected: root.connectedNetwork !== null

  readonly property bool targetInRange: root.targetNetwork !== null
  // NM reports signalStrength as a 0..1 fraction, not 0..100 — the same
  // *100 conversion the first-party network panel does.
  readonly property int targetSignal: root.targetNetwork
    ? Math.round((root.targetNetwork.signalStrength || 0) * 100) : -1

  // ---- action state -------------------------------------------------------
  // busy: a connect attempt is in flight (panel shows a spinner on the button)
  property bool busy: false
  property string resultMessage: ""
  property bool resultIsError: false
  property double lastAttemptAt: 0

  // Radios are blocked and a connect is pointless until a passphrase arrives.
  readonly property bool canAttempt: root.nmAvailable && root.wifiEnabled
    && root.targetInRange && !root.busy

  readonly property string statusLabel: {
    if (!root.nmAvailable) return "no NetworkManager"
    if (!root.wifiEnabled) return "wifi off"
    if (root.busy) return "connecting…"
    if (root.isConnectedToTarget) return "connected"
    if (!root.targetInRange) return "no signal"
    if (root.anyWifiConnected) return "on other net"
    return "disconnected"
  }

  readonly property color statusColor: {
    if (root.statusLabel === "connected") return root.okColor
    if (root.statusLabel === "no NetworkManager" || root.statusLabel === "no signal") return root.danger
    if (root.statusLabel === "connecting…") return root.dim
    return root.foreground
  }

  readonly property string tooltipText: "WiFi Force Connector · " + root.statusLabel
    + " · click to reconnect " + root.targetSsid

  // ---- connect ------------------------------------------------------------
  // Fire-and-report: the NM client emits connectionFailed(state, reason) on a
  // bad passphrase, and connectedChanged flips on success. Neither needs a
  // Process, so there is nothing to poll and nothing to time out.
  function connectWithPassphrase(passphrase) {
    if (root.busy) return
    if (!root.targetNetwork) {
      root.resultIsError = true
      root.resultMessage = "Can't see " + root.targetSsid + " — is the modem on?"
      return
    }

    root.busy = true
    root.resultIsError = false
    root.resultMessage = ""
    root.lastAttemptAt = Date.now()

    try {
      root.targetNetwork.connectWithPsk(passphrase)
    } catch (error) {
      root.finishAttempt(false, "connectWithPsk threw: " + error)
    }
  }

  // Called by the NM signals below; a 20s ceiling stops the button spinning
  // forever if NetworkManager gives up quietly without a failure signal.
  function finishAttempt(ok, message) {
    if (!root.busy) return
    root.busy = false
    if (ok) {
      root.resultIsError = false
      root.resultMessage = "Connected to " + root.targetSsid
    } else {
      root.resultIsError = true
      root.resultMessage = message || "Couldn't connect"
    }
    console.log("WifiForceConnector: connect " + (ok ? "ok" : "failed: " + root.resultMessage))
  }

  // A wrong passphrase shows up as WifiAuthTimeout. NoSecrets means the
  // profile has no key at all. Both are retryable by re-entering the
  // passphrase, so the panel reopens the field either way.
  function handleConnectionFailed(state, reason) {
    if (!root.busy) return
    var text = reason ? reason.toString() : "Failed"
    if (reason === ConnectionFailReason.WifiAuthTimeout) text = "Wrong password"
    else if (reason === ConnectionFailReason.NoSecrets) text = "Passphrase required"
    else if (reason === ConnectionFailReason.WifiNetworkLost) text = "Network lost"
    else if (reason === ConnectionFailReason.WifiClientDisconnected) text = "Disconnected mid-handshake"
    root.finishAttempt(false, text)
  }

  Timer {
    id: attemptWatchdog
    interval: 20000
    running: root.busy
    repeat: false
    onTriggered: root.finishAttempt(false, "Timed out after 20 s")
  }

  // Remembered target SSID. Machine-portable (HOME, never a hardcoded user
  // path) and holds no secret -- only the network name.
  //
  // Build the path by CONCATENATION: `Quickshell.env("XDG_STATE_HOME") ||
  // <fallback>` short-circuits to the bare state dir and drops the subdir,
  // which makes FileView try to open a directory. Also note FileView cannot
  // create missing parent directories, so the dir must already exist.
  FileView {
    id: configFile
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") || "") + "/.local/state")
      + "/urija.wifi-force-connector/ssid"
    watchChanges: false
    printErrors: true
  }

  // One reusable Process (never per-request createObject -- Quickshell can
  // wedge a component-created Process before it ever spawns).
  Process {
    id: mkdirProc
    command: []
    running: false
    onExited: function(exitCode) {
      mkdirProc.running = false
      if (exitCode !== 0) {
        console.warn("WifiForceConnector: could not create state file (exit " + exitCode + ")")
        return
      }
      // The file exists now, so the FileView can materialise. Reload brings
      // it up loaded; onLoaded then flushes the queued SSID.
      Qt.callLater(function() { configFile.reload() })
    }
  }

  property bool _mkdirRan: false
  property string _pendingSsid: ""

  // Flush once the FileView reports itself loaded (first run: the file does
  // not exist yet, so loaded only fires after mkdir + reload).
  Connections {
    target: configFile
    function onLoaded() { root.flushPendingSsid() }
  }

  // Success is observed from the model, not from a return value.
  Connections {
    target: root.connectedNetwork
    function onConnectedChanged() {
      if (root.busy && root.isConnectedToTarget) root.finishAttempt(true, "")
    }
  }

  // ---- panel lifecycle ----------------------------------------------------
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
    root.setScannerEnabled(true)
  }
  function close() {
    if (panelLoader.item) panelLoader.item.close()
    root.setScannerEnabled(false)
  }
  function togglePanel() {
    if (root.opened) root.close()
    else root.open()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function handlePressed(buttonCode) {
    if (buttonCode === Qt.LeftButton) {
      if (root.opened) root.close()
      else root.open()
    } else {
      // Right/middle click: forget the bad profile and force a clean rescan
      // so a stale profile can't shadow the reconnected one.
      root.forgetAndRescan()
    }
  }

  // The stale-profile failure mode is a saved profile holding a wrong PSK.
  // Deleting it makes the next connectWithPsk build a fresh one from scratch.
  function forgetAndRescan() {
    if (root.targetNetwork && typeof root.targetNetwork.forget === "function") {
      try {
        root.targetNetwork.forget()
        root.resultIsError = false
        root.resultMessage = "Forgot saved profile for " + root.targetSsid
        console.log("WifiForceConnector: forgot " + root.targetSsid)
      } catch (error) {
        console.log("WifiForceConnector: forget failed: " + error)
      }
    } else {
      root.resultIsError = true
      root.resultMessage = "No saved profile for " + root.targetSsid
    }
  }

  // Scan list for the panel's network picker. Primitive snapshots only (never
  // the live NM objects) so a delegate can never hold a wrapper to a network
  // that NetworkManager has since destroyed.
  //
  // NetworkManager only knows the APs it has actually scanned: with the radio
  // associated, the model holds just the connected network. scannerEnabled is
  // what makes it survey the rest, so it is turned on while the panel is open
  // and released on close (the same lifecycle the stock network panel uses).
  property var scannerDevice: null
  property bool scannerOn: false

  function setScannerEnabled(enabled) {
    var nextDevice = enabled ? root.wifiDevice : null

    if (root.scannerDevice && root.scannerDevice !== nextDevice) {
      try { root.scannerDevice.scannerEnabled = false } catch (error) {}
    }

    root.scannerDevice = nextDevice
    root.scannerOn = enabled

    if (root.scannerDevice) {
      try {
        root.scannerDevice.scannerEnabled = enabled
        console.log("WifiForceConnector: scanner " + (enabled ? "on" : "off"))
      } catch (error) {
        console.log("WifiForceConnector: scanner toggle failed: " + error)
      }
    }
  }

  Component.onDestruction: root.setScannerEnabled(false)

  readonly property var availableNetworks: {
    var nets = root.wifiNetworks
    var rows = []
    for (var i = 0; i < nets.length; i++) {
      var n = nets[i]
      if (!n || !n.name) continue
      var secured = n.security !== WifiSecurityType.None && n.security !== WifiSecurityType.Owe
      rows.push({
        ssid: n.name,
        signal: Math.round((n.signalStrength || 0) * 100),
        secured: secured,
        connected: n.connected === true
      })
    }
    rows.sort(function(a, b) {
      if (a.connected !== b.connected) return a.connected ? -1 : 1
      if (a.secured !== b.secured) return a.secured ? -1 : 1
      return b.signal - a.signal
    })
    return rows
  }

  function selectTarget(ssid) {
    root.rememberSsid(ssid)
  }

  // ---- IPC (headless verification) ---------------------------------------
  IpcHandler {
    target: root.moduleName
    function refresh(): void { root.forgetAndRescan() }
    function forget(): void { root.forgetAndRescan() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Geometry of the live panel, for generating a README preview image.
    // Delegated to the panel: `popup` is a local id inside Panel.qml and is
    // not reachable (and has no findChild) from here.
    function geometry(): string {
      var item = panelLoader.item
      if (!item || !item.opened) return JSON.stringify({ opened: false })
      if (typeof item.geometry !== "function") return JSON.stringify({ opened: true, measured: false })
      var g = item.geometry()
      return JSON.stringify({ opened: true, x: g.x, y: g.y, width: g.width, height: g.height })
    }
    // The passphrase is deliberately NOT an IPC arg: omarchy shell args are
    // visible in the process table. Drive the panel for an interactive entry.
    function select(ssid: string): void { root.selectTarget(ssid) }
    function status(): string {
      return JSON.stringify({
        status: root.statusLabel,
        ssid: root.targetSsid,
        ssidSource: root.ssidOverride !== "" ? "env" : (root.savedSsid !== "" ? "saved" : "auto"),
        nmAvailable: root.nmAvailable,
        wifiEnabled: root.wifiEnabled,
        inRange: root.targetInRange,
        signal: root.targetSignal,
        connected: root.anyWifiConnected,
        connectedToTarget: root.isConnectedToTarget,
        connectedSsid: root.connectedNetwork ? root.connectedNetwork.name : "",
        busy: root.busy,
        canAttempt: root.canAttempt,
        networks: root.availableNetworks.length,
        resultMessage: root.resultMessage,
        resultIsError: root.resultIsError,
        lastAttemptAt: root.lastAttemptAt
      })
    }
  }

  // ---- wiring -------------------------------------------------------------
  implicitWidth: box.implicitWidth + Style.space(12)
  implicitHeight: root.barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  // ---- bar chrome ---------------------------------------------------------
  Row {
    id: box
    anchors.centerIn: parent
    spacing: Style.space(4)

    Text {
      id: glyph
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "\uf0ac" // globe
      color: root.statusColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.busy ? "…" : (root.isConnectedToTarget ? "✓" : "!")
      color: root.statusColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    labelVisible: false
    tooltipText: root.tooltipText
    onPressed: function(buttonCode) {
      root.handlePressed(buttonCode)
    }
  }
}
