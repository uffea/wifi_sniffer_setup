#!/bin/bash
# =============================================================================
# Wi-Fi Sniffer Setup Script
# Raspberry Pi 5 + Alfa AWUS036AXML (MT7921AUN)
#
# Automates Part 1 of WiFi-Sniffer-RPi5-AWUS036AXML.md
# Run on a clean Raspberry Pi OS Bookworm (64-bit) as a regular user:
#
#   chmod +x setup-wifi-sniffer.sh
#   ./setup-wifi-sniffer.sh
#
# The script requires sudo — it will prompt for your password.
# Do NOT run it as root directly (sudo ./setup-wifi-sniffer.sh) —
# the script uses $USER to configure per-user settings (sudoers, wireshark group).
#
# Safe to re-run any time (idempotent) — re-running repairs missing/broken
# packages, permissions, and systemd services. It will NOT overwrite your
# hostapd/dnsmasq/mon0-channel config files if you've already customized them
# (delete a file first to reset it to the script's default).
# =============================================================================

set -uo pipefail

# Suppress all interactive prompts from apt/dpkg.
# Must be passed inline to sudo — sudo strips exported env vars by default.
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get"

# Detect the real user (handles both direct run and sudo invocation)
SCRIPT_USER=${SUDO_USER:-$USER}

# Helpers
die()  { echo ""; echo "  [FATAL] $*"; echo "  Aborting."; exit 1; }
warn() { echo "  [WARN]  $* — continuing"; }
ok()   { echo "  [OK]    $*"; }

# Trap unexpected exits and report the line number
trap 'echo ""; echo "  [FATAL] Script exited unexpectedly at line $LINENO"; exit 1' ERR

# Log everything to a file as well as the terminal. If the session drops with
# no visible error (see the rpi-connect note below), the log on disk still
# shows exactly how far the script got.
LOG_FILE="$HOME/setup-wifi-sniffer-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "============================================================"
echo " Wi-Fi Sniffer Setup"
echo " Target user: $SCRIPT_USER"
echo " Logging to:  $LOG_FILE"
echo "============================================================"
echo ""

# Best-effort: is this shell itself running inside a Raspberry Pi Connect
# remote shell? Advisory only — a miss just skips the extra warning below.
running_via_rpi_connect() {
    local pid=$$ ppid
    for _ in 1 2 3 4 5 6 7 8; do
        [ -z "$pid" ] || [ "$pid" -le 1 ] && return 1
        if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qi 'rpi-connect'; then
            return 0
        fi
        ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
        [ -z "$ppid" ] && return 1
        pid=$ppid
    done
    return 1
}

if running_via_rpi_connect; then
    echo "  [NOTE]  This shell looks like a Raspberry Pi Connect remote shell."
    echo "          Upgrading rpi-connect restarts the service that carries this"
    echo "          session, which drops the connection with no error message —"
    echo "          the script's own rpi-connect protection (below) covers that"
    echo "          specific case, but any other service restart during a long"
    echo "          apt run could still disconnect you. For extra safety, run this"
    echo "          script inside 'tmux new -s setup' and reattach if it drops."
    echo ""
fi

# =============================================================================
# STEP 1 — System Update & Package Installation
# =============================================================================
echo "--- [1/7] System Update & Package Installation ---"

# Hold rpi-connect back for the duration of the upgrade.
#
# Raspberry Pi's own troubleshooting docs confirm this: upgrading
# rpi-connect/rpi-connect-lite restarts the Connect service mid-upgrade. If
# this script is running inside a Connect remote shell, that restart kills
# the shell — and this script — with no error message, because the session
# dies with the service, not because of a script error. Holding the package
# during 'full-upgrade' lets everything else upgrade normally without ending
# the session it's running in; it's unheld again immediately below.
CONNECT_PKGS=$(dpkg -l rpi-connect rpi-connect-lite 2>/dev/null | awk '/^ii/{print $2}')
if [ -n "$CONNECT_PKGS" ]; then
    # shellcheck disable=SC2086
    sudo apt-mark hold $CONNECT_PKGS > /dev/null
    ok "Held back $CONNECT_PKGS for this upgrade (its own upgrade restarts the service and can kill a Connect remote shell mid-script)"
fi

$APT update || die "apt update failed — check network connectivity"
$APT full-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  || die "apt full-upgrade failed"

if [ -n "$CONNECT_PKGS" ]; then
    # shellcheck disable=SC2086
    sudo apt-mark unhold $CONNECT_PKGS > /dev/null
    echo "  [NOTE]  $CONNECT_PKGS was held back during the upgrade above so its"
    echo "          own restart could not drop this session mid-script. It is not"
    echo "          upgraded yet. Update it over a PLAIN SSH session — not this"
    echo "          Connect remote shell — so a restart mid-upgrade cannot drop"
    echo "          the very connection running the command:"
    echo "            ssh $SCRIPT_USER@<rpi-ip>"
    echo "            sudo apt update && sudo apt install --only-upgrade $CONNECT_PKGS"
    echo "          If you must do it over Connect, wrap it: tmux new -s upgrade"
