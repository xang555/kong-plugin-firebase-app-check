#!/usr/bin/env bash
set -euo pipefail

# Enable CGo for plugin builds
export CGO_ENABLED=1

# Override default linker flags to remove deprecated -ld_classic,
# and set rpath to loader path
export CGO_LDFLAGS="-Wl,-rpath,@loader_path"

# Build the Kong plugin as a Go plugin
go build -buildmode=plugin -o firebase_app_check.so .

echo "✅ Build complete: firebase_app_check.so"