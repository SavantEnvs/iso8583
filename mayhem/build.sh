#!/usr/bin/env bash
#
# iso8583/mayhem/build.sh — build moov-io/iso8583's fuzz harness as a sanitized
# libFuzzer binary (OSS-Fuzz Go path: go114-fuzz-build + clang link).
#
# Harness: mayhem/specfuzz/harness.go — mining branch only. Feeds fuzz bytes to the JSON message-spec
# importer (specs.Builder.ImportJSON), which builds composite fields and sorts their tag keys.
#
# We produce:
#   /mayhem/iso8583-spec-fuzz-mined-4ce54e2 — the fuzz target
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only; UBSan is not part of the Go libFuzzer link. An explicit
# empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C shim compile and
# the final clang++ link. Go's gc compiler always emits DWARF4 with no version knob; the C shim
# compiled by clang (LLVMFuzzerTestOneInput wrapper) is forced to DWARF3, and the FIRST CU in
# the binary (the shim) is what the DWARF-version gate reads.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Go env: toolchain pinned under /opt/toolchains (SPEC §6.2 item 8); GOMODCACHE is set in the
# Dockerfile ENV and survives the PATCH re-run under a different $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE. The module cache
# doubles as a FILE PROXY: file proxy FIRST, network LAST — the offline re-run resolves
# entirely from the in-image cache; the network entries only fill misses on the first
# (online) build.
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

TARGET="iso8583-spec-fuzz-mined-4ce54e2"
mkdir -p "$SRC/mayhem-build"

# ── Fuzz target: specfuzz.Fuzz via go114-fuzz-build (legacy func Fuzz([]byte) int) ────────
echo "=== building $TARGET (specfuzz.Fuzz, go114-fuzz-build) ==="
go114-fuzz-build -o "$SRC/mayhem-build/$TARGET.a" -func Fuzz github.com/moov-io/iso8583/mayhem/specfuzz
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$TARGET.a" -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# Warm the test-build cache so mayhem/test.sh only RUNS the suite (no cold compile there),
# and so the module graph for ./... (incl. test deps) is fully present in the module cache
# for the offline re-run.
echo "=== pre-building the test suite (go test -count=1 compile cache warm-up) ==="
go build ./...
go test -run '^$' -count=1 ./... >/dev/null

echo "build.sh complete:"
ls -la "/mayhem/$TARGET"
