#!/bin/bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec "$SCRIPT_DIR/manage-doubao-skin-macos.sh" disable "$@"
