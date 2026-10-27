#!/usr/bin/env bash
# Generate Swift protobuf sources from protocol/proto into AMProtocol/Generated.
# The generator (protoc-gen-swift) is built from the resolved swift-protobuf
# checkout so its version always equals the runtime the package links.
# Usage: scripts/gen-proto.sh [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/mac/Packages/AMKit"
PROTO_DIR="$ROOT/protocol/proto"
OUT="$PKG/Sources/AMProtocol/Generated"

swift package --package-path "$PKG" resolve
(cd "$PKG/.build/checkouts/swift-protobuf" && swift build -c release --product protoc-gen-swift >&2)
PLUGIN="$PKG/.build/checkouts/swift-protobuf/.build/release/protoc-gen-swift"

generate() {
  local dest="$1"
  mkdir -p "$dest"
  (cd "$PROTO_DIR" && protoc \
    --plugin=protoc-gen-swift="$PLUGIN" \
    --swift_out="$dest" \
    --swift_opt=Visibility=Public \
    anmirror/v1/*.proto)
}

if [[ "${1:-}" == "--check" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  generate "$TMP"
  # protoc nests output by proto path; compare flattened.
  mkdir -p "$TMP/flat"
  find "$TMP/anmirror" -name '*.pb.swift' -exec cp {} "$TMP/flat/" \;
  if diff -r "$TMP/flat" "$OUT" >&2; then
    echo "gen-proto: up to date"
  else
    echo "gen-proto: generated files are stale; run scripts/gen-proto.sh" >&2
    exit 1
  fi
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  generate "$TMP"
  rm -f "$OUT"/*.pb.swift
  find "$TMP/anmirror" -name '*.pb.swift' -exec cp {} "$OUT/" \;
  echo "gen-proto: wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
fi