fi

# Pre-accept interactive prompts before installing packages
echo "wireshark-common wireshark-common/install-setuid boolean true" \
  | sudo debconf-set-selections
echo "iperf3 iperf3/daemon boolean true" \
  | sudo debconf-set-selections 2>/dev/null || true

$APT install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  iw wireless-tools net-tools \
  aircrack-ng \
  wireshark tshark \
  iperf iperf3 \
  tcpdump \
  hostapd dnsmasq \
  iptables \
  firmware-misc-nonfree \
  git curl \
  || die "Package installation failed"

# Add user to wireshark group so tshark works without sudo
if getent group wireshark > /dev/null; then
    sudo usermod -aG wireshark "$SCRIPT_USER"
    ok "Added $SCRIPT_USER to wireshark group"
else
    warn "wireshark group not found — tshark may require sudo"
fi

# Grant dumpcap raw socket capabilities
DUMPCAP_PATH=$(command -v dumpcap 2>/dev/null \
  || { [ -x /usr/bin/dumpcap ] && echo /usr/bin/dumpcap; } \
  || true)
[ -z "$DUMPCAP_PATH" ] && die "dumpcap not found — wireshark-common may not have installed correctly"
sudo setcap cap_net_raw,cap_net_admin=eip "$DUMPCAP_PATH" \
  || die "setcap on dumpcap failed"

# /usr/local/bin/iw — iw wrapper that suppresses EBUSY ("resource busy").
#
# When wifidump calls 'sudo iw dev mon0 set channel X' while the AP (ap0) is
# running, iw exits non-zero with "command failed: Device or resource busy".
# That error text gets piped to Wireshark instead of pcapng data, causing the
# "magic = 0x6d6d6f63" error. The fix: intercept 'sudo iw' via a wrapper at
# /usr/local/bin/iw — sudo's secure_path puts /usr/local/bin before /usr/sbin,
# so 'sudo iw' resolves to this wrapper rather than the real binary.
# EBUSY is safe to ignore: ap0 already owns the PHY channel, and mon0 follows
# it automatically. All other errors are passed through unchanged.
sudo tee /usr/local/bin/iw > /dev/null <<'IWEOF'
#!/bin/bash
output=$(/usr/sbin/iw "$@" 2>&1)
ret=$?
if [ $ret -ne 0 ] && echo "$output" | grep -qE "resource busy|Invalid argument"; then
    # resource busy:     AP (ap0) owns the PHY channel — mon0 already on correct channel.
    # Invalid argument:  wifidump passed a 6 GHz frequency (MHz) as a channel number
    #                    (e.g. "set channel 6135"). Pre-set the frequency with
    #                    'sudo mon0-set-channel freq <MHz>' before starting
    #                    wifidump and enter the MHz value as the channel in Wireshark.
    exit 0
fi
[ -n "$output" ] && echo "$output" >&2
exit $ret
IWEOF
sudo chmod +x /usr/local/bin/iw

# sudoers drop-in for wifidump extcap — allows the plugin to run iw/ip/dumpcap/tcpdump
# over SSH without a password prompt.
# Lists /usr/local/bin/iw (the wrapper) so 'sudo iw' is permitted without a
# password. Scripts that call /usr/sbin/iw directly (ap-enable, wlan1-monitor)
# run as root via sudo and are unaffected.
# tcpdump is listed alongside dumpcap: dumpcap+setcap already lets any user
# capture without sudo, so this NOPASSWD entry only matters if something here
# invokes 'sudo tcpdump' directly instead.
IP_PATH=$(command -v ip 2>/dev/null || { [ -x /usr/sbin/ip ] && echo /usr/sbin/ip; } || true)
TCPDUMP_PATH=$(command -v tcpdump 2>/dev/null || { [ -x /usr/bin/tcpdump ] && echo /usr/bin/tcpdump; } || true)
# DUMPCAP_PATH already resolved above
[ -z "$IP_PATH" ] && die "ip not found"
[ -z "$TCPDUMP_PATH" ] && die "tcpdump not found — package installation may have failed"
SUDOERS_FILE="/etc/sudoers.d/wifidump"
echo "$SCRIPT_USER ALL=(ALL) NOPASSWD: $IP_PATH, /usr/local/bin/iw, $DUMPCAP_PATH, $TCPDUMP_PATH, /usr/local/bin/mon0-set-channel" \
  | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"
# Validate the file — sudo will ignore sudoers.d files with syntax errors
sudo visudo -c -f "$SUDOERS_FILE" > /dev/null \
  && echo "  Created $SUDOERS_FILE (/usr/local/bin/iw, $IP_PATH, $DUMPCAP_PATH, $TCPDUMP_PATH, /usr/local/bin/mon0-set-channel)" \
  || echo "  WARNING: $SUDOERS_FILE failed visudo check — check paths manually"

