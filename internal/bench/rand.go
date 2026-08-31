package bench

// Random-access determinism: every "random" choice in a scenario
// is a pure function of (seed, labels...), so the generator can
// stream 100M rows without state and the query selector can
// recompute any tuple's participants in O(1) — the property the
// selection-rule invariants (§2 of the plan) lean on.

// mix64 is SplitMix64's finalizer: a cheap, well-distributed
// 64-bit permutation.
func mix64(x uint64) uint64 {
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	x ^= x >> 31
	return x
}

// rnd folds the seed and any number of index labels into one
// uniform 64-bit value. Fold order matters, so distinct label
// tuples give independent streams.
func rnd(seed uint64, labels ...uint64) uint64 {
	x := mix64(seed ^ 0x9e3779b97f4a7c15)
	for _, l := range labels {
		x = mix64(x ^ mix64(l+0x9e3779b97f4a7c15))
	}
	return x
}

// rndBelow maps rnd output to [0, n). Modulo bias at these n
// (≤ 2^32) is < 2^-32 — irrelevant for workload shaping.
func rndBelow(seed uint64, n int, labels ...uint64) int {
	return int(rnd(seed, labels...) % uint64(n))
}
