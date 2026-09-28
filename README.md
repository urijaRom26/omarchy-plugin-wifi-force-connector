# WiFi Force Connector

A bar button for Omarchy that re-creates your WiFi profile from scratch with a
passphrase you type in — the one-click fix for a machine that is stuck
"disconnected" even though the modem is right there.

![WiFi Force Connector panel](preview.png)

## The problem it solves

NetworkManager stores a saved profile per WiFi network, including the
passphrase. When that stored passphrase goes stale — the ISP rotates the WiFi
password, you set a new one on the router, the profile got half-written — the
connection fails with:

```
psk mismatch reported by supplicant
state change: need-auth -> failed (reason 'no-secrets')
```

NetworkManager then asks for a new passphrase, but it asks through a secret
agent that only exists inside a running desktop session. From a script, a TTY,
or a headless context there is no agent, so it fails with `no-secrets` and
retries forever. The adapter looks fine (it still *sees* the network at full
signal) and no amount of retrying helps, because the problem is the stored
key, not the radio.

The normal fix is `nmcli device wifi connect "SSID" password "…"`, which
creates or overwrites the profile and activates it. This plugin puts that
behind one button.

## Install

```bash
omarchy plugin add https://github.com/urijaRom26/omarchy-plugin-wifi-force-connector
```

Then restart the shell if the widget does not appear:

```bash
omarchy restart shell
```

## Use

1. Click the globe button in your bar (it sits after the network icon by
   default).
2. If more than one network is in range, pick one — the choice is remembered.
3. Type the passphrase and press the big **CONNECT** button (or just hit
   Enter).

The button creates or replaces the profile and connects. If the passphrase is
wrong the panel says so and the field stays open for another try. There is also
a **Forget saved profile** button, which deletes the stale profile so the next
CONNECT builds a clean one. Right-clicking the bar icon does the same thing.

The bar button itself shows current state at a glance: ✓ when you are on the
target network, ! when you are not, … while a connection is in flight.

## Which network it targets

In order of precedence:

1. `WIFI_RESCUE_SSID` environment variable, if set.
2. The network you previously picked in the panel (remembered in
   `$XDG_STATE_HOME/urija.wifi-force-connector/ssid`).
3. The strongest encrypted network currently in range.

So it works with no configuration at all, and there is no hardcoded SSID in the
source.

## About the passphrase

The passphrase is handed straight to NetworkManager through Quickshell's
`Network.connectWithPsk()`. It is deliberately **never**:

- passed as a command-line argument (argv is world-readable in `/proc`)
- written to disk by the plugin
- written to any log or the shell journal
- accepted as an IPC argument over `omarchy shell`

Only NetworkManager's own root-owned keyfile under
`/etc/NetworkManager/system-connections/` holds the result, as it does for any
WiFi connection.

The plugin never runs anything as root and never asks for a password or an
elevated privilege prompt. It talks to NetworkManager over the same session bus
the desktop uses, exactly like the built-in network panel.

## The state file, and why it is written this way

The plugin remembers the network you picked in one file:

```
$XDG_STATE_HOME/urija.wifi-force-connector/ssid
```

That path is predictable, so any process running as you can create it, or
replace it with a symlink, at any moment. The write is therefore built so that
**the destination is never opened for writing at all**:

1. `statewriter.pl` creates a temp file in the same directory, named with
   `getpid()` (unpredictable) and mode `0600`, using
   `O_CREAT | O_EXCL | O_NOFOLLOW` — created fresh, and impossible to be a
   pre-planted symlink.
2. The payload is written through that **already-open descriptor**. The temp
   path is never re-resolved, so nothing can be swapped underneath it.
3. The file is closed, then `rename(2)` publishes it onto the destination.

`rename(2)` is a single atomic syscall on the final name, and it does **not**
follow a symlink — it replaces the symlink *itself*, leaving the link's target
untouched. That removes the check-then-write window entirely: there is no
earlier check whose result could disagree with what is written.

Reading the value is equally deliberate. `FileView` is not used at all — it
opens paths normally, so a planted symlink would let an attacker choose which
network name reaches `NetworkManager.connectWithPsk()`. The plugin reads via
`statewriter.pl --read`, which opens with `O_NOFOLLOW` and requires a plain
regular file; anything else yields "no saved choice" and the plugin falls back
to auto-detecting the strongest encrypted network in range.

**Ownership is not consent.** A regular file you own may hold unrelated data,
so a non-empty pre-existing file is refused rather than replaced — tracked by a
companion `.owned` marker created with the same `O_EXCL | O_NOFOLLOW`
discipline. When a write is refused the panel says so (`Not writing state: …`)
and the plugin keeps working by auto-detecting. Nothing is ever overwritten to
force it through.

If a write is refused, the connection itself is unaffected: the plugin
reconnects using the passphrase you typed, and only the *remembered* choice is
skipped.

### Two earlier bugs, for the record

- **v1.0.0** created the file with `install -D /dev/null`, which truncates
  whatever regular file already sits at the path.
- **v1.0.1** replaced that with a chain of `test -L` / `test -e` / `test -f` /
  `wc -c` guards before the write. That was still wrong: `test -f` *follows*
  symlinks, and every step re-resolved the pathname, so a symlink planted
  between the last check and the write turned the write into an
  arbitrary-file overwrite (TOCTOU).

Both were reported in
[issue #9145](https://github.com/omacom/omarchy-plugin-marketplace/issues/9145)
and are fixed in 1.1.0.

### Why a Perl helper?

The safe primitive here is `open(2)` with `O_CREAT | O_EXCL | O_NOFOLLOW`
followed by `rename(2)`. Quickshell's `Process` exposes no descriptor-relative
API for that, and the shell utilities either follow symlinks (`touch`, `>`,
`FileView`) or clobber existing data (`mv` without `-T`, `dd` without
`conv=notrunc`). `perl` is in the base Arch install and is the only thing
present that can do it in one atomic step per operation.

The payload travels over **stdin**, never argv, and is length-prefixed
(`<byte-length> <space> <bytes>`) because Quickshell's `Process.write()`
cannot close stdin — there is no `close()` and no EOF is delivered, so a helper
that read to EOF would block forever. The prefix is a **byte** count, so
non-ASCII SSIDs are stored intact.

The passphrase is never passed to this helper, or to any process, at all.

## Requirements

- NetworkManager (checked at runtime; the panel reports `no NetworkManager`
  rather than misbehaving)
- Quickshell's NetworkManager backend

## Troubleshooting

**The panel says "Can't see &lt;SSID&gt;".** The radio is associated but that
network is not in the scan results. The plugin turns the scanner on while the
panel is open; if the list is stale, close and reopen it.

**"Wrong password".** The handshake timed out authenticating. The field stays
open — type the current router password and press CONNECT again.

**Nothing happens when I click CONNECT.** The button is greyed out until the
passphrase is at least 8 characters (WPA's minimum) and a network is actually
in range. Both conditions are visible in the panel.

## Inspecting it headlessly

The widget exposes a status IPC for scripting and debugging:

```bash
omarchy shell urija.wifi-force-connector status
omarchy shell urija.wifi-force-connector select "MyNetwork"
omarchy shell urija.wifi-force-connector forget
```

## License

MIT — see [LICENSE](LICENSE).
