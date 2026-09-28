import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// WiFi Force Connector panel — the recovery UI.
//
// One job: get a correct passphrase into NetworkManager. The big CONNECT
// button hands the typed passphrase to hostWidget.connectWithPassphrase(),
// which calls Network.connectWithPsk() so NetworkManager creates or
// overwrites the profile and activates it. No shell, no argv, no keyring
// agent (which is what dead-ended the manual `nmcli connection up`).
//
// Every visible value is read from hostWidget, so the bar label and this
// panel are always the same source of truth.

Panel {
  id: root
  moduleName: "urija.wifi-force-connector"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.55)
  readonly property color okColor: "#a3be8c"
  readonly property color warn: "#ebcb8b"
  readonly property color danger: "#bf616a"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- view state (all from hostWidget) ----------------------------------
  readonly property string ssid: root.hostWidget ? root.hostWidget.targetSsid : "—"
  readonly property string statusText: root.hostWidget ? root.hostWidget.statusLabel : "loading"
  readonly property bool busy: root.hostWidget ? root.hostWidget.busy : false
  readonly property bool inRange: root.hostWidget ? root.hostWidget.targetInRange : false
  readonly property bool wifiEnabled: root.hostWidget ? root.hostWidget.wifiEnabled : false
  readonly property int signal: root.hostWidget ? root.hostWidget.targetSignal : -1
  readonly property bool connectedToTarget: root.hostWidget ? root.hostWidget.isConnectedToTarget : false
  readonly property var availableNetworks: root.hostWidget ? root.hostWidget.availableNetworks : []
  readonly property string connectedSsid: root.hostWidget && root.hostWidget.connectedNetwork
    ? root.hostWidget.connectedNetwork.name : ""
  readonly property string resultMessage: root.hostWidget ? root.hostWidget.resultMessage : ""
  readonly property bool resultIsError: root.hostWidget ? root.hostWidget.resultIsError : false
  readonly property bool canAttempt: root.hostWidget ? root.hostWidget.canAttempt : false

  readonly property color statusColor: {
    if (root.statusText === "connected") return root.okColor
    if (root.statusText === "no signal" || root.statusText === "no NetworkManager") return root.danger
    if (root.statusText === "connecting…") return root.dim
    return root.warn
  }

  readonly property string signalText: root.signal >= 0 ? root.signal + "%" : "—"
  readonly property bool resultVisible: root.resultMessage !== ""

  // The passphrase lives only in this field and is handed straight to the NM
  // client. It is never stored on the widget, echoed to the bar, logged, or
  // passed as an argument.
  property string passphrase: ""
  readonly property bool canSubmit: root.canAttempt && root.passphrase.length >= 8

  readonly property string connectLabel: root.busy ? "CONNECTING…" : "CONNECT"

  function open() { root.controller.show() }
  function close() { root.controller.hide() }

  // On-screen geometry of the popup card, used to generate the README preview.
  // KeyboardPanel is a full-screen transparent layer-shell window, so the
  // window's own x/y/width/height are the whole monitor. The visible card is
  // the BorderSurface placed at `cardOrigin` with `contentWidth/Height`, which
  // the base component already computes in logical screen coordinates.
  function geometry() {
    return {
      x: Math.round(popup.cardOrigin.x),
      y: Math.round(popup.cardOrigin.y),
      width: Math.round(popup.contentWidth),
      height: Math.round(popup.contentHeight)
    }
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function submit() {
    if (!root.canSubmit) return
    var pw = root.passphrase
    root.passphrase = ""
    if (root.hostWidget && typeof root.hostWidget.connectWithPassphrase === "function") {
      root.hostWidget.connectWithPassphrase(pw)
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The passphrase field owns typing while the panel is up; Esc closes.
      onCloseRequested: {
        root.passphrase = ""
        root.close()
      }
      onReturnRequested: root.submit()
      onActivateRequested: root.submit()
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "WiFi Force Connector"
        meta: root.ssid
        detail: root.statusText.toUpperCase()
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      // ---- reason we can't connect (or a quiet success line) ------------
      Text {
        width: parent.width
        text: {
          if (root.resultVisible) return root.resultMessage
          if (!root.wifiEnabled) return "Wi-Fi is switched off — turn the radio on first"
          if (!root.inRange) return "Can't see " + root.ssid + " — bring the modem closer"
          if (root.statusText === "on other net")
            return "Connected to " + root.connectedSsid + ", not " + root.ssid
          return ""
        }
        color: root.resultIsError ? root.danger
          : (root.statusText === "on other net" ? root.warn : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        visible: text !== ""
      }

      // ---- network picker -------------------------------------------------
      // Only shown when the target is ambiguous (nothing chosen yet). An
      // explicit pick is remembered by the bar widget.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.availableNetworks.length > 1 && root.hostWidget
          && root.hostWidget.savedSsid === "" && root.hostWidget.ssidOverride === ""

        Text {
          width: parent.width
          text: "CHOOSE A NETWORK"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Repeater {
          model: root.availableNetworks.slice(0, 6)

          delegate: Button {
            required property var modelData
            width: parent ? parent.width : implicitWidth
            leftAlign: true
            text: modelData.ssid
            iconText: modelData.connected ? "✓" : (modelData.secured ? "\uf023" : "\uf05b")
            foreground: root.foreground
            focusable: true
            selected: modelData.ssid === root.ssid
            onClicked: {
              root.passphrase = ""
              if (root.hostWidget && typeof root.hostWidget.selectTarget === "function")
                root.hostWidget.selectTarget(modelData.ssid)
            }
          }
        }
      }

      // ---- passphrase ---------------------------------------------------
      TextField {
        id: pwField
        width: parent.width
        password: true
        placeholderText: "Passphrase"
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        enabled: !root.busy
        text: root.passphrase
        onTextChanged: root.passphrase = text
        onAccepted: root.submit()
        Keys.onEscapePressed: {
          root.passphrase = ""
          root.close()
        }
        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
        Component.onCompleted: Qt.callLater(forceActiveFocus)
      }

      Text {
        width: parent.width
        text: "Creates or replaces the saved profile for " + root.ssid
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }

      // ---- the big one ---------------------------------------------------
      Button {
        id: connectButton
        width: parent.width
        height: Style.space(56)
        text: root.connectLabel
        iconText: root.busy ? "" : "\uf0ac"
        iconSpinning: root.busy
        iconSize: Style.font.title
        fontSize: Style.font.title
        foreground: root.foreground
        background: root.connectedToTarget
          ? "transparent" : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        accent: root.foreground
        focusable: true
        // 8-char WPA minimum, plus a real radio+AP. Disabled reads as dead
        // rather than silently failing on click.
        enabled: root.canSubmit
        opacity: root.canSubmit ? 1.0 : 0.45
        onClicked: root.submit()
      }

      Button {
        id: forgetButton
        width: parent.width
        text: root.busy ? "Forgetting…" : "Forget saved profile"
        iconText: "\uf1f8"
        foreground: root.dim
        focusable: true
        enabled: !root.busy
        onClicked: {
          if (root.hostWidget && typeof root.hostWidget.forgetAndRescan === "function")
            root.hostWidget.forgetAndRescan()
        }
      }

      PanelSeparator {
        foreground: root.foreground
      }

      // ---- state rows ----------------------------------------------------
      Column {
        width: parent.width
        spacing: Style.space(8)

        InfoPair {
          label: "Status"
          value: root.statusText
          valueColor: root.statusColor
        }
        InfoPair {
          label: "Signal"
          value: root.signalText
        }
        InfoPair {
          label: "Radio"
          value: root.wifiEnabled ? "on" : "off"
          valueColor: root.wifiEnabled ? root.foreground : root.danger
        }
        InfoPair {
          label: "Connected to"
          value: root.connectedSsid !== "" ? root.connectedSsid : "nothing"
        }
      }

      Text {
        width: parent.width
        text: "Passphrase goes straight to NetworkManager — never to argv or a log."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Text {
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      Layout.fillWidth: true
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
    }
  }
}
