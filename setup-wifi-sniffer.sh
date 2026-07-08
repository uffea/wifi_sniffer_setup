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

echo ""
echo "============================================================"
echo " Wi-Fi Sniffer Setup"
echo " Target user: $SCRIPT_USER"
echo "============================================================"
echo ""

# =============================================================================
# STEP 1 — System Update & Package Installation
# =============================================================================
echo "--- [1/6] System Update & Package Installation ---"

$APT update || die "apt update failed — check network connectivity"
$APT full-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  || die "apt full-upgrade failed"

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
    #                    'sudo iw dev mon0 set freq <MHz> HT20' before starting
    #                    wifidump and enter the MHz value as the channel in Wireshark.
    exit 0
fi
[ -n "$output" ] && echo "$output" >&2
exit $ret
IWEOF
sudo chmod +x /usr/local/bin/iw

# sudoers drop-in for wifidump extcap — allows the plugin to run iw/ip/dumpcap
# over SSH without a password prompt.
# Lists /usr/local/bin/iw (the wrapper) so 'sudo iw' is permitted without a
# password. Scripts that call /usr/sbin/iw directly (ap-enable, wlan1-monitor)
# run as root via sudo and are unaffected.
IP_PATH=$(command -v ip 2>/dev/null || { [ -x /usr/sbin/ip ] && echo /usr/sbin/ip; } || true)
# DUMPCAP_PATH already resolved above
[ -z "$IP_PATH" ] && die "ip not found"
SUDOERS_FILE="/etc/sudoers.d/wifidump"
echo "$SCRIPT_USER ALL=(ALL) NOPASSWD: $IP_PATH, /usr/local/bin/iw, $DUMPCAP_PATH" \
  | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"
# Validate the file — sudo will ignore sudoers.d files with syntax errors
sudo visudo -c -f "$SUDOERS_FILE" > /dev/null \
  && echo "  Created $SUDOERS_FILE (/usr/local/bin/iw, $IP_PATH, $DUMPCAP_PATH)" \
  || echo "  WARNING: $SUDOERS_FILE failed visudo check — check paths manually"

echo "  Step 1 done."

# =============================================================================
# STEP 2 — NetworkManager / dhcpcd: Exclude wlan1 and ap0
# =============================================================================
echo ""
echo "--- [2/6] NetworkManager / dhcpcd — Excluding wlan1 and ap0 ---"

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
echo "--- [3/6] Monitor Mode Service (wlan1-monitor) ---"

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
echo "--- [4/6] iperf Persistent Services ---"

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
echo "--- [5/6] AP Mode Pre-configuration ---"

sudo mkdir -p /etc/hostapd

# Default: 5 GHz, channel 36, 802.11ax (Wi-Fi 6)
# Edit /etc/hostapd/hostapd-ap0.conf to change band/channel/technology
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

# dnsmasq config for AP clients (192.168.99.x)
# listen-address is used instead of interface= + bind-interfaces because
# dnsmasq cannot resolve dynamically created VIF interfaces by name at startup.
sudo tee /etc/dnsmasq-ap0.conf > /dev/null <<'EOF'
listen-address=192.168.99.1
bind-interfaces
dhcp-range=192.168.99.100,192.168.99.200,255.255.255.0,24h
dhcp-option=3,192.168.99.1
EOF

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
# STEP 6 — Verification
# =============================================================================
echo ""
echo "--- [6/6] Verification ---"
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
check "sudoers wifidump entry present"    "sudo test -f /etc/sudoers.d/wifidump"
check "hostapd config present"            "test -f /etc/hostapd/hostapd-ap0.conf"
check "dnsmasq AP config present"         "test -f /etc/dnsmasq-ap0.conf"

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
echo "     systemctl status wlan1-monitor iperf2-tcp iperf2-udp iperf3"
echo ""
echo "  3. Edit the AP passphrase if needed:"
echo "     sudo nano /etc/hostapd/hostapd-ap0.conf"
echo ""
