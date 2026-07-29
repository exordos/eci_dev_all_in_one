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

# First-boot bootstrap of a managed realm node.
#
# The parent realm's core delivers /etc/exordos/realm_spec.json to this node
# (a config resource created by the exordos ecosystem builder agent, see
# exordos_ecosystem docs/realm-manager.md). Once the file arrives, the nested
# exordos core VM is bootstrapped with the pre-assigned realm identity. The
# booted child then self-reports to the ecosystem and the managed realm
# becomes ACTIVE.

set -u
set -o pipefail

REALM_SPEC="/etc/exordos/realm_spec.json"
BUILD_ENV_FILE="/etc/exordos/realm-image.env"
ENV_FILE="/etc/exordos/realm.env"
MARKER="/var/lib/exordos-realm/.bootstrapped"
STORAGE_POOL="exordos-realm"
ATTEMPTS=3

if [ -f "$MARKER" ]; then
    echo "Realm already bootstrapped ($MARKER exists), nothing to do"
    exit 0
fi

# Single source of truth for INVENTORY and the nested core network
# (NESTED_CIDR / NESTED_GATEWAY / NESTED_CORE_IP), written at build time.
# The nested network is deliberately distinct from the parent realm network
# (10.20.0.0/22) so it never collides on a nested realm node.
# shellcheck source=/dev/null
. "$BUILD_ENV_FILE"

HYPER_URI="qemu+tcp://${NESTED_GATEWAY}/system"

echo "Waiting for the realm spec at $REALM_SPEC ..."
while [ ! -s "$REALM_SPEC" ]; do
    sleep 5
done

echo "Realm spec found, bootstrapping the nested core VM"

if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
    echo "env file $ENV_FILE found, sourced"
fi

for attempt in $(seq 1 "$ATTEMPTS"); do
    if exordos bootstrap \
        -m core \
        -i "$INVENTORY" \
        --repository "${ELEMENT_REPOSITORY:-https://repo.exordos.com/exordos-elements/}" \
        -f \
        --cidr "$NESTED_CIDR" \
        --hyper-connection-uri "$HYPER_URI" \
        --hyper-storage-pool "$STORAGE_POOL" \
        --realm-spec "$REALM_SPEC"; then

        mkdir -p "$(dirname "$MARKER")"
        touch "$MARKER"
        echo "Realm bootstrap finished successfully"
        exit 0
    fi
    echo "Bootstrap attempt $attempt/$ATTEMPTS failed, retrying in 30s"
    sleep 30
done

echo "Realm bootstrap failed after $ATTEMPTS attempts" >&2
exit 1