echo "  Step 1 done."

# =============================================================================
# STEP 2 — NetworkManager / dhcpcd: Exclude wlan1 and ap0, enable the wlan0 radio
# =============================================================================
echo ""
echo "--- [2/7] NetworkManager / dhcpcd — Excluding wlan1 and ap0 ---"

# Enable NetworkManager's Wi-Fi radio switch.
#
# If Wi-Fi was not configured in Raspberry Pi Imager, Raspberry Pi OS leaves the
# wireless radio disabled at first boot. NetworkManager then reports wlan0 as
# "unavailable" and refuses to bring the link up, so it stays DOWN with
# "qdisc noop" — and 'iw dev wlan0 scan' fails with "Network is down (-100)".
# That breaks the wlan0 channel survey (Part 2, Section 7.1), which is the only
# way to run an ACTIVE scan while mon0 owns the Alfa's radio.
#
# This is NM's own soft switch, independent of rfkill, and it persists in
# /var/lib/NetworkManager/NetworkManager.state. Turning it on leaves wlan0
# "disconnected" — radio up and scannable, not connected to anything. wlan1 is
# unmanaged, so NM does not touch it either way.
if command -v nmcli > /dev/null; then
    if [ "$(nmcli -t radio wifi 2>/dev/null)" = "disabled" ]; then
        sudo nmcli radio wifi on 2>/dev/null \
            && ok "NetworkManager Wi-Fi radio enabled (wlan0 now scannable)" \
            || warn "Could not enable the Wi-Fi radio — run: sudo nmcli radio wifi on"
    else
        ok "NetworkManager Wi-Fi radio already enabled"
    fi
else
    warn "nmcli not found — cannot check the Wi-Fi radio switch"
fi

# Mark unmanaged via nmcli (may fail if adapter not plugged in yet — that's OK)
sudo nmcli dev set wlan1 managed no 2>/dev/null || true

# Permanent conf.d file so it survives reboots regardless of adapter presence
sudo tee /etc/NetworkManager/conf.d/wlan1-unmanaged.conf > /dev/null <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan1;interface-name:ap0
EOF

sudo systemctl reload NetworkManager 2>/dev/null \
  || sudo systemctl restart NetworkManager 2>/dev/null \
  || warn "Could not reload NetworkManager — reboot will apply the config"
ok "wlan1 and ap0 excluded from NetworkManager"

# Exclude wlan1 and ap0 from dhcpcd — dhcpcd watches for new interfaces and
# will try to DHCP-configure ap0 the moment it appears, which conflicts with
# hostapd's AP mode setup and causes INTERFACE-DISABLED failures.
if [ -f /etc/dhcpcd.conf ]; then
    grep -q "denyinterfaces.*ap0" /etc/dhcpcd.conf 2>/dev/null \
        || echo "denyinterfaces wlan1 ap0" | sudo tee -a /etc/dhcpcd.conf > /dev/null
    sudo systemctl restart dhcpcd 2>/dev/null || true
    ok "wlan1 and ap0 excluded from dhcpcd"
fi

# =============================================================================
# STEP 3 — wlan1-monitor Systemd Service (creates mon0 at boot)
# =============================================================================
echo ""
echo "--- [3/7] Monitor Mode Service (wlan1-monitor) ---"

sudo tee /etc/systemd/system/wlan1-monitor.service > /dev/null <<'EOF'
[Unit]
Description=Create mon0 monitor interface on wlan1 (Alfa AWUS036AXML)
After=sys-subsystem-net-devices-wlan1.device
BindsTo=sys-subsystem-net-devices-wlan1.device

