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
ENV_FILE="/etc/exordos/realm-image.env"
MARKER="/var/lib/exordos-realm/.bootstrapped"
STORAGE_POOL="exordos-realm"
# The nested core's own NAT network must not collide with the network the
# realm node itself is attached to (both would default to 10.20.0.0/22,
# see exordos/constants.py GC_CIDR), hence a distinct --cidr/URI here.
NESTED_CIDR="192.168.100.0/24"
HYPER_URI="qemu+tcp://192.168.100.1/system"
ATTEMPTS=3

if [ -f "$MARKER" ]; then
    echo "Realm already bootstrapped ($MARKER exists), nothing to do"
    exit 0
fi

# shellcheck source=/dev/null
. "$ENV_FILE"

echo "Waiting for the realm spec at $REALM_SPEC ..."
while [ ! -s "$REALM_SPEC" ]; do
    sleep 5
done
echo "Realm spec found, bootstrapping the nested core VM"

for attempt in $(seq 1 "$ATTEMPTS"); do
    if exordos bootstrap \
        -m core \
        -i "$CORE_VERSION" \
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
