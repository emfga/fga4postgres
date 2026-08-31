package bench

import (
	"time"
)

// The result file schema (plan §4). One file per scenario × size
// per invocation; everything a later reader needs to interpret —
// or to refuse to compare — rides along in the file.

// ResultSchemaVersion versions the JSON shape itself; benchreport
// refuses files it does not understand.
const ResultSchemaVersion = 1

type Result struct {
	SchemaVersion    int          `json:"schema_version"`
	StartedAt        string       `json:"started_at"`
	FinishedAt       string       `json:"finished_at"`
	Scenario         string       `json:"scenario"`
	Size             string       `json:"size"`
	Seed             uint64       `json:"seed"`
	GeneratorVersion int          `json:"generator_version"`
	Env              Env          `json:"env"`
	Load             LoadInfo     `json:"load"`
	Cases            []CaseResult `json:"cases"`
}

type LoadInfo struct {
	Rows    int64   `json:"rows"`
	Seconds float64 `json:"seconds"`
	Skipped bool    `json:"skipped"`
}

type CaseResult struct {
	Feature   string  `json:"feature"`
	Variant   string  `json:"variant"`
	WarmupOps uint64  `json:"warmup_ops"`
	Ops       uint64  `json:"ops"`
	Seconds   float64 `json:"seconds"`
	Latency   Latency `json:"latency_us"`
}

// Latency summarises the case histogram in microseconds. Min,
// max and mean are exact; the percentiles carry the pinned ~2%
// bucket error (histogram.go).
type Latency struct {
	Min  int64 `json:"min"`
	P50  int64 `json:"p50"`
	P95  int64 `json:"p95"`
	P99  int64 `json:"p99"`
	Max  int64 `json:"max"`
	Mean int64 `json:"mean"`
}

func summarize(h *Hist) Latency {
	us := func(d time.Duration) int64 {
		return d.Microseconds()
	}
	return Latency{
		Min:  us(h.Min()),
		P50:  us(h.Quantile(0.50)),
		P95:  us(h.Quantile(0.95)),
		P99:  us(h.Quantile(0.99)),
		Max:  us(h.Max()),
		Mean: us(h.Mean()),
	}
}