[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/iw dev mon0 del
ExecStart=/usr/sbin/rfkill unblock wifi
ExecStart=/usr/sbin/ip link set wlan1 up
ExecStart=/usr/sbin/iw dev wlan1 interface add mon0 type monitor
ExecStart=/usr/sbin/ip link set mon0 up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wlan1-monitor
echo "  wlan1-monitor enabled (starts when Alfa adapter is plugged in)."

# =============================================================================
# STEP 4 — iperf Persistent Services
# =============================================================================
echo ""
echo "--- [4/7] iperf Persistent Services ---"

# iperf2 TCP — port 5001, Zephyr zperf compatible
sudo tee /etc/systemd/system/iperf2-tcp.service > /dev/null <<'EOF'
[Unit]
Description=iperf2 TCP server (port 5001, Zephyr zperf compatible)
After=network.target

[Service]
ExecStart=/usr/bin/iperf -s
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# iperf2 UDP — separate instance required (single iperf -s only handles TCP)
sudo tee /etc/systemd/system/iperf2-udp.service > /dev/null <<'EOF'
[Unit]
Description=iperf2 UDP server (port 5001, Zephyr zperf compatible)
After=network.target

[Service]
ExecStart=/usr/bin/iperf -s -u
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# iperf3 — port 5201, single instance handles both TCP and UDP
sudo tee /etc/systemd/system/iperf3.service > /dev/null <<'EOF'
[Unit]
Description=iperf3 Network Performance Tool (port 5201)
After=network.target

[Service]
ExecStart=/usr/bin/iperf3 -s
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable iperf2-tcp iperf2-udp iperf3
echo "  iperf2-tcp, iperf2-udp, iperf3 enabled."

# =============================================================================
# STEP 5 — AP Mode Pre-configuration (hostapd + dnsmasq)
# =============================================================================
echo ""
echo "--- [5/7] AP Mode Pre-configuration ---"

sudo mkdir -p /etc/hostapd

# Default: 5 GHz, channel 36, 802.11ax (Wi-Fi 6)
# Edit /etc/hostapd/hostapd-ap0.conf to change band/channel/technology
# Skipped if the file already exists so a re-run doesn't clobber your edits
# (e.g. a custom channel or passphrase) — delete the file to regenerate defaults.
if [ -f /etc/hostapd/hostapd-ap0.conf ]; then
    echo "  /etc/hostapd/hostapd-ap0.conf already exists — leaving your customizations intact."
else
sudo tee /etc/hostapd/hostapd-ap0.conf > /dev/null <<'EOF'
interface=ap0
driver=nl80211
ssid=RPi5-TestAP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0

# =============================================================================
# BAND SELECTION — hw_mode
# =============================================================================
#   a  → 5 GHz   (required for 802.11ac / Wi-Fi 5 and 802.11ax / Wi-Fi 6)
#   g  → 2.4 GHz (use for 802.11n / Wi-Fi 4 on 2.4 GHz, or legacy g/b)
#   b  → 2.4 GHz legacy only (avoid unless specifically testing old devices)
hw_mode=a

# =============================================================================
# CHANNEL SELECTION
# =============================================================================
# Must match hw_mode. When switching channel also update ht_capab (HT40+/-)
# and vht_oper_centr_freq_seg0_idx (if using 80 MHz VHT) below.
#
# IMPORTANT: The Alfa MT7921 is a single-radio adapter. The AP must use the
# same band (2.4/5/6 GHz) as mon0. Since mon0 is created on the 5 GHz PHY by
# the wlan1-monitor service, the AP must also be 5 GHz (hw_mode=a).
#
# NOTE: 5 GHz and 6 GHz require a regulatory domain to be configured:
#   sudo raspi-config nonint do_wifi_country SE   (use your country code)
#   sudo reboot
#
#  5 GHz no-DFS — safe indoors, no radar detection needed:
#    UNII-1:  36, 40, 44, 48      ← recommended for lab/office use
#    UNII-3: 149, 153, 157, 161   ← also no DFS, good alternative
#
#  5 GHz DFS — radar detection required, may trigger channel switch:
#    UNII-2: 52, 56, 60, 64, 100, 104, 108, 112, 116, 132, 136, 140
channel=36

# =============================================================================
# 802.11 MODE / GENERATION
# =============================================================================
# Default: 802.11n / Wi-Fi 4 on 5 GHz (HT40) — reliable baseline.
# Requires country code set (see NOTE above).
#
# To enable 802.11ac / Wi-Fi 5 (80 MHz VHT):
#   Uncomment ieee80211ac and vht_* lines below
# To enable 802.11ax / Wi-Fi 6:
#   Uncomment ieee80211ac + ieee80211ax lines
#
#  To test 802.11a only:  comment out ieee80211n line

# --- 802.11n / Wi-Fi 4 (HT20) ---
# HT20 (20 MHz) is used instead of HT40 to avoid the mandatory HT co-existence
# scan that hostapd performs before enabling 40 MHz mode. That scan causes a
# ~30s delay before the AP becomes visible. HT20 starts in ~3s and is more
# than sufficient for iperf/zperf testing.
# To switch to HT40 (higher throughput, ~30s startup):
#   ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]   # ch 36, 44, 149, 157
#   ht_capab=[HT40-][SHORT-GI-20][SHORT-GI-40]   # ch 40, 48, 153, 161
ieee80211n=1
wmm_enabled=1
ht_capab=[SHORT-GI-20]

# --- 802.11ac / Wi-Fi 5 (uncomment to enable 80 MHz VHT) ---
#ieee80211ac=1
#vht_capab=[SHORT-GI-80][MAX-MPDU-11454]
## Channel width: 0 = 20/40 MHz   1 = 80 MHz   2 = 160 MHz
#vht_oper_chwidth=1
## 80 MHz centre segment — update when changing channel:
##   ch 36–48  → 42    ch 52–64  → 58    ch 100–112 → 106
##   ch 132–140 → 138  ch 149–161 → 155
#vht_oper_centr_freq_seg0_idx=42

# --- 802.11ax / Wi-Fi 6 (uncomment to enable — requires ieee80211ac above) ---
#ieee80211ax=1

# =============================================================================
# SECURITY
# =============================================================================
wpa=2
wpa_passphrase=TestPassword123
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
fi

# dnsmasq config for AP clients (192.168.99.x)
# listen-address is used instead of interface= + bind-interfaces because
# dnsmasq cannot resolve dynamically created VIF interfaces by name at startup.
# Skipped if it already exists — see note above.
if [ -f /etc/dnsmasq-ap0.conf ]; then
    echo "  /etc/dnsmasq-ap0.conf already exists — leaving your customizations intact."
else
sudo tee /etc/dnsmasq-ap0.conf > /dev/null <<'EOF'
listen-address=192.168.99.1
bind-interfaces
dhcp-range=192.168.99.100,192.168.99.200,255.255.255.0,24h
dhcp-option=3,192.168.99.1
EOF
fi

# Disable the system dnsmasq service — it conflicts with the AP-specific instance
# started by ap-enable. DHCP is only needed when the AP is active.
sudo systemctl disable --now dnsmasq 2>/dev/null || true
echo "  System dnsmasq service disabled (AP instance managed by ap-enable/ap-disable)."

echo "  hostapd and dnsmasq configs written."

# ap-enable: creates ap0 VIF, starts hostapd, waits for ENABLED, then assigns IP,
#            starts dnsmasq and sets up NAT.
sudo tee /usr/local/bin/ap-enable > /dev/null <<'EOF'
#!/bin/bash
set -e

# Clean up any leftover state from a previous run
kill "$(cat /var/run/hostapd-ap0.pid 2>/dev/null)" 2>/dev/null || pkill hostapd 2>/dev/null || true
rm -f /var/run/hostapd-ap0.pid /var/run/hostapd/ap0 /tmp/hostapd-ap0.log
pkill -f "dnsmasq-ap0" 2>/dev/null || true
/usr/sbin/iw dev ap0 del 2>/dev/null || true
sleep 0.5

# Ensure hostapd control socket directory exists
mkdir -p /var/run/hostapd

# Create AP virtual interface and bring it up
/usr/sbin/iw dev wlan1 interface add ap0 type __ap
/usr/sbin/ip link set ap0 up

# Start hostapd in background with logging.
# Use nohup + & instead of -B: the -B daemonize flag causes nl80211 socket
# issues on MT7921 that prevent AP mode from initialising correctly.
nohup /usr/sbin/hostapd /etc/hostapd/hostapd-ap0.conf >> /tmp/hostapd-ap0.log 2>&1 &
echo $! > /var/run/hostapd-ap0.pid

# Brief pause then verify hostapd is still running
sleep 2
if ! pgrep -x hostapd > /dev/null; then
    echo "  [ERROR] hostapd failed to start. Check log: sudo cat /tmp/hostapd-ap0.log"
    echo "  Common cause: country code not set — run: sudo raspi-config nonint do_wifi_country SE"
    exit 1
fi

# Wait for hostapd to reach ENABLED (normally ~3s with HT20; ~30s with HT40)
echo "  Waiting for AP to become active..."
for i in $(seq 1 20); do
    hostapd_cli -i ap0 status 2>/dev/null | grep -q "state=ENABLED" && break
    sleep 1
done

# Assign IP only after hostapd has fully configured the interface
/usr/sbin/ip addr add 192.168.99.1/24 dev ap0

# Stop system dnsmasq (conflicts with AP instance) and start AP-specific instance
systemctl stop dnsmasq 2>/dev/null || true
sleep 0.5
/usr/sbin/dnsmasq -C /etc/dnsmasq-ap0.conf

# Enable IP forwarding and NAT — auto-detect the uplink interface
UPLINK=$(ip route | awk '/^default/ {print $5; exit}')
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
iptables -A FORWARD -i ap0 -o "$UPLINK" -j ACCEPT
iptables -A FORWARD -i "$UPLINK" -o ap0 -m state --state RELATED,ESTABLISHED -j ACCEPT

CHANNEL=$(grep "^channel=" /etc/hostapd/hostapd-ap0.conf | cut -d= -f2)
echo "AP started — SSID: RPi5-TestAP, gateway: 192.168.99.1, channel: $CHANNEL (uplink: $UPLINK)"
EOF
sudo chmod +x /usr/local/bin/ap-enable

# ap-disable: stops hostapd + dnsmasq, removes ap0 VIF
sudo tee /usr/local/bin/ap-disable > /dev/null <<'EOF'
#!/bin/bash
kill "$(cat /var/run/hostapd-ap0.pid 2>/dev/null)" 2>/dev/null || pkill hostapd 2>/dev/null || true
rm -f /var/run/hostapd-ap0.pid
pkill -f "dnsmasq-ap0" 2>/dev/null || true

# Remove NAT rules — match whichever interface was the uplink
UPLINK=$(ip route | awk '/^default/ {print $5; exit}')
iptables -t nat -D POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i ap0 -o "$UPLINK" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$UPLINK" -o ap0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=0

/usr/sbin/iw dev ap0 del 2>/dev/null || true
echo "AP stopped, ap0 removed."
EOF
sudo chmod +x /usr/local/bin/ap-disable

echo "  ap-enable and ap-disable installed to /usr/local/bin/"

# =============================================================================
# STEP 6 — Persistent Monitor Channel (mon0)
# =============================================================================
echo ""
echo "--- [6/7] Persistent Monitor Channel Configuration ---"

sudo mkdir -p /etc/wifi-sniffer

# Channel config — edit any time to change mon0's channel, or use the
# mon0-set-channel helper below. Applied automatically on every reboot.
# Skipped if it already exists so a re-run doesn't reset your chosen channel.
if [ -f /etc/wifi-sniffer/mon0-channel.conf ]; then
    echo "  /etc/wifi-sniffer/mon0-channel.conf already exists — leaving it untouched."
else
sudo tee /etc/wifi-sniffer/mon0-channel.conf > /dev/null <<'EOF'
# mon0 monitor channel — applied at boot by wlan1-monitor-channel.service,
# and any time via: sudo mon0-set-channel
#
# CHANNEL:     plain iw channel number (2.4/5 GHz), e.g. 6, 36, 60, 149
# FREQ:        control frequency in MHz — required for 6 GHz; takes precedence
#              over CHANNEL when both are set. e.g. 5975, 6135, 6175, 6215
# FREQ_WIDTH:  channel width in MHz: 20 (default), 40, 80 or 160
# FREQ_CENTRE: centre frequency in MHz — MANDATORY for widths above 20 MHz.
#              iw refuses "set freq <f> 40" without it. mon0-set-channel
#              derives it automatically for 5 and 6 GHz; set it by hand only
#              for a non-standard block.
CHANNEL=36
#FREQ=
#FREQ_WIDTH=20
#FREQ_CENTRE=
EOF
    echo "  Created /etc/wifi-sniffer/mon0-channel.conf (default: channel 36)"
fi

# mon0-set-channel — applies the config above to mon0. The MT7921 driver
# requires wlan1 to be down to change mon0's band/channel, so this brings
# wlan1 down, applies the channel/frequency, then brings wlan1 back up.
#
# Usage:
#   sudo mon0-set-channel                        # (re-)apply the channel from the conf file
#   sudo mon0-set-channel 36                     # channel 36 (2.4/5 GHz), stored + applied
#   sudo mon0-set-channel freq 6135              # 6135 MHz, 20 MHz wide
#   sudo mon0-set-channel freq 6135 40           # 40 MHz wide, centre derived automatically
#   sudo mon0-set-channel freq 6135 40 6125      # explicit centre frequency
#
# NOTE: iw REQUIRES a centre frequency for any width above 20 MHz —
# "iw dev mon0 set freq 6135 40" is a usage error, not a driver failure. The
# helper derives the centre of the containing block for 5 and 6 GHz so the
# 3-argument form works; pass a 4th argument only for a non-standard block.
sudo tee /usr/local/bin/mon0-set-channel > /dev/null <<'EOF'
#!/bin/bash
# mon0-set-channel — set mon0's capture channel and persist it across reboots.
set -uo pipefail

CONF=/etc/wifi-sniffer/mon0-channel.conf

# Call the real iw, NOT the /usr/local/bin/iw wrapper. The wrapper deliberately
# swallows "Invalid argument" so wifidump keeps streaming; here that would hide
# a genuine mistake and report success for a channel that was never set.
IW=/usr/sbin/iw

die() { echo "mon0-set-channel: $*" >&2; exit 1; }

usage() {
    cat >&2 <<'USAGE'
Usage:
  mon0-set-channel                               re-apply the channel from the conf file
  mon0-set-channel <channel>                     2.4/5 GHz channel number (6, 36, 149 ...)
  mon0-set-channel freq <MHz>                    control frequency, 20 MHz wide (use for 6 GHz)
  mon0-set-channel freq <MHz> <width>            width 20|40|80|160, centre derived automatically
  mon0-set-channel freq <MHz> <width> <centre>   explicit centre frequency in MHz

iw requires a centre frequency for any width above 20 MHz. It is derived for
5 and 6 GHz, so the 4th argument is only needed for a non-standard block.
USAGE
    exit 1
}

is_num() { [[ $1 =~ ^[0-9]+$ ]]; }

# Centre of the <width> MHz block containing control frequency <freq>.
# Blocks are aligned to the bottom of the band: 5170 MHz for 5 GHz (so ch36+40
# -> 5190) and 5945 MHz for 6 GHz (so 6135 at 40 MHz -> 6125).
derive_centre() {
    local f=$1 w=$2 base
    if   (( f >= 5945 && f <= 7125 )); then base=5945
    elif (( f >= 5170 && f <= 5895 )); then base=5170
    else
        die "cannot derive a centre frequency for ${f} MHz — pass it as the 4th argument"
    fi
    echo $(( base + ((f - base) / w) * w + w / 2 ))
}

# ------------------------------------------------------------ parse arguments
MODE=""; NEW_CHANNEL=""; NEW_FREQ=""; NEW_WIDTH=""; NEW_CENTRE=""

case "${1:-}" in
    -h|--help|help) usage ;;
