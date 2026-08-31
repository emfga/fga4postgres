package bench

import (
	"math/rand/v2"
	"testing"
	"time"
)

func TestHistQuantileError(t *testing.T) {
	// Uniform samples over [1ms, 100ms]: every interior
	// quantile must land within the pinned ~2% bucket error
	// (plus the sampling granularity of n samples).
	rng := rand.New(rand.NewPCG(1, 2))
	h := NewHist()
	var exact []time.Duration
	for i := 0; i < 100_000; i++ {
		d := time.Millisecond +
			time.Duration(rng.Int64N(int64(99*time.Millisecond)))
		h.Record(d)
		exact = append(exact, d)
	}
	if h.N() != 100_000 {
		t.Fatalf("n = %d", h.N())
	}
	for _, q := range []float64{0.5, 0.95, 0.99} {
		got := float64(h.Quantile(q))
		want := float64(time.Millisecond) +
			q*float64(99*time.Millisecond)
		rel := (got - want) / want
		if rel < -0.03 || rel > 0.05 {
			t.Errorf("q%.2f: got %v, want ~%v (rel %+.3f)",
				q, time.Duration(got),
				time.Duration(want), rel)
		}
	}
	_ = exact
}

func TestHistExactExtremes(t *testing.T) {
	h := NewHist()
	for _, d := range []time.Duration{
		3 * time.Millisecond,
		17 * time.Microsecond,
		2 * time.Second,
	} {
		h.Record(d)
	}
	if h.Min() != 17*time.Microsecond {
		t.Errorf("min = %v", h.Min())
	}
	if h.Max() != 2*time.Second {
		t.Errorf("max = %v", h.Max())
	}
	mean := (3*time.Millisecond + 17*time.Microsecond +
		2*time.Second) / 3
	if h.Mean() != mean {
		t.Errorf("mean = %v, want %v", h.Mean(), mean)
	}
}

func TestHistClamps(t *testing.T) {
	h := NewHist()
	h.Record(time.Nanosecond)    // below 1µs
	h.Record(1000 * time.Second) // above 100s
	if h.N() != 2 {
		t.Fatalf("n = %d", h.N())
	}
	// Quantiles clamp into the exact observed range.
	if q := h.Quantile(0.5); q > time.Microsecond {
		t.Errorf("low clamp: %v", q)
	}
	if q := h.Quantile(1); q != 1000*time.Second {
		t.Errorf("high clamp: %v", q)
	}
}

func TestHistEmpty(t *testing.T) {
	h := NewHist()
	if h.Quantile(0.99) != 0 || h.Mean() != 0 || h.N() != 0 {
		t.Error("empty histogram must report zeros")
	}
}
