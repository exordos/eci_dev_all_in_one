#!/usr/bin/env bash

# Copyright 2026 Genesis Corporation
#
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -eu
set -x
set -o pipefail

EL_PATH="/opt/exordos-realm"
REPO_URL="https://repo.exordos.com"
STORAGE_POOL="exordos-realm"
STORAGE_POOL_PATH="/var/lib/exordos-realm/disks"

# Nested core VM network. Single source of truth, baked into
# /etc/exordos/realm-image.env and consumed by the first-boot bootstrap
# (--cidr / --hyper-connection-uri). Kept distinct from the parent realm
# network (10.20.0.0/22, see exordos/constants.py GC_CIDR) so it never
# collides when this node is itself a nested realm node.
NESTED_CIDR="192.168.100.0/24"
NESTED_GATEWAY="192.168.100.1"

# Optimize apt
echo 'APT::Install-Recommends "false";' | sudo tee -a /etc/apt/apt.conf.d/99exordos.conf > /dev/null
echo 'APT::Install-Suggests "false";' | sudo tee -a /etc/apt/apt.conf.d/99exordos.conf > /dev/null
sudo apt-get update

# Hypervisor stack + tooling
sudo apt-get install -y \
    jq \
    qemu-guest-agent \
    bridge-utils \
    qemu-system-x86 \
    qemu-utils \
    genisoimage \
    libvirt-daemon-system \
    libvirt-dev \
    ovmf \
    net-tools \
    dnsmasq \
    qemu-system-modules-spice \
    iptables-persistent

# Developer builds only: enable console/ssh password access.
# Do NOT set for published images: access to managed realm nodes is
# governed by the parent core (ssh key / user capabilities).
if [ "${DEV_ACCESS:-0}" = "1" ]; then
    echo "ubuntu:ubuntu" | sudo chpasswd
    sudo rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    # Unlock the default user's password. cloud.cfg ships "lock_passwd: True";
    # sed avoids pulling in yq just for this one line.
    sudo sed -i -E 's/(lock_passwd:[[:space:]]*)([Tt]rue)/\1false/' /etc/cloud/cloud.cfg
fi

# RAM/swap optimizations: the node hosts a nested core VM.
# Note: this Ubuntu release no longer splits kernel modules into a
# separate "-extra" package (nor ships a "linux-modules-generic" meta
# package) - everything is in linux-modules-<uname -r>.
sudo apt-get install -y zram-tools "linux-modules-$(uname -r)"
echo "ALGO=zstd" | sudo tee -a /etc/default/zramswap > /dev/null
echo "PERCENT=20" | sudo tee -a /etc/default/zramswap > /dev/null
sudo systemctl enable zramswap

sudo apt-get install -y ksmtuned
# minimize cpu usage
echo "KSM_SLEEP_MSEC=100" | sudo tee -a /etc/ksmtuned.conf > /dev/null
sudo systemctl enable ksmtuned

# libvirt install breaks dns, fix it temporarily
DEFAULT_IF=$(ip -j route show default | jq -r '.[0].dev // empty')
if [ -n "$DEFAULT_IF" ]; then
    sudo resolvectl dns "$DEFAULT_IF" 1.1.1.1 || true
fi

# The exordos bootstrap CLI talks to the hypervisor over tcp
sudo tee -a /etc/libvirt/libvirtd.conf > /dev/null <<EOL
listen_tcp = 1
listen_addr = "0.0.0.0"
auth_tcp = "none"
EOL

sudo systemctl stop libvirtd
sudo systemctl enable libvirtd-tcp.socket
sudo systemctl start libvirtd-tcp.socket
sudo systemctl start libvirtd

# Storage pool for the nested core VM disks
sudo mkdir -p "$STORAGE_POOL_PATH"
# libvirtd may not accept connections immediately after start; wait for it
for _ in $(seq 1 10); do
    sudo virsh uri >/dev/null 2>&1 && break
    sleep 1
done
sudo virsh pool-define-as --name "$STORAGE_POOL" --type dir --target "$STORAGE_POOL_PATH"
sudo virsh pool-start "$STORAGE_POOL"
sudo virsh pool-autostart "$STORAGE_POOL"

