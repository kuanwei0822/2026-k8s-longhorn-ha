#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

helm upgrade --install longhorn . \
  --namespace longhorn-system \
  --create-namespace \
  -f values.yaml

echo ""
echo "[完成] Longhorn 安裝-升級結束"