// Native Go fuzz wrapper over the upstream legacy harness (test/fuzz-reader/reader.go),
// ported from the original fork integration. Run with:
//
//	go test -fuzz=FuzzReader ./mayhem/
//
// The libFuzzer target (/mayhem/iso8583-reader-fuzz) is built from the same
// fuzzreader.Fuzz entrypoint by mayhem/build.sh.
package mayhem

import (
	"testing"

	fuzzreader "github.com/moov-io/iso8583/test/fuzz-reader"
)

func FuzzReader(f *testing.F) {
	f.Fuzz(func(t *testing.T, data []byte) {
		fuzzreader.Fuzz(data)
	})
}
