#!/usr/bin/env bash
# Regenerates Sources/FlipperProto from the Flipper RPC .proto files.
# Usage: scripts/gen-proto.sh <dir-with-protos> <path-to-protoc-gen-swift>
# Needs protoc on PATH (e.g. nix-shell -p protobuf).
set -euo pipefail
PROTO_DIR="${1:?proto dir}"
PLUGIN="${2:?protoc-gen-swift path}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/FlipperProto"
rm -f "$OUT"/*.pb.swift
protoc --plugin=protoc-gen-swift="$PLUGIN" \
  --swift_opt=Visibility=Public \
  --swift_out="$OUT" \
  -I "$PROTO_DIR" "$PROTO_DIR"/*.proto
ls "$OUT"
