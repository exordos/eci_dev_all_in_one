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
    sudo apt-get install -y yq
    echo "ubuntu:ubuntu" | sudo chpasswd
    sudo rm -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    sudo yq -yi '.system_info.default_user.lock_passwd |= false' /etc/cloud/cloud.cfg
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
sudo resolvectl dns "$(ip -j route show default | jq -r '.[0].dev')" 1.1.1.1 || true

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
sudo virsh pool-define-as --name "$STORAGE_POOL" --type dir --target "$STORAGE_POOL_PATH"
sudo virsh pool-start "$STORAGE_POOL"
sudo virsh pool-autostart "$STORAGE_POOL"

# iptables rules are order-sensitive, so set appropriate rules via libvirt
# hooks: they expose the nested core API (11010) and private DNS (53) on
# the node addresses.
sudo mkdir -p /etc/libvirt/hooks
sudo cp "$EL_PATH/etc/libvirt/hooks/qemu" /etc/libvirt/hooks/
sudo chmod +x /etc/libvirt/hooks/qemu

sudo tee -a /etc/sysctl.conf > /dev/null <<EOL
net.ipv4.ip_forward=1
EOL

# Speed up nested VM boot
sudo curl -fsSL "$REPO_URL/1af41041/latest/1af41041.rom" --output /usr/share/qemu/1af41041.rom

# Install the exordos CLI (provides `exordos bootstrap`).
# EXORDOS_INSTALL_URL allows testing with a locally served installer.
curl -fsSL "${EXORDOS_INSTALL_URL:-$REPO_URL/install.sh}" | sudo sh

# Resolve the core element version to bake (latest stable by default)
CORE_VERSION="${CORE_VERSION:-}"
if [ -z "$CORE_VERSION" ]; then
    CORE_VERSION=$(curl -fsSL --compressed "$REPO_URL/exordos-elements/inventory.json" \
        | jq -r '.elements.core | keys[] | select(contains("-") | not)' \
        | sort -V | tail -1)
fi

# Pre-warm the element cache (core + ecosystem_realm inventories) so the
# first-boot bootstrap does not need to download anything.
sudo HOME=/root exordos bootstrap --download-only -i "$CORE_VERSION"

# First-boot bootstrap: waits for /etc/exordos/realm_spec.json delivered
# by the parent realm, then bootstraps the nested core VM with it.
sudo mkdir -p /etc/exordos /var/lib/exordos-realm
echo "CORE_VERSION=$CORE_VERSION" | sudo tee /etc/exordos/realm-image.env > /dev/null
sudo chmod +x "$EL_PATH/exordos/images/exordos-realm-bootstrap.sh"
sudo cp "$EL_PATH/etc/systemd/exordos-realm-bootstrap.service" /etc/systemd/system/
sudo systemctl enable exordos-realm-bootstrap.service

# Minimize image size, MUST be last before shutdown
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /tmp/*
sudo sync
