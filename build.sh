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

# CORE_VERSION pins the exordos core element version baked into the image
# (default: latest stable in the public repo).
# DEV_ACCESS=1 enables ubuntu:ubuntu console/ssh access (dev builds only).

curl -fsSL https://repo.exordos.com/install.sh | sudo sh

exordos build -f . "$@"
