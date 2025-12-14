#!/bin/bash

set -e

NQPTP_VERSION="1.2.4"
SHAIRPORT_SYNC_VERSION="4.3.2"
TMP_DIR=""
BLUETOOTH_ENABLED=""

cleanup() {
    if [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}



verify_os() {
    MSG="Unsupported OS: Debian 13 (Trixie) or compatible is required."

    if [ ! -f /etc/os-release ]; then
        echo $MSG
        exit 1
    fi

    . /etc/os-release

    if [[ "$ID" != "debian" ]] || [[ "$VERSION_ID" != "13"* ]]; then
        echo $MSG
        exit 1
    fi
}

configure_audio_overlay() {
    echo "Configuring HiFiBerry Amp2 audio overlay…"

    # Remove dtparam=audio=on if it exists
    sudo sed -i '/^dtparam=audio=on$/d' /boot/firmware/config.txt

    # Add dtoverlay=hifiberry-dacplus if not present
    if ! grep -q '^dtoverlay=hifiberry-dacplus$' /boot/firmware/config.txt; then
        echo 'dtoverlay=hifiberry-dacplus' | sudo tee -a /boot/firmware/config.txt >/dev/null
    fi

    # Configure dtoverlay=vc4-kms-v3d,noaudio
    if grep -q '^dtoverlay=vc4-kms-v3d,noaudio$' /boot/firmware/config.txt; then
        # Already configured correctly
        :
    elif grep -q '^dtoverlay=vc4-kms-v3d$' /boot/firmware/config.txt; then
        # Replace existing without noaudio
        sudo sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,noaudio/' /boot/firmware/config.txt
    else
        # Append new
        echo 'dtoverlay=vc4-kms-v3d,noaudio' | sudo tee -a /boot/firmware/config.txt >/dev/null
    fi

    echo "HiFiBerry Amp2 configured."
}

set_hostname() {
    CURRENT_PRETTY_HOSTNAME=$(hostnamectl status --pretty)

    read -p "Hostname [$(hostname)]: " HOSTNAME
    sudo hostnamectl set-hostname "${HOSTNAME:-$(hostname)}"

    read -p "Pretty hostname [${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}]: " PRETTY_HOSTNAME
    PRETTY_HOSTNAME="${PRETTY_HOSTNAME:-${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}}"
    sudo hostnamectl set-hostname --pretty "$PRETTY_HOSTNAME"
}

configure_pipewire_bluetooth() {
    echo "Configuring PipeWire Bluetooth support…"

    sudo apt update
    sudo apt install -y --no-install-recommends \
        pipewire pipewire-pulse wireplumber \
        pipewire-alsa libspa-0.2-bluetooth

    # Remove conflicting PulseAudio Bluetooth modules
    sudo apt purge -y pulseaudio-module-bluetooth || true

    # Restart PipeWire services
    systemctl --user daemon-reload
    systemctl --user enable --now wireplumber pipewire pipewire-pulse

    # Enable Bluetooth service
    systemctl enable --now bluetooth.service

    # Unblock Bluetooth rfkill
    sudo rfkill unblock bluetooth

    # Disable serial console on Bluetooth UART to avoid conflicts
    sudo sed -i 's/ console=ttyAMA0,[0-9]*//g' /boot/firmware/cmdline.txt

    echo "PipeWire Bluetooth support installed."
    echo "You may configure codecs or profiles in WirePlumber config if needed."
}

install_bluetooth() {
    read -p "Do you want to install Bluetooth Audio support? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then
        return
    fi

    BLUETOOTH_ENABLED=1

    configure_pipewire_bluetooth

    # Bluetooth Agent
    sudo tee /etc/systemd/system/bt-agent@.service >/dev/null <<'EOF'
[Unit]
Description=Bluetooth Agent
Requires=bluetooth.service
After=bluetooth.service

[Service]
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable bt-agent@hci0.service

    # rfkill unblock service for persistence
    sudo tee /etc/systemd/system/rfkill-unblock-bluetooth.service >/dev/null <<'EOF'
[Unit]
Description=Unblock Bluetooth rfkill
After=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock bluetooth

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable rfkill-unblock-bluetooth.service
}

configure_audio_codecs() {
    if [ "$BLUETOOTH_ENABLED" != "1" ]; then
        return
    fi

    echo "Configuring Bluetooth audio codecs…"

    read -p "Enable aptX codec? [y/N] " ENABLE_APTX
    read -p "Enable aptX HD codec? [y/N] " ENABLE_APTX_HD
    read -p "Enable AAC codec? [y/N] " ENABLE_AAC

    PACKAGES=""
    if [[ "$ENABLE_APTX" =~ ^(yes|y|Y)$ ]]; then
        PACKAGES="$PACKAGES libopenaptx0"
    fi

    if [[ "$ENABLE_APTX_HD" =~ ^(yes|y|Y)$ ]]; then
        PACKAGES="$PACKAGES libopenaptx0"
    fi

    if [ -n "$PACKAGES" ]; then
        if ! sudo apt install -y --no-install-recommends $PACKAGES; then
            echo "Warning: Failed to install codec packages: $PACKAGES. Some codecs may not work."
        fi
    fi

    CODECS="sbc"
    if [[ "$ENABLE_APTX_HD" =~ ^(yes|y|Y)$ ]]; then
        CODECS="aptx_hd $CODECS"
    fi
    if [[ "$ENABLE_APTX" =~ ^(yes|y|Y)$ ]]; then
        CODECS="aptx $CODECS"
    fi
    if [[ "$ENABLE_AAC" =~ ^(yes|y|Y)$ ]]; then
        CODECS="$CODECS aac"
    fi

    sudo mkdir -p /etc/wireplumber/bluetooth.lua.d
    sudo tee /etc/wireplumber/bluetooth.lua.d/51-codecs.lua >/dev/null <<EOF
monitor.bluez.properties = {
  ["bluez5.codecs"] = "[ $CODECS ]",
}
EOF

    echo "Bluetooth codecs configured."
}

install_shairport() {
    read -p "Do you want to install Shairport Sync (AirPlay 2)? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then
        return
    fi

    # Ensure PipeWire and required audio packages are installed
    sudo apt update
    sudo apt install -y --no-install-recommends \
         pipewire pipewire-pulse wireplumber \
         libspa-0.2-bluetooth shairport-sync \
         wget unzip autoconf automake build-essential libtool

    # If PipeWire isn’t running as user, enable it
    systemctl --user enable --now pipewire pipewire-pulse wireplumber

    # Shairport Sync config (PipeWire backend)
    sudo tee /etc/shairport-sync.conf >/dev/null <<EOF
general = {
  name = "${PRETTY_HOSTNAME:-$(hostname)}";
  output_backend = "pw";
}

sessioncontrol = {
  session_timeout = 20;
};
EOF

    sudo usermod -a -G audio shairport-sync

    # Configure Shairport Sync systemd service to run as your user
    sudo systemctl daemon-reload
    sudo systemctl enable --now shairport-sync.service
}

trap cleanup EXIT

echo "Raspberry Pi Audio Receiver Install"

verify_os
configure_audio_overlay
set_hostname
install_bluetooth
configure_audio_codecs
install_shairport

echo "Installation complete. A reboot is recommended for audio overlays and services to take effect."
read -p "Reboot now? [y/N] " REBOOT_REPLY
if [[ "$REBOOT_REPLY" =~ ^(yes|y|Y)$ ]]; then
    echo "Rebooting..."
    sudo reboot
else
    echo "Please reboot manually when ready."
fi