esac

if [ "${1:-}" = "freq" ]; then
    MODE=freq
    NEW_FREQ=${2:-}; NEW_WIDTH=${3:-20}; NEW_CENTRE=${4:-}
    is_num "$NEW_FREQ"  || usage
    is_num "$NEW_WIDTH" || usage
    case "$NEW_WIDTH" in
        20)
            NEW_CENTRE="" ;;
        40|80|160)
            if [ -n "$NEW_CENTRE" ]; then
                is_num "$NEW_CENTRE" || usage
            else
                NEW_CENTRE=$(derive_centre "$NEW_FREQ" "$NEW_WIDTH") || exit 1
            fi ;;
        *)
            die "width must be 20, 40, 80 or 160 (got $NEW_WIDTH)" ;;
    esac
elif [ -n "${1:-}" ]; then
    is_num "$1" || usage
    MODE=channel; NEW_CHANNEL=$1
fi

# ------------------------------------------------- persist before applying
# Arguments are fully validated above, so the conf file can never be left
# holding a combination that fails on every subsequent run.
if [ -n "$MODE" ]; then
    TMP=$(mktemp) || die "mktemp failed"
    {
        cat <<'HDR'
# mon0 monitor channel — applied at boot by wlan1-monitor-channel.service,
# and any time via: sudo mon0-set-channel
#
# CHANNEL:     plain iw channel number (2.4/5 GHz), e.g. 6, 36, 60, 149
# FREQ:        control frequency in MHz — required for 6 GHz; takes precedence
#              over CHANNEL when both are set. e.g. 5975, 6135, 6175, 6215
# FREQ_WIDTH:  channel width in MHz: 20 (default), 40, 80 or 160
# FREQ_CENTRE: centre frequency in MHz — MANDATORY for widths above 20 MHz.
#              iw refuses "set freq <f> 40" without it. mon0-set-channel
#              derives it automatically for 5 and 6 GHz.
HDR
        if [ "$MODE" = freq ]; then
            echo "#CHANNEL="
            echo "FREQ=$NEW_FREQ"
            echo "FREQ_WIDTH=$NEW_WIDTH"
            if [ -n "$NEW_CENTRE" ]; then echo "FREQ_CENTRE=$NEW_CENTRE"; else echo "#FREQ_CENTRE="; fi
        else
            echo "CHANNEL=$NEW_CHANNEL"
            echo "#FREQ="
            echo "#FREQ_WIDTH=20"
            echo "#FREQ_CENTRE="
        fi
    } > "$TMP"
    install -m 644 "$TMP" "$CONF" || die "could not write $CONF"
    rm -f "$TMP"
