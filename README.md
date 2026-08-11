# Wi-Fi Sniffer & Debug Setup: Raspberry Pi 5 + Alfa AWUS036AXML

**Hardware:** Raspberry Pi 5 (4 GB or 8 GB) · Alfa AWUS036AXML (MT7921AUN, Wi-Fi 6E)  
**OS:** Raspberry Pi OS (64-bit)  
**Document version:** August 2026

---

## Table of Contents

### Setup Guide

1. [Hardware Overview](#1-hardware-overview)
2. [Installing Raspberry Pi OS](#2-installing-raspberry-pi-os)
3. [First Boot & Connection](#3-first-boot--connection)
4. [Run the Setup Script](#4-run-the-setup-script)
5. [Verify the Setup](#5-verify-the-setup)
6. [Set the Capture Channel](#6-set-the-capture-channel) — `mon0-set-channel`

### Usage Guide

1. [Install Wireshark on Windows](#1-install-wireshark-on-windows)
2. [Remote Capture with wifidump — Easiest](#2-remote-capture-with-wifidump----easiest)
3. [Local Capture on the RPi5 — Advanced](#3-local-capture-on-the-rpi5----advanced)
4. [Decrypt Wi-Fi Frames](#4-decrypt-wi-fi-frames)
5. [Throughput Testing — iperf2 and iperf3](#5-throughput-testing--iperf2-and-iperf3)
6. [AP Mode + Simultaneous Capture](#6-ap-mode--simultaneous-capture)
7. [Channel Scan & Survey](#7-channel-scan--survey)
8. [RPi Connect — Register Your Device (Optional)](#8-rpi-connect--register-your-device-optional)
9. [Quick-Reference Cheat Sheet](#9-quick-reference-cheat-sheet)

---

## Part 1 — Setup Guide

> Follow this part once to set up the RPi5 and Alfa adapter as a Wi-Fi sniffer.

---

## 1. Hardware Overview

### Raspberry Pi 5

- Quad-core Arm Cortex-A76 @ 2.4 GHz, PCIe 2.0, USB 3.0 × 2, USB 2.0 × 2
- Built-in Wi-Fi: BCM43455 (2.4 / 5 GHz, 802.11ac) — used for internet / management
- Requires a **27 W USB-C PD** power supply (5 V / 5 A)
- microSD card: **32 GB class 10 / A1 minimum**; 64 GB+ recommended

### Alfa AWUS036AXML

| Property | Value |
| ---------- | ------- |
| Chipset | MediaTek MT7921AUN |
| Kernel driver | `mt7921u` (in-kernel since Linux 5.18) |
| Bands | 2.4 GHz · 5 GHz · 6 GHz (Wi-Fi 6E) |
| USB | USB 3.0 (SuperSpeed) |
| Monitor mode | Yes – kernel-native, no patches needed |
| Packet injection | Yes |
| VIF support | Yes – AP + monitor simultaneously on one adapter |
| Power draw | Up to 2.7 W — **use a powered USB hub** if the RPi5 shows under-voltage warnings |

> **Tip:** The RPi5 USB 3.0 ports can supply up to 1.2 A per port when using the official 27 W PSU. The AWUS036AXML peak draw is within spec, but a powered hub removes all doubt.

---

## 2. Installing Raspberry Pi OS

### 2.1 Download Raspberry Pi Imager

Download the Raspberry Pi Imager for your host computer from:  
**<https://www.raspberrypi.com/software/>**

Install and launch it on Windows, macOS, or Linux.

> On Linux: `sudo apt install rpi-imager`

### 2.2 Flash the SD Card

1. Insert your microSD card into your computer.
2. In Raspberry Pi Imager, click **Choose Device** → select **Raspberry Pi 5**.
3. Click **Choose OS** → **Raspberry Pi OS (other)** → **Raspberry Pi OS Lite (64-bit)** (headless).  
   The Desktop image is not required — all capture and testing workflows use SSH and tshark.
4. Click **Choose Storage** → select your microSD card.
5. Click **Next**.

### 2.3 Customise Settings

When prompted *"Would you like to apply OS customisation settings?"* click **Edit Settings**.

Configure your credentials and preferences:

| Tab | Setting | Recommended value |
| ----- | --------- | ------------------- |
| General | Hostname | `wifi-sniffer` |
| General | Username | your username |
| General | Password | your password |
| General | Wi-Fi SSID / Password | your home/lab network (or leave blank and use Ethernet) |
| General | Locale / Timezone | your region |
| Services | Enable SSH | ✓ Use password authentication |
| Services | Enable Raspberry Pi Connect | ✓ Recommended, follow instructions |

> Both SSH and RPi Connect will be available after first boot. RPi Connect requires linking your Raspberry Pi account first — see Part 2, Section 8.

Click **Save**, then **Yes** to apply. Click **Yes** to erase and write.

The flash + verify takes roughly 5–10 minutes.

---

## 3. First Boot & Connection

### 3.1 Physical Setup

1. Eject the SD card from your computer and insert it into the **microSD slot on the underside** of the RPi5.
2. Plug the Alfa AWUS036AXML into a **blue USB 3.0 port**.
3. Connect an Ethernet cable to your router or switch.
4. Connect the USB-C power supply.
5. The green LED will flicker during first boot — allow 2–3 minutes for the system to be ready.

> **Ethernet** is recommended during setup to ensure internet access is unaffected if Wi-Fi settings are changed.

### 3.2 Connect via RPi Connect

If you enabled RPi Connect in the Imager settings, you can access the RPi5 from any browser without knowing its IP address:

1. Go to **<https://connect.raspberrypi.com>** and sign in with your Raspberry Pi account.
2. Select your device (`wifi-sniffer`).
3. Choose **Remote shell** to open a terminal.

Once connected, note the IP address — you will need it later for SSH and wifidump:

```bash
hostname -I
```

> RPi Connect requires the device to have internet access (via Ethernet or Wi-Fi) and your Raspberry Pi account to be linked — see Part 2, Section 8 for the linking step.

### 3.3 Connect via SSH

Find the RPi5 IP address from your router's DHCP client list (look for hostname `wifi-sniffer`). Then SSH in from your computer:

```bash
ssh <username>@<ip-address>
```

> **Tip:** If your local network supports mDNS (Bonjour/Avahi — enabled by default on macOS and most Linux distros; on Windows install "Bonjour Print Services" or use it via iTunes/Chrome), you can use the hostname instead of hunting for the IP address:
>
> ```bash
> ssh <username>@wifi-sniffer.local
> ```
>
> This works anywhere an IP address is used in this guide (SSH, `scp`, wifidump's "Remote SSH server address"), as long as the hostname was kept as `wifi-sniffer` in Section 2.3.

Verify internet connectivity:

```bash
ping -c 4 8.8.8.8
```

---

## 4. Run the Setup Script

All remaining build steps are automated by `setup-wifi-sniffer.sh`. The script handles package installation, Wireshark permissions, NetworkManager configuration, the `wlan1-monitor` systemd service, the persistent capture channel, iperf persistent services, and AP mode pre-configuration.

### 4.1 Get the Script onto the RPi5

**Option A — download directly on the RPi5** (works from RPi Connect terminal or SSH, no file transfer needed):

```bash
curl -sSO https://raw.githubusercontent.com/uffea/wifi_sniffer_setup/main/setup-wifi-sniffer.sh
```

**Option B — copy from your computer over SSH:**

Open a terminal and navigate to the folder where `setup-wifi-sniffer.sh` is saved, then run:

```bash
cd C:\path\to\folder          # Windows (Command Prompt / PowerShell)
# or
cd ~/path/to/folder            # macOS / Linux

scp setup-wifi-sniffer.sh <username>@<rpi-ip>:~/
```

### 4.2 Run the Script

SSH into the RPi5 and run:

```bash
chmod +x setup-wifi-sniffer.sh
./setup-wifi-sniffer.sh
```

> The script will prompt for your `sudo` password at the start. During installation, accept any questions that appear (e.g. iperf3 daemon setup) by pressing **Enter** or selecting **Yes**.

Everything the script prints is also written to `~/setup-wifi-sniffer-<timestamp>.log`, so if the session drops partway through (see the RPi Connect note below), the log on disk still shows exactly how far it got.

> **Running over Raspberry Pi Connect?** Upgrading `rpi-connect` itself restarts the service that carries a Connect remote shell, which silently drops the connection — and this script — mid-upgrade. The script holds `rpi-connect`/`rpi-connect-lite` back for the duration of Step 1's `apt full-upgrade` and unholds them right after, specifically so this can't happen; it will tell you at the end how to update Connect separately over a plain SSH session. That protects against Connect's own restart, but a long `apt` run can restart other services too — for extra safety, run the script inside `tmux new -s setup` so you can reattach if anything drops it:
>
> ```bash
> tmux new -s setup
> ./setup-wifi-sniffer.sh
> # if the connection drops: reconnect, then `tmux attach -t setup`
> ```

The script runs through 7 steps and prints progress as it goes:

| Step | What it does |
| ------ | ------------- |
| 1 | System update, package install (holding back `rpi-connect` during the upgrade if installed), `dumpcap` capabilities, `iw` wrapper, sudoers entry for wifidump |
| 2 | Enables NetworkManager's Wi-Fi radio (so `wlan0` can scan), excludes `wlan1` and `ap0` from NetworkManager and dhcpcd permanently |
| 3 | Creates and enables the `wlan1-monitor` service (creates `mon0` at boot) |
| 4 | Creates and enables `iperf2-tcp`, `iperf2-udp`, and `iperf3` as persistent services |
| 5 | Writes `hostapd` and `dnsmasq` config files plus the `ap-enable` / `ap-disable` helpers (AP not started) |
| 6 | Installs `mon0-set-channel` and the `wlan1-monitor-channel` service so the capture channel persists across reboots (default: channel 36) |
| 7 | Runs a verification checklist and prints pass/fail for each component |

**Interface assignment after the script completes:**

| Interface | Adapter | Role |
| ----------- | --------- | ------ |
| `wlan0` | Built-in RPi5 BCM43455 | Normal Wi-Fi — internet, SSH, management |
| `wlan1` | Alfa AWUS036AXML | Base interface — neutral managed, never captured directly |
| `mon0` | Alfa AWUS036AXML (VIF) | Permanent monitor capture interface |

### 4.3 Reboot

```bash
sudo reboot
```

Required for the `wireshark` group membership to take effect.

---

## 5. Verify the Setup

After the reboot in Section 4.3, run these checks to confirm everything is working:

```bash
# Should show wlan0, wlan1 (managed), and mon0 (monitor) on channel 36
iw dev

# Both should show active (exited)
systemctl status wlan1-monitor wlan1-monitor-channel

# Should show active (running)
systemctl status iperf2-tcp iperf2-udp iperf3
```

If any service is not active, try restarting it:

```bash
sudo systemctl restart wlan1-monitor wlan1-monitor-channel
```

> **Once all checks pass**, the RPi5 is ready to use. Section 6 below covers changing the capture channel; Part 2 covers the capture and testing workflows.

---

## 6. Set the Capture Channel

`mon0` comes up on the channel stored in `/etc/wifi-sniffer/mon0-channel.conf` (default: **channel 36**). The `wlan1-monitor-channel` service applies that file on every boot, so the channel survives reboots and adapter re-plugs — you only need to change it when you want to capture somewhere else.

Use the `mon0-set-channel` helper for every channel change:

```bash
sudo mon0-set-channel 36              # 5 GHz  — channel number
sudo mon0-set-channel 6               # 2.4 GHz — channel number
sudo mon0-set-channel freq 6135       # 6 GHz  — control frequency in MHz, 20 MHz wide
sudo mon0-set-channel freq 6135 40    # 40 MHz wide — centre frequency derived for you
sudo mon0-set-channel                 # re-apply whatever is already in the conf file
sudo mon0-set-channel --help           # all forms
```

The helper writes your choice into the conf file **and** applies it immediately, so the new channel is live now *and* after the next reboot. 

### 6.1 6 GHz Needs a Frequency, Not a Channel Number

`iw` resolves a plain channel number to 5 GHz — `set channel 37` gives you 5 GHz channel 37, not 6 GHz. For 6 GHz always use the `freq` form with the frequency in MHz.

| 6 GHz channel | Frequency (MHz) |
| --------------- | ----------------- |
| 1 | 5975 |
| 37 | 6135 |
| 45 | 6175 |
| 53 | 6215 |

These are the preferred scanning channels (PSCs) — the ones 6 GHz clients probe first, so they are the most productive channels to sit on.

> **20 MHz bandwidth is the right default for sniffing.** A wider capture interface does not show you more frames — it only changes how the radio reports the channel, and on a busy band it costs sensitivity. Use 20 MHz unless you are specifically investigating wide-channel behaviour.

> **Regulatory domain:** 5 GHz and 6 GHz need a country code set. If a channel is rejected, run `sudo raspi-config nonint do_wifi_country SE` (substitute your own code) and reboot.

### 6.2 Editing the Config File Directly

Equivalent to using the helper with an argument — useful if you prefer to see all the settings at once:

```bash
sudo nano /etc/wifi-sniffer/mon0-channel.conf
sudo mon0-set-channel                 # apply the edit
```

`CHANNEL` is a plain channel number; `FREQ` is a control frequency in MHz and takes precedence over `CHANNEL` when both are set. Comment one out to use the other. `FREQ_WIDTH` defaults to 20; if you set it higher, also set `FREQ_CENTRE` — or just use the helper, which fills it in.

---

## Part 2 — Usage Guide

> Start here after completing the Part 1 setup. This part covers all capture and testing workflows.

---

## 1. Install Wireshark on Windows

1. Download the Wireshark 4.x installer from [wireshark.org](https://www.wireshark.org).
2. Run the installer.
3. On the **Choose Components** screen, ensure **Extcap Plugins** is checked — this includes `wifidump`, the plugin used for remote Wi-Fi capture.
4. Complete the installation.

**Ensure OpenSSH Client is installed on Windows:**  
Settings → System → Optional Features → search for "OpenSSH Client" → Install if not present. This is required by `wifidump` to connect to the RPi5.

**Verify wifidump is present:**  
Open Wireshark and look for **"Wi-Fi remote capture"** in the interface list on the start screen. If it appears, wifidump is installed and ready.

If it is missing:

- Re-run the Wireshark installer → **Modify** → **Choose Components → Extcap Plugins** → ensure **Wifidump** is checked.

---

## 2. Remote Capture with wifidump -- Easiest

`wifidump` is a Wireshark 4.x extcap plugin purpose-built for remote Wi-Fi (802.11) capture over SSH. It works on **Windows, macOS, and Linux** and handles channel selection through the Wireshark GUI — no commands needed on the RPi5 before connecting.

> **wifidump is strictly for Wi-Fi capture.** If you need to capture other network technologies remotely (Bluetooth, 802.15.4, Ethernet etc.), look into the `sshdump` extcap plugin, which is a general-purpose remote SSH capture tool included with the same Wireshark installation.

### Live Remote Capture

1. In Wireshark, look for **"Wi-Fi remote capture"** in the interface list.
2. Click the **gear icon** next to it.
3. Configure:
   - **Remote SSH server address:** `<rpi-ip>` or `wifi-sniffer.local`
   - **Remote SSH username:** the username from the image
   - **Remote SSH password:** the password from the image
   - **Remote interface:** `mon0`
   - **Channel / frequency:** a channel number within the band `mon0` is already on. To move to a different band, pre-set it with `sudo mon0-set-channel` first (Part 1, Section 6) — wifidump cannot do a cross-band switch itself.
4. Click **Start**.

wifidump connects over SSH, sets the channel on `mon0`, and streams frames live into Wireshark. Since `mon0` is already in monitor mode via the systemd service set up in Part 1, Section 4, wifidump will find it ready and proceed without needing to reconfigure it.

### 2.1 6 GHz Capture

wifidump passes its channel field straight to `iw set channel`, which always resolves a plain number like 37 to 5 GHz. So for 6 GHz, set the frequency on the RPi first and let wifidump's own channel step fail harmlessly.

**Step 1 — Pre-set `mon0` on the RPi** (see Part 1, Section 6):

```bash
sudo mon0-set-channel freq 6135
```

**Step 2 — Start wifidump** and enter the same frequency in MHz in the channel field (e.g. `6135`). wifidump's channel-set step fails silently on the invalid channel number, leaving `mon0` exactly where you pre-set it.

**Switching back to 2.4 or 5 GHz** afterwards is a single command — no interface juggling needed:

```bash
sudo mon0-set-channel 36              # 5 GHz channel 36
```

---

## 3. Local Capture on the RPi5 -- Advanced

All capture on the RPi5 is done via `tshark` over SSH. `mon0` is already in monitor mode — no setup needed. Set the desired channel with `sudo mon0-set-channel` (Part 1, Section 6), then capture to a `.pcapng` file and retrieve it to your Windows machine for analysis in Wireshark.

### 3.1 Capture to File

```bash
# Set channel, then capture to a timestamped file
sudo mon0-set-channel 36
tshark -i mon0 -w ~/capture_$(date +%Y%m%d_%H%M).pcapng
```

No `sudo` or `-I` flag needed — `mon0` is already in monitor mode and `dumpcap` has the required capabilities from Part 1, Section 4.

To capture for a fixed duration:

```bash
tshark -i mon0 -a duration:60 -w ~/cap_ch36.pcapng
```

### 3.2 Useful Capture Filters

Pass with `-f` to reduce file size by filtering at capture time:

| Purpose | Filter |
| --------- | -------- |
| Only a specific BSSID | `wlan addr2 aa:bb:cc:dd:ee:ff` |
| Only beacon frames | `wlan[0] == 0x80` |
| EAPOL handshakes only | `ether proto 0x888e` |

```bash
tshark -i mon0 -f "ether proto 0x888e" -w ~/handshake.pcapng
```

### 3.3 Retrieve the Capture File

Copy the file to your Windows machine for analysis in Wireshark:

```bash
scp <username>@<rpi-ip>:~/cap_ch36.pcapng ~/Desktop/
```

### 3.4 Wireshark Display Filters (on Windows)

Once the `.pcapng` is open in Wireshark on your Windows machine, use these in the **Display Filter** bar:

| Purpose | Filter |
| --------- | -------- |
| Only 802.11 management frames | `wlan.fc.type == 0` |
| Only beacon frames | `wlan.fc.type_subtype == 8` |
| Only probe requests | `wlan.fc.type_subtype == 4` |
| Only data frames | `wlan.fc.type == 2` |
| Specific BSSID | `wlan.bssid == aa:bb:cc:dd:ee:ff` |
| Specific client | `wlan.addr == aa:bb:cc:dd:ee:ff` |
| Exclude beacons | `!(wlan.fc.type_subtype == 8)` |
| WPA handshake only | `eapol` |

---

## 4. Decrypt Wi-Fi Frames

When you have the WPA2/WPA3 passphrase (or per-session keys), Wireshark can decrypt the data payload of captured frames.

### 4.1 Requirements

- You **must capture the 4-way EAPOL handshake** of the client session you want to decrypt. This means the capture must start **before** the client associates (or you must deauth + re-auth the client while capturing).
- The adapter must be on the **same channel** as the target AP.

> For WPA3-SAE, the handshake is a Simultaneous Authentication of Equals (SAE) commit/confirm exchange. Wireshark 4.x supports SAE decryption with the passphrase.

### 4.2 Add Decryption Keys in Wireshark

1. **Edit → Preferences → Protocols → IEEE 802.11**
2. Check **"Enable decryption"**
3. Click **Edit** next to Decryption Keys
4. Click **+** (Add)
5. Select key type and enter the key:

| Key Type | Format | When to use |
| ---------- | -------- | ------------- |
| `wpa-pwd` | `passphrase:SSID` | You know the Wi-Fi password — this is the normal case. Wireshark derives the PSK internally. |
| `wpa-psk` | 64-character hex PSK | You have the raw hex PSK rather than the password (e.g. copied from a router config), or the password contains special characters that confuse the `wpa-pwd` parser. |
| `wpa-tk` | Temporal Key (hex) | You do not have the password at all, but have extracted the per-session TK from supplicant debug logs. Does not require the EAPOL handshake to be in the capture. |

**In practice:** use `wpa-pwd` for any network where you know the password — it is the simplest and works for the vast majority of cases. Use `wpa-psk` only if `wpa-pwd` fails to decrypt (which can happen with passwords containing colons or non-ASCII characters, since the colon is the separator between passphrase and SSID). `wpa-tk` is rarely needed outside of firmware or driver debugging.

1. Click **OK** → **OK**.

### 4.3 Derive the PSK (for wpa-psk entry)

```bash
wpa_passphrase "MyNetwork" "MyPassword"
```

Copy the `psk=` value (64 hex characters) and use it as the `wpa-psk` key in Wireshark.

### 4.4 Verify Decryption

Once the pcapng file is loaded in Wireshark with the key configured:

- Data frames previously showing as **TKIP** or **CCMP (encrypted)** will decode to their actual protocol (TCP, UDP, DNS, HTTP, etc.)
- Apply display filter: `!wlan.fc.type_subtype == 8 && wlan.fc.type == 2` to see only decrypted data frames.
- Filter for a specific protocol: `http` or `dns` to inspect application layer traffic.

**Are the keys stored for future captures?**  
No — the decryption key (passphrase or PSK) you enter in Wireshark is stored in its preferences and reused automatically for every subsequent capture or file you open. However, the **EAPOL handshake frames must be present in each capture file** for Wireshark to derive the per-session keys. The passphrase alone is not enough — without the handshake in the pcapng, the data frames cannot be decrypted. For ongoing testing, either capture continuously from before the client connects, or start a new short capture each time the client reconnects.

---

## 5. Throughput Testing — iperf2 and iperf3

> **The iperf2 and iperf3 servers are already running as system services — no startup needed.** They were set up in Part 1, Section 4 and start automatically at every boot.

Two versions of iperf are in use:

| | iperf2 (`iperf`) | iperf3 |
| --- | --- | --- |
| **Default port** | 5001 | 5201 |
| **Zephyr zperf compatible** | ✓ Yes | ✗ No |
| **Protocol** | iperf2 wire protocol | Completely different rewrite |
| **Use for** | Zephyr / nRF device testing | Host-to-host testing (laptop ↔ RPi5) |

> **iperf2 and iperf3 are not interoperable.** They use incompatible protocols and cannot communicate with each other. Always use iperf2 (`iperf`) when the other endpoint is a Zephyr device running `zperf`. Additionally, iperf3 is known to produce unreliable UDP results over Wi-Fi (reported throughput can exceed actual link rate), making iperf2 the better choice for Wi-Fi UDP measurements in general.

### 5.1 iperf2 — Zephyr / zperf Testing

The TCP and UDP servers are both already running (ports 5001). Connect directly from your Zephyr device.

**From Zephyr shell on the nRF device:**

```text
zperf tcp upload <rpi-ip> 5001 10 1K 1M
zperf udp upload <rpi-ip> 5001 10 1K 1M
```

Format: `zperf <tcp|udp> upload <host> <port> <duration_s> <packet_size> <rate>`

**From any other client (manual iperf2 client):**

```bash
iperf -c <rpi-ip>        # TCP
iperf -c <rpi-ip> -u     # UDP
```

### 5.2 iperf3 — Host-to-Host Testing

Use iperf3 when both endpoints are Linux/Windows/macOS hosts (e.g. laptop testing throughput to the RPi5 AP). The server is already running on port 5201.

**From a client (laptop, phone, another Pi):**

```bash
iperf3 -c <rpi-ip>
```

---

## 6. AP Mode + Simultaneous Capture

The MT7921AUN chipset supports kernel-native virtual interfaces (VIF), allowing you to create both an AP and a monitor interface **on the same physical adapter simultaneously**. This makes it possible to:

- Advertise a Wi-Fi network (AP)
- Run iperf2/iperf3 clients through it
- Capture all 802.11 frames on the same channel with Wireshark/tshark

The hostapd and dnsmasq configuration files were created in Part 1, Section 4. This section covers runtime startup.

**Architecture:**

```text
AWUS036AXML (wlan1)  ← base interface, always managed
├── mon0    → permanent monitor interface (Wireshark/tshark, always present)
└── ap0     → AP virtual interface (add on demand, remove when done)

wlan0 (built-in RPi5)
└── managed → internet / SSH / management
```

### 6.1 Start the AP

```bash
sudo ap-enable
```

This creates the `ap0` VIF, assigns IP `192.168.99.1`, starts hostapd and dnsmasq, and enables NAT. `mon0` follows the AP onto its channel automatically — the MT7921 is a single-radio adapter, so both VIFs share one channel. While the AP is running, `mon0-set-channel` cannot move `mon0` independently; change `channel=` in `/etc/hostapd/hostapd-ap0.conf` and restart the AP instead. Verify with:

```bash
iw dev   # should show wlan1, mon0, and ap0
```

**To change AP settings** (SSID, passphrase, channel, or 802.11 mode), edit the config file and restart the AP:

```bash
sudo nano /etc/hostapd/hostapd-ap0.conf
sudo ap-disable && sudo ap-enable
```

The config file includes comments for every setting — see the band, channel, and 802.11 mode sections for guidance on switching between Wi-Fi generations or channels.

### 6.2 Run zperf Tests from a Zephyr Device

The iperf2 servers (port 5001) are already running on the RPi5. Connect the nRF device to **RPi5-TestAP**, confirm it has an IP address, then run zperf from the Zephyr shell:

```text
# Verify the device has an IP on the AP subnet (should be 192.168.99.x)
net iface

# TCP upload — 10 s, 1000-byte packets, target 1 Mbps
zperf tcp upload 192.168.99.1 5001 10 1K 1M

# UDP upload — 10 s, 1000-byte packets, target 1 Mbps
zperf udp upload 192.168.99.1 5001 10 1K 1M
```

Format: `zperf <tcp|udp> upload <host> <port> <duration_s> <packet_size> <rate>`

> If `net iface` shows no IP address, DHCP has not completed yet — wait a few seconds and check again, or confirm `CONFIG_NET_DHCPV4=y` is set in your project's Kconfig.

### 6.3 Capture Simultaneously

Open Wireshark in Windows on the same channel and start to see the Wi-Fi packet. Remember to start Wireshark monitoring before connecting with the device to decrypt the communication.

### 6.4 What mon0 Sees — AP Running vs. Stopped

The MT7921 hardware installs per-client session keys when a device authenticates with ap0. This changes what mon0 captures and what Wireshark can dissect.

| Condition | Hardware decryption | What mon0 sees | Wireshark result |
| ----------- | -------------------- | -------------------- | ----------------- |
| **ap0 stopped** | None | Encrypted frames (as on the air) | Protected=1, CCMP ciphertext — add WPA2 passphrase in Wireshark + capture EAPOL handshake to decrypt |
| **ap0 running, WPA2** | Active for ap0 clients | Protected=1 in header, but **plaintext payload** — hardware already decrypted | Dissector confused (expects ciphertext, sees plaintext) — set **"Ignore the Protection bit"** to **"Yes - with IV"** in Edit → Preferences → Protocols → IEEE 802.11 |
| **ap0 running, open (no WPA2)** | None (no encryption) | Plaintext frames | Correct dissection, no keys needed |

**Key points:**

- When ap0 is stopped, Wireshark's normal passphrase-based decryption works — but only if you captured the EAPOL 4-way handshake at client association time.
- When ap0 is running with WPA2, Wireshark's passphrase decryption does **not** work (there is no CCMP ciphertext left for it to decrypt). Use "Ignore the Protection bit" instead.
- Frames from **other BSSes** on the same channel (not your ap0 clients) are never hardware-decrypted regardless of ap0 state — Wireshark sees them as normal encrypted frames.
- Management frames (beacons, probe requests, association, EAPOL) are always unencrypted and fully visible in both modes.

For throughput testing where payload content matters, an open AP (no WPA2) gives the cleanest captures. For testing WPA2 association behaviour, stop the AP after clients associate, then examine the handshake in the capture.

### 6.5 Stop the AP

```bash
sudo ap-disable
```

`mon0` remains in place and capture continues working normally after the AP is stopped. It stays on the AP's channel — run `sudo mon0-set-channel` to put it back on your configured channel.

> **Troubleshooting — disable monitor mode temporarily:** To free up the radio entirely (e.g. to use `wlan1` as a regular managed client):
>
> ```bash
> sudo systemctl stop wlan1-monitor
> sudo iw dev mon0 del
> ```
>
> To restore, start both services so `mon0` is recreated *and* put back on its configured channel:
>
> ```bash
> sudo systemctl start wlan1-monitor wlan1-monitor-channel
> ```

---

## 7. Channel Scan & Survey

### 7.1 Scan for Nearby Networks

`wlan1` cannot do active scans while `mon0` is active on the same radio. Use `wlan0` (the built-in adapter) instead:

```bash
# Active scan via built-in adapter
sudo iw dev wlan0 scan | grep -E "SSID|freq|signal|channel"
```

Or via NetworkManager (also uses wlan0):

```bash
nmcli dev wifi list
```

For a passive scan across all channels, use `airodump-ng` on `mon0` — see Section 7.2.

### 7.2 View Channel Utilisation with airodump-ng

`airodump-ng` shows all APs with their channel, BSSID, signal strength, and the number of clients — ideal for picking a clear channel. `mon0` is already in monitor mode so no setup is needed:

```bash
# Scan all channels (hop every 0.5s)
sudo airodump-ng mon0

# Scan only 5 GHz
sudo airodump-ng --band a mon0

# Scan only 2.4 GHz
sudo airodump-ng --band bg mon0

# Lock to one channel for deeper capture
sudo airodump-ng -c 6 mon0
sudo airodump-ng -c 36 mon0
```

> `airodump-ng` sets the channel itself, but it hits the same driver limitation as `iw`: it cannot move `mon0` to a different band while `wlan1` is UP. If a `-c` or `--band` option produces no frames, put `mon0` on that band first with `sudo mon0-set-channel` (Part 1, Section 6), then start `airodump-ng`.

The columns to watch:

| Column | Meaning |
| -------- | --------- |
| CH | Channel used by AP |
| PWR | Signal strength (higher negative = weaker) |
| Beacons | Frame count — confirms AP is active |
| #Data | Data frames seen |
| ENC | Encryption type |

### 7.3 Choosing a Good Channel for Measurements

**2.4 GHz (channels 1–13):**

- Only channels **1, 6, 11** are non-overlapping in 20 MHz mode.
- Pick the channel with the fewest APs and lowest beacon count from the airodump-ng scan.
- Avoid channels with high `#Data` counts (congested).

**5 GHz:**

- Far more non-overlapping channels available (36, 40, 44, 48, 52, 56 ... 149, 153, 157, 161).
- Prefer UNII-1 (36–48) for compatibility; UNII-3 (149–165) for minimal interference in residential areas.
- Check for DFS channels (52–144) — these may trigger radar detection causing channel switches.

**6 GHz (Wi-Fi 6E):**

- Channels 1–233 in 20 MHz increments — extremely low congestion in most environments.
- Excellent choice for clean baseline measurements.
- Requires client devices that support 6 GHz.

Compare total frame counts across channels to identify the quietest one, then make it the standing capture channel:

```bash
sudo mon0-set-channel 44          # or: sudo mon0-set-channel freq 6135
```

---

## 8. RPi Connect — Register Your Device (Optional)

The RPi Connect service is already installed and running (enabled via Raspberry Pi Imager in Part 1, Section 2).

### 8.1 Activate Connect

This is already done if it was included when the SD Image was created.

```bash
systemctl --user start rpi-connect
rpi-connect signin
```

This outputs a URL — open it in any browser, log in with your Raspberry Pi account, and the device is registered.

> For Raspberry Pi Connect to work, the RPi5 must have internet access — either via Ethernet or via the Wi-Fi credentials configured during OS install.

### 8.2 Access Your Pi Remotely

1. Go to **<https://connect.raspberrypi.com>** in any browser.
2. Sign in with your Raspberry Pi account.
3. Select your device.
4. Choose **Screen sharing** (full desktop) or **Remote shell** (terminal only).

> **Screen sharing** requires the Desktop version of Raspberry Pi OS. Lite (headless) only supports **Remote shell**.

### 8.3 Check Connection Status

```bash
rpi-connect status
```

### 8.4 Disable / Sign Out

```bash
rpi-connect signout
systemctl --user stop rpi-connect
```

---

## 9. Quick-Reference Cheat Sheet

```bash
# === INTERFACE MANAGEMENT ===
iw dev                                      # List all wireless interfaces and VIFs
iw phy phy1 info                            # Show adapter capabilities
sudo ip link set wlan1 up/down              # Bring base interface up/down

# === MONITOR INTERFACE (persistent via systemd — see Part 1, Section 4) ===
sudo systemctl start wlan1-monitor          # Create mon0 (normally auto at boot)
sudo systemctl stop wlan1-monitor           # Remove mon0
iw dev mon0 info                            # Show mon0's current channel / frequency

# === CAPTURE CHANNEL (persists across reboots — see Part 1, Section 6) ===
sudo mon0-set-channel 6                     # 2.4 GHz channel 6
sudo mon0-set-channel 36                    # 5 GHz channel 36
sudo mon0-set-channel freq 6135             # 6 GHz — MHz, 20 MHz wide (ch37)
sudo mon0-set-channel freq 6135 40          # 40 MHz wide — centre derived (6125)
sudo mon0-set-channel freq 6135 40 6125     # 40 MHz wide — explicit centre
sudo mon0-set-channel                       # Re-apply the configured channel
sudo mon0-set-channel --help                # All forms
# Widths >20 MHz REQUIRE a centre frequency — iw rejects "set freq 6135 40"
# Config file: /etc/wifi-sniffer/mon0-channel.conf

# === CAPTURE ===
tshark -i mon0 -w cap.pcapng               # Capture to file
tshark -i mon0 -a duration:60 -w cap.pcapng  # Capture for 60 seconds
tshark -i mon0 -f "ether proto 0x888e" -w handshake.pcapng  # EAPOL only
scp <user>@<rpi-ip>:~/cap.pcapng ~/Desktop/  # Retrieve on Windows

# === REMOTE CAPTURE ===
# Use wifidump extcap in Wireshark — remote interface: mon0 (see Section 2)

# === iperf2 (Zephyr zperf compatible) — server already running ===
iperf -c <ip>                               # TCP client, port 5001
iperf -c <ip> -u                            # UDP client, port 5001

# === iperf3 (host-to-host) — server already running ===
iperf3 -c <ip> -u -b 50M -t 30 -i 1       # UDP 50 Mbps, 30 sec
iperf3 -c <ip> -P 4 --bidir               # 4 parallel bidirectional

# === AP + MONITOR ===
sudo ap-enable                              # Start AP (ap0, 192.168.99.1, DHCP)
sudo ap-disable                             # Stop AP and remove ap0
# Edit AP config: sudo nano /etc/hostapd/hostapd-ap0.conf

# === CHANNEL SCAN ===
sudo airodump-ng mon0                       # Passive all-band scan (visual)
sudo airodump-ng --band a mon0             # 5 GHz only
sudo airodump-ng -c 36 mon0               # Lock to channel 36

# === RASPBERRY PI CONNECT ===
rpi-connect signin                          # Link device to your account
rpi-connect status                          # Check status
rpi-connect signout                         # Unlink account
# Access via: https://connect.raspberrypi.com
```
