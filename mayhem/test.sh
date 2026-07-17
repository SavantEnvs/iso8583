#!/usr/bin/env bash
#
# iso8583/mayhem/test.sh — RUN moov-io/iso8583's OWN full Go test suite (`go test ./...`)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: iso8583's suite is a large REAL known-answer suite — the message,
# field, encoding (ASCII/BCD/LBCD/EBCDIC/BER-TLV/binary/hex), prefix, padding, and specs
# packages all assert exact packed/unpacked byte sequences and field values for fixed
# inputs. They assert BEHAVIOUR, not "exits 0", so a no-op / stubbed pack/unpack FAILS
# this oracle. This script only RUNS the suite (build.sh already warmed the compile cache).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... (full upstream suite) ==="
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json -count=1 ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Package-level summary for humans (ok/FAIL lines from go test's own output).
grep -o '"Output":"\(ok  \|FAIL\|---\)[^"]*"' "$JSON" 2>/dev/null | grep -v '\-\-\- PASS' | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines with a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported non-zero but we counted 0 failures (e.g. a package
# build error), force a failure so the oracle stays honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter
# them. /mayhem/iso8583-reader-fuzz IS dynamically linked (clang+ASan). Run it single-shot on
# a known corpus seed and assert libFuzzer emits "Executed" — proving it actually processed
# the input. A sabotaged (exit-0-neutered) binary emits nothing → FAILED increments.
PROBE_INPUT="$SRC/mayhem/iso8583-reader-fuzz/testsuite/financial_transaction_message.dat"
if [ -x /mayhem/iso8583-reader-fuzz ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: iso8583-reader-fuzz single-shot on known corpus seed ==="
  PROBE_OUT=$(/mayhem/iso8583-reader-fuzz "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: iso8583-reader-fuzz executed the corpus input (unpack path active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: iso8583-reader-fuzz produced no 'Executed' output (inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
