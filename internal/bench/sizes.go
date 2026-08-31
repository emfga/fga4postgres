package bench

import "fmt"

// Size names a dataset scale. Tuples is the exact row count in
// fga.tuple for one scenario store at that scale (owner decision
// 3: sizes count tuples).
type Size struct {
	Name   string
	Tuples int
}

// Sizes is the single source of the supported scales. The CLI
// validator, the generator and the workflow (via -list-sizes)
// all read this list; nothing else may repeat it.
var Sizes = []Size{
	{Name: "100k", Tuples: 100_000},
	{Name: "1m", Tuples: 1_000_000},
	{Name: "10m", Tuples: 10_000_000},
	{Name: "100m", Tuples: 100_000_000},
}

// ParseSize resolves a size by name, listing the valid names in
// the error so a drifted caller (the workflow's forced YAML
// duplication) fails loudly.
func ParseSize(name string) (Size, error) {
	for _, s := range Sizes {
		if s.Name == name {
			return s, nil
		}
	}
	names := make([]string, len(Sizes))
	for i, s := range Sizes {
		names[i] = s.Name
	}
	return Size{}, fmt.Errorf(
		"unknown size %q (valid: %v)", name, names)
}