fi

# ------------------------------------------------------------------- apply
[ -r "$CONF" ] || die "$CONF not found — re-run setup-wifi-sniffer.sh"
# shellcheck disable=SC1090
source "$CONF"

CHANNEL=${CHANNEL:-}
FREQ=${FREQ:-}
FREQ_WIDTH=${FREQ_WIDTH:-20}
FREQ_CENTRE=${FREQ_CENTRE:-}

# Back-compat: conf files written before FREQ_CENTRE existed.
if [ -n "$FREQ" ] && [ "$FREQ_WIDTH" != 20 ] && [ -z "$FREQ_CENTRE" ]; then
    FREQ_CENTRE=$(derive_centre "$FREQ" "$FREQ_WIDTH") || exit 1
fi

$IW dev mon0 info > /dev/null 2>&1 \
    || die "mon0 does not exist — sudo systemctl start wlan1-monitor"

# The MT7921 driver refuses a cross-band change while the managed wlan1 is UP,
# so wlan1 goes down for the switch. The trap guarantees it comes back up even
# if iw fails — otherwise a rejected argument would strand wlan1 down and take
# the AP and any managed use of the adapter with it.
restore_wlan1() { ip link set wlan1 up 2> /dev/null || true; }
trap restore_wlan1 EXIT
ip link set wlan1 down

