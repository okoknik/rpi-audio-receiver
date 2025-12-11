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

enable_debian_contrib() {
    echo "Enabling Debian contrib and non-free repositories…"

    # Backup sources.list
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

    # Add contrib and non-free to lines containing 'main'
    sudo sed -i 's/ main$/ main contrib non-free/' /etc/apt/sources.list
    sudo sed -i 's/ main contrib$/ main contrib non-free/' /etc/apt/sources.list

    echo "Repositories updated. Running apt update…"
    sudo apt update
}

configure_audio_overlay() {
    echo "Configuring HiFiBerry Amp2 audio overlay…"

    # Remove dtparam=audio=on if it exists
    sudo sed -i '/^dtparam=audio=on$/d' /boot/config.txt

    # Add dtoverlay=hifiberry-dacplus if not present
    if ! grep -q '^dtoverlay=hifiberry-dacplus$' /boot/config.txt; then
        echo 'dtoverlay=hifiberry-dacplus' | sudo tee -a /boot/config.txt >/dev/null
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
}

configure_audio_codecs() {
    if [ "$BLUETOOTH_ENABLED" != "1" ]; then
        return
    fi

    echo "Configuring Bluetooth audio codecs…"

    read -p "Enable aptX codec? [y/N] " ENABLE_APTX
    read -p "Enable AAC codec? [y/N] " ENABLE_AAC

    PACKAGES=""
    if [[ "$ENABLE_APTX" =~ ^(yes|y|Y)$ ]]; then
        PACKAGES="$PACKAGES libopenaptx0"
    fi

    if [ -n "$PACKAGES" ]; then
        if ! sudo apt install -y --no-install-recommends $PACKAGES; then
            echo "Warning: Failed to install codec packages: $PACKAGES. Some codecs may not work."
        fi
    fi

    CODECS="sbc"
    if [[ "$ENABLE_AAC" =~ ^(yes|y|Y)$ ]]; then
        CODECS="$CODECS aac"
    fi
    if [[ "$ENABLE_APTX" =~ ^(yes|y|Y)$ ]]; then
        CODECS="$CODECS aptx"
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
         pipewire pipewire-pulse wireplumber libpipewire-0.3-dev \
         libspa-0.2-bluetooth avahi-daemon \
         wget unzip autoconf automake build-essential \
         libtool git libpopt-dev libconfig-dev \
         libssl-dev libsoxr-dev libplist-dev libsodium-dev \
         libavahi-client-dev libavcodec-dev libavformat-dev libavutil-dev uuid-dev xxd

    # If PipeWire isn’t running as user, enable it
    systemctl --user enable --now pipewire pipewire-pulse wireplumber

    if [[ -z "$TMP_DIR" ]]; then
        TMP_DIR=$(mktemp -d)
    fi

    cd "$TMP_DIR"

    # (same ALAC + NQPTP install as before)
    wget -O alac-master.zip https://github.com/mikebrady/alac/archive/refs/heads/master.zip
    unzip alac-master.zip
    cd alac-master
    autoreconf -fi
    ./configure
    make -j "$(nproc)"
    sudo make install
    sudo ldconfig
    cd ..

    wget -O nqptp-${NQPTP_VERSION}.zip \
         https://github.com/mikebrady/nqptp/archive/refs/tags/${NQPTP_VERSION}.zip
    unzip nqptp-${NQPTP_VERSION}.zip
    cd nqptp-${NQPTP_VERSION}
    autoreconf -fi
    ./configure --with-systemd-startup
    make -j "$(nproc)"
    sudo make install
    cd ..

    wget -O shairport-sync-${SHAIRPORT_SYNC_VERSION}.zip \
         https://github.com/mikebrady/shairport-sync/archive/refs/tags/${SHAIRPORT_SYNC_VERSION}.zip
    unzip shairport-sync-${SHAIRPORT_SYNC_VERSION}.zip
    cd shairport-sync-${SHAIRPORT_SYNC_VERSION}

    autoreconf -fi
    ./configure --sysconfdir=/etc \
                --with-pw \
                --with-avahi \
                --with-ssl=openssl \
                --with-systemd \
                --with-airplay-2
    make -j "$(nproc)"
    sudo make install
    cd ..

    # Shairport Sync config (PipeWire backend)
    sudo tee /etc/shairport-sync.conf >/dev/null <<EOF
general = {
  name = "${PRETTY_HOSTNAME:-$(hostname)}";
  output_backend = "pw";
}

pw = {
  # Additional PipeWire options can go here if desired
};

sessioncontrol = {
  session_timeout = 20;
};
EOF

    sudo usermod -a -G audio shairport-sync

    # Configure Shairport Sync systemd service to run as your user
    sudo systemctl daemon-reload
    sudo systemctl enable --now shairport-sync.service
}

install_raspotify() {
    read -p "Do you want to install Raspotify (Spotify Connect)? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^(yes|y|Y)$ ]]; then
        return
    fi

    curl -sL https://dtcooper.github.io/raspotify/install.sh | sh

    LIBRESPOT_NAME="${PRETTY_HOSTNAME// /-}"
    LIBRESPOT_NAME=${LIBRESPOT_NAME:-$(hostname)}

    sudo tee /etc/raspotify/conf >/dev/null <<EOF
LIBRESPOT_QUIET=on
LIBRESPOT_AUTOPLAY=on
LIBRESPOT_DISABLE_AUDIO_CACHE=on
LIBRESPOT_DISABLE_CREDENTIAL_CACHE=on
LIBRESPOT_ENABLE_VOLUME_NORMALISATION=on
LIBRESPOT_NAME="${LIBRESPOT_NAME}"
LIBRESPOT_DEVICE_TYPE="avr"
LIBRESPOT_BITRATE="320"
LIBRESPOT_INITIAL_VOLUME="100"
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable raspotify
}

trap cleanup EXIT

echo "Raspberry Pi Audio Receiver Install"

verify_os
enable_debian_contrib
configure_audio_overlay
set_hostname
install_bluetooth
configure_audio_codecs
install_shairport
install_raspotify
