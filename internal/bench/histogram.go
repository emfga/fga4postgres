package bench

import (
	"math"
	"time"
)

// Fixed-bucket log-spaced latency histogram. The bucket layout is
// pinned (plan §4) so percentiles stay comparable across binary
// versions: bounds 1µs–100s, buckets growing by ×1.04, which
// bounds the relative error of any reported percentile at ~2%
// (half the bucket width). Values outside the bounds clamp into
// the edge buckets; exact min/max/sum ride alongside so the
// extremes and the mean stay exact.

const (
	histMin   = time.Microsecond
	histMax   = 100 * time.Second
	histRatio = 1.04
)

// histBuckets covers [histMin, histMax] at the pinned ratio.
var histBuckets = int(math.Ceil(
	math.Log(float64(histMax)/float64(histMin))/
		math.Log(histRatio))) + 1

// Hist accumulates durations. The zero value is not ready — use
// NewHist.
type Hist struct {
	counts []uint64
	n      uint64
	sum    time.Duration
	min    time.Duration
	max    time.Duration
}

func NewHist() *Hist {
	return &Hist{counts: make([]uint64, histBuckets)}
}

// bucket maps a duration to its bucket index, clamped.
func bucket(d time.Duration) int {
	if d <= histMin {
		return 0
	}
	i := int(math.Log(float64(d)/float64(histMin)) /
		math.Log(histRatio))
	if i >= histBuckets {
		i = histBuckets - 1
	}
	return i
}

// bucketValue is the upper bound of a bucket — the value a
// percentile falling in that bucket reports, so the ~2% error is
// one-sided (never under-reporting a latency).
func bucketValue(i int) time.Duration {
	return time.Duration(float64(histMin) *
		math.Pow(histRatio, float64(i+1)))
}

func (h *Hist) Record(d time.Duration) {
	h.counts[bucket(d)]++
	h.n++
	h.sum += d
	if h.n == 1 || d < h.min {
		h.min = d
	}
	if d > h.max {
		h.max = d
	}
}

func (h *Hist) N() uint64 { return h.n }

func (h *Hist) Min() time.Duration { return h.min }
func (h *Hist) Max() time.Duration { return h.max }

func (h *Hist) Mean() time.Duration {
	if h.n == 0 {
		return 0
	}
	return h.sum / time.Duration(h.n)
}

// Quantile reports the smallest bucket bound below which at least
// q of the samples fall (0 < q <= 1). Min and max are exact; the
// interior carries the pinned ~2% bucket error.
func (h *Hist) Quantile(q float64) time.Duration {
	if h.n == 0 {
		return 0
	}
	rank := uint64(math.Ceil(q * float64(h.n)))
	// The extremes are tracked exactly — report them exactly,
	// which also keeps clamped out-of-range samples honest.
	if rank <= 1 {
		return h.min
	}
	if rank >= h.n {
		return h.max
	}
	var seen uint64
	for i, c := range h.counts {
		seen += c
		if seen >= rank {
			v := bucketValue(i)
			// Clamp to the exact extremes so p0/p100 never
			// report outside the observed range.
			if v > h.max {
				v = h.max
			}
			if v < h.min {
				v = h.min
			}
			return v
		}
	}
	return h.max
}
