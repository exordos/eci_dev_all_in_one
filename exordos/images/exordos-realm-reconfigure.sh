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

# Apply a re-delivered realm spec to a node that is already bootstrapped.
#
# The parent realm rewrites /etc/exordos/realm_spec.json whenever the realm
# changes hands -- a warm pool realm being claimed is the case that matters --
# and runs this from the config resource's on_change hook.  The first-boot
# bootstrap consumes the whole spec, but it runs exactly once: it is gated on
# the marker below, so anything the spec gained after that was written to the
# node and never read.  The tenant's ssh key is the part of that which leaves
# a claimed realm unreachable, so it is applied here.
#
# This runs on every reconcile, so it must be idempotent, and it must return
# promptly: the node's universal agent waits for it.

set -u
set -o pipefail

REALM_SPEC="/etc/exordos/realm_spec.json"
BUILD_ENV_FILE="/etc/exordos/realm-image.env"
MARKER="/var/lib/exordos-realm/.bootstrapped"

# The nested core authorizes the key the node bootstrapped it with. With no
# key in the spec at first boot -- which is every warm pool realm -- `exordos
# bootstrap` generates one and keeps it, named after the installation
# (--name exordos-core), in the ubuntu user's home.  That key is the way in.
NODE_USER="ubuntu"
NODE_KEY="/home/$NODE_USER/.ssh/exordos_core"

# The hook runs as root; the key belongs to the node user that bootstrapped
# the nested core.
run_as_node_user() {
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "$NODE_USER" -- "$@"
    else
        "$@"
    fi
}

# Nothing has consumed the spec yet: the first boot takes it whole, this key
# included, so leave it to the service whose job that is.
if [ ! -f "$MARKER" ]; then
    echo "Not bootstrapped yet, leaving the spec to the bootstrap service"
    systemctl restart --no-block exordos-realm-bootstrap.service
    exit 0
fi

if [ ! -s "$REALM_SPEC" ]; then
    echo "No realm spec at $REALM_SPEC, nothing to apply"
    exit 0
fi

ssh_public_key="$(jq -r '.ssh_public_key // empty' "$REALM_SPEC")"
if [ -z "$ssh_public_key" ]; then
    echo "The spec carries no ssh key, nothing to apply"
    exit 0
fi

if [ ! -r "$NODE_KEY" ]; then
    echo "No usable node key at $NODE_KEY: cannot reach the nested core" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$BUILD_ENV_FILE"

# The key travels on stdin so it never has to survive a round of shell
# quoting on its way into the nested core.  A known link-local address with
# no persistent host key of its own is not worth recording, and recording it
# would only fail the next time the nested core is rebuilt.
printf '%s\n' "$ssh_public_key" | run_as_node_user ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=10 \
    -i "$NODE_KEY" \
    "$NODE_USER@$NESTED_CORE_IP" '
        set -eu
        key="$(cat)"
        install -d -m 700 "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        if grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then
            echo "ssh key already authorized"
        else
            printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
            echo "ssh key authorized"
        fi
    '