# Exposing the nested core (core API 11010, private DNS 53) on the node
# addresses and SNAT'ing the nested subnet out is done by the control-plane
# `border` resource (border_node capability) that the parent realm delivers
# once the node registers — no static libvirt hook needed.
#
# The border driver (BorderCapabilityDriver) ships in gcl_sdk. Upgrade the
# universal agent's gcl_sdk to the latest PyPI release so border support is
# picked up automatically once released there.
# GCL_SDK_WHEEL_URL overrides the install source (e.g. a wheel built from a
# local gcl_sdk checkout and served from the dev repo) to test an unreleased
# SDK build before it ships to PyPI.
UA_VENV="/opt/universal_agent/.venv"
UA_CONF="/etc/exordos_universal_agent/exordos_universal_agent.conf"
sudo "$UA_VENV/bin/pip" install --upgrade "${GCL_SDK_WHEEL_URL:-gcl_sdk}"
if sudo "$UA_VENV/bin/python" -c "import gcl_sdk.agents.universal.drivers.border" 2>/dev/null; then
    if ! grep -q "BorderCapabilityDriver" "$UA_CONF"; then
        sudo awk '/caps_drivers =/{print; print "    BorderCapabilityDriver,"; next}1' \
            "$UA_CONF" | sudo tee "$UA_CONF.tmp" > /dev/null
        sudo mv "$UA_CONF.tmp" "$UA_CONF"
    fi
fi

sudo tee -a /etc/sysctl.conf > /dev/null <<EOL
net.ipv4.ip_forward=1
EOL

# Speed up nested VM boot
sudo mkdir -p /usr/share/qemu
sudo curl -fsSL "$REPO_URL/1af41041/latest/1af41041.rom" --output /usr/share/qemu/1af41041.rom

# Install the exordos CLI (provides `exordos bootstrap`).
# EXORDOS_INSTALL_URL allows testing with a locally served installer.
curl -fsSL "${EXORDOS_INSTALL_URL:-$REPO_URL/install.sh}" | sudo sh

# Element repository to fetch the core/ecosystem_realm elements from. Defaults
# to the public repo; override for local/dev testing against a mirror (e.g.
# a repository serving a not-yet-released core build).
ELEMENT_REPOSITORY="${ELEMENT_REPOSITORY:-$REPO_URL}"

# Resolve the core element version to bake (latest stable by default)
CORE_VERSION="${CORE_VERSION:-}"
if [ -z "$CORE_VERSION" ]; then
    CORE_VERSION=$(curl -fsSL --compressed "$ELEMENT_REPOSITORY/exordos-elements/inventory.json" \
        | jq -r '.elements.core | keys[] | select(contains("-") | not)' \
        | sort -V | tail -1)
fi

if [ -z "$CORE_VERSION" ] || [ "$CORE_VERSION" = "null" ]; then
    echo "Error: failed to resolve CORE_VERSION from $ELEMENT_REPOSITORY" >&2
    exit 1
fi

# Pre-warm the element cache (core + ecosystem_realm inventories) so the
# first-boot bootstrap does not need to download anything.
sudo HOME=/root exordos bootstrap --download-only -i "$CORE_VERSION" --repository "$ELEMENT_REPOSITORY"

# First-boot bootstrap: waits for /etc/exordos/realm_spec.json delivered
# by the parent realm, then bootstraps the nested core VM with it.
sudo mkdir -p /etc/exordos /var/lib/exordos-realm
sudo tee /etc/exordos/realm-image.env > /dev/null <<EOL
CORE_VERSION=$CORE_VERSION
ELEMENT_REPOSITORY=$ELEMENT_REPOSITORY
NESTED_CIDR=$NESTED_CIDR
NESTED_GATEWAY=$NESTED_GATEWAY
EOL
sudo chmod +x "$EL_PATH/exordos/images/exordos-realm-bootstrap.sh"
sudo cp "$EL_PATH/etc/systemd/exordos-realm-bootstrap.service" /etc/systemd/system/
sudo systemctl enable exordos-realm-bootstrap.service

# Minimize image size, MUST be last before shutdown
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /tmp/*
sudo sync