if [ -n "$FREQ" ]; then
    if [ -n "$FREQ_CENTRE" ]; then
        $IW dev mon0 set freq "$FREQ" "$FREQ_WIDTH" "$FREQ_CENTRE" \
            || die "iw rejected: set freq $FREQ $FREQ_WIDTH $FREQ_CENTRE"
        echo "mon0 set to ${FREQ} MHz, ${FREQ_WIDTH} MHz wide (centre ${FREQ_CENTRE} MHz)"
    else
        $IW dev mon0 set freq "$FREQ" "$FREQ_WIDTH" \
            || die "iw rejected: set freq $FREQ $FREQ_WIDTH"
        echo "mon0 set to ${FREQ} MHz, ${FREQ_WIDTH} MHz wide"
    fi
elif [ -n "$CHANNEL" ]; then
    $IW dev mon0 set channel "$CHANNEL" \
        || die "iw rejected: set channel $CHANNEL"
    echo "mon0 set to channel ${CHANNEL}"
else
    die "no CHANNEL or FREQ configured in $CONF"
fi

# Read back what the driver actually accepted
$IW dev mon0 info | grep -E "^[[:space:]]*(channel|center)" | sed 's/^[[:space:]]*/  /'
EOF
sudo chmod +x /usr/local/bin/mon0-set-channel

