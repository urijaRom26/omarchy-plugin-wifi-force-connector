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

  // The remembered SSID, read by statewriter.pl --read rather than by
  // FileView. FileView opens the path normally and therefore FOLLOWS a
  // symlink, so a planted link would feed an attacker-chosen string straight
  // into NetworkManager.connectWithPsk(). The helper opens with O_NOFOLLOW
  // and refuses anything that is not a plain regular file, so a symlink at the
  // path yields "" (auto-detect) instead of a chosen network name.
  //
  // This is async, so the value fills in shortly after startup; until then
  // targetSsid falls back to the strongest encrypted network in range.
  property string _savedSsid: ""

  function readSavedSsid() {
    readProc.command = ["/usr/bin/perl", root._pluginDir + "/statewriter.pl", "--read", root._statePath()]
    readProc.running = true
  }

  function _statePath() {
    return (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") || "") + "/.local/state")
      + "/urija.wifi-force-connector/ssid"
  }

  Process {
    id: readProc
    command: []
    running: false
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    onExited: function(exitCode) {
      readProc.running = false
      // Any failure (missing, symlink, directory, unreadable) means "no saved
      // choice", which is a safe fallback: auto-detect from the scan.
      root._savedSsid = exitCode === 0 ? String(readOut.text || "").trim() : ""
    }
  }

  readonly property string savedSsid: root._savedSsid

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

  // Persist the target SSID.
  //
  // SECURITY: the destination is a predictable path
  // ($XDG_STATE_HOME/urija.wifi-force-connector/ssid), so it is treated as
  // hostile. The write is performed by a single open(2) on a private temp
  // file followed by an atomic rename(2) onto the destination. Neither step
  // ever opens the destination for writing, so a symlink planted there --
  // before, during, or after -- cannot be followed and its target cannot be
  // modified. See statewriter.pl for the full rationale.
  //
  // The payload travels over stdin, never argv: argv is world-readable
  // through /proc, and the SSID is not a secret, but keeping content out of
  // argv also keeps it out of any process listing.
  function rememberSsid(ssid) {
    if (ssid === "") return
    root._pendingSsid = ssid
    root._cfgDir = (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") || "") + "/.local/state")
      + "/urija.wifi-force-connector"
    mkdirProc.command = ["mkdir", "-p", root._cfgDir]
    mkdirProc.running = true
  }

  // mkdir finished -> hand the payload to the helper.
  //
  // The payload is framed as "<byte-length> <space> <bytes>" because
  // Quickshell's Process.write() cannot close stdin: there is no close() and
  // no EOF is delivered, so a helper that read to EOF would block forever
  // (verified: `tee` never exits under qs). With a length prefix the helper
  // reads exactly that many bytes and terminates.
  function stageWrite() {
    writeProc.stdinEnabled = true
    writeProc.command = ["/usr/bin/perl", root._pluginDir + "/statewriter.pl", root._cfgDir + "/ssid"]
    writeProc.running = true
    Qt.callLater(function() {
      if (!writeProc.running) return
      // Byte length, not character length, so UTF-8 SSIDs survive.
      var n = unescape(encodeURIComponent(root._pendingSsid)).length
      if (n < 1 || n > 255) {
        writeProc.running = false
        root.refuseWrite("network name has an unsupported length")
        return
      }
      writeProc.write(n + " " + root._pendingSsid)
    })
  }

  function finishWrite() {
    // The file on disk is already updated; keep the in-memory value in step so
    // targetSsid does not stay on the previous choice until the next restart.
    root._savedSsid = root._pendingSsid
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

  // The remembered SSID is read and written exclusively through
  // statewriter.pl (see readSavedSsid / rememberSsid). There is deliberately
  // no FileView here: it opens paths normally and would follow a symlink at
  // this predictable location, on both read and write.

  // ---- state write --------------------------------------------------------
  //
  // There is deliberately NO check-then-write chain here. An earlier version
  // ran `test -L`, `test -e`, `test -f`, `wc -c`, `touch` and then
  // FileView.setText() as a sequence of separate processes. That was wrong
  // twice over:
  //
  //   * test -f FOLLOWS symlinks, so it approves a symlink whose target is a
  //     regular file. The guard passed and the write then went through the
  //     link.
  //   * every step re-resolved the pathname, so a same-user process could
  //     swap in a symlink between the last check and the write. The value
  //     checked was never the value written.
  //
  // The write is now a single process -- statewriter.pl -- which creates a
  // private temp file with O_CREAT|O_EXCL|O_NOFOLLOW, writes the payload
  // through that already-open descriptor, and publishes it with rename(2).
  // rename replaces the destination *name* and never follows a symlink there,
  // so there is no check/write window at all. See statewriter.pl.
  Process {
    id: mkdirProc
    command: []
    running: false
    onExited: function(exitCode) {
      mkdirProc.running = false
      if (exitCode !== 0) {
        root.refuseWrite("could not create state directory (exit " + exitCode + ")")
        return
      }
      root.stageWrite()
    }
  }

  // The single write path. Payload goes over stdin, never argv.
  Process {
    id: writeProc
    command: []
    running: false
    stdinEnabled: true
    stderr: StdioCollector { id: writeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      writeProc.running = false
      if (exitCode !== 0) {
        var why = String(writeStderr.text || "").trim()
        root.refuseWrite(why !== "" ? why : "state write refused (exit " + exitCode + ")")
        return
      }
      root.finishWrite()
    }
  }

  // Refuse to write and surface it. Never falls back to a destructive write.
  function refuseWrite(reason) {
    root._pendingSsid = ""
    root.resultIsError = true
    root.resultMessage = "Not writing state: " + reason
    console.warn("WifiForceConnector: " + root.resultMessage)
  }

  property string _cfgDir: ""
  property string _pendingSsid: ""

  // Absolute path to this plugin's own directory, so the helper script is
  // found no matter where `omarchy plugin add` installed it.
  //
  // Qt.resolvedUrl() returns a *URL* ("file:///home/..."), which is not a
  // usable argv value -- perl looks for a literal path named
  // "file:///home/..." and fails. Strip the scheme, then percent-decode
  // (a plugin id or install path may contain spaces or other escapes).
  readonly property string _pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    u = u.replace(/^file:\/\/\//, "/")
    return decodeURIComponent(u).replace(/\/$/, "")
  }

  // Load the remembered SSID once the shell has finished starting. Until this
  // resolves, targetSsid falls back to auto-detection, which is a safe
  // default: it never connects to a name an attacker chose.
  Timer {
    id: startupRead
    interval: 400
    running: true
    repeat: false
    onTriggered: root.readSavedSsid()
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
