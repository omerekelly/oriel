#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -O \
  -framework Foundation -framework Network -framework VideoToolbox \
  -framework CoreMedia -framework CoreGraphics -framework ImageIO \
  Tools/Probe/main.swift Shared/Protocol.swift \
  -o build/probe
echo "built build/probe"
