// Package specfuzz is the Mayhem harness for the JSON message-spec importer: the spec is fuzz-controlled
// input, so it reaches the spec validation and tag sorting that the mined fix changed.
package specfuzz

import "github.com/moov-io/iso8583/specs"

// Fuzz builds a message spec from data (go-fuzz style: -1 rejects the input, 1 accepts it).
func Fuzz(data []byte) int {
	if _, err := specs.Builder.ImportJSON(data); err != nil {
		return -1
	}
	return 1
}