# wlan1-monitor-channel.service — applies the configured channel every boot,
# after mon0 has been created by wlan1-monitor.service.
sudo tee /etc/systemd/system/wlan1-monitor-channel.service > /dev/null <<'EOF'
[Unit]
Description=Apply configured channel to mon0
After=wlan1-monitor.service
Requires=wlan1-monitor.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mon0-set-channel
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wlan1-monitor-channel
echo "  wlan1-monitor-channel enabled — mon0 channel now persists across reboots."
echo "  Change it any time: sudo mon0-set-channel <channel>   (e.g. sudo mon0-set-channel 60)"

# =============================================================================
# STEP 7 — Verification
# =============================================================================
echo ""
echo "--- [7/7] Verification ---"
echo ""

PASS=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd" &>/dev/null; then
    echo "  [OK]  $label"
    PASS=$((PASS+1))
  else
    echo "  [!!]  $label — CHECK MANUALLY"
    FAIL=$((FAIL+1))
  fi
}

check "wlan1-monitor service enabled"     "systemctl is-enabled wlan1-monitor"
check "iperf2-tcp service enabled"        "systemctl is-enabled iperf2-tcp"
check "iperf2-udp service enabled"        "systemctl is-enabled iperf2-udp"
check "iperf3 service enabled"            "systemctl is-enabled iperf3"
check "dumpcap setcap applied"            "getcap /usr/bin/dumpcap | grep -q cap_net_raw"
check "wlan1 NM config present"           "test -f /etc/NetworkManager/conf.d/wlan1-unmanaged.conf"
check "NM Wi-Fi radio enabled (wlan0)"    "[ \"\$(nmcli -t radio wifi)\" = enabled ]"
check "sudoers wifidump entry present"    "sudo test -f /etc/sudoers.d/wifidump"
check "sudoers tcpdump entry present"     "sudo grep -q tcpdump /etc/sudoers.d/wifidump"
check "hostapd config present"            "test -f /etc/hostapd/hostapd-ap0.conf"
check "dnsmasq AP config present"         "test -f /etc/dnsmasq-ap0.conf"
check "wlan1-monitor-channel enabled"     "systemctl is-enabled wlan1-monitor-channel"
check "mon0 channel config present"       "test -f /etc/wifi-sniffer/mon0-channel.conf"

echo ""
echo "  $PASS checks passed, $FAIL need attention."

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================================"
echo " Setup complete."
echo "============================================================"
echo ""
echo " Next steps:"
echo "  1. REBOOT — required for group membership and services to take effect."
echo "     sudo reboot"
echo ""
echo "  2. After reboot, plug in the Alfa adapter and verify:"
echo "     iw dev           # should show wlan1 (managed) and mon0 (monitor)"
echo "     systemctl status wlan1-monitor wlan1-monitor-channel iperf2-tcp iperf2-udp iperf3"
echo ""
echo "  3. Edit the AP passphrase if needed:"
echo "     sudo nano /etc/hostapd/hostapd-ap0.conf"
echo ""
echo "  4. Change mon0's channel any time (persists across reboots):"
echo "     sudo mon0-set-channel 60             # 2.4/5 GHz channel number"
echo "     sudo mon0-set-channel freq 6135      # 6 GHz, MHz, 20 MHz wide"
echo "     sudo mon0-set-channel freq 6135 40   # 40 MHz wide, centre derived"
echo "     sudo mon0-set-channel --help         # all forms"
echo "     Or edit /etc/wifi-sniffer/mon0-channel.conf directly, then:"
echo "     sudo mon0-set-channel"
echo ""
echo " Re-running this script is safe — it repairs services/permissions and"
echo " won't overwrite your hostapd/dnsmasq/channel customizations."
echo ""
