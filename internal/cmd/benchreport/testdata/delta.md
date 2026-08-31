# Benchmark report

## direct @ 100k (seed 1)

- engine 0.1.0, PostgreSQL 18.6, go1.25.7
- linux/amd64, 8× Example CPU, governor performance
- storage volume; loaded 100000 rows in 0.7s
- commit aaaaaaaaaaaa
- closed-loop warm-cache service times, single connection — not latency under load

> ⚠ baseline storage "tmpfs", candidate "volume"
> ⚠ baseline pg_settings.work_mem "8192", candidate "4096"

Deltas are against the committed baseline; informational only.

| case | ops/s | Δ ops/s | p50 | p95 | Δ p95 | p99 |
|---|--:|--:|--:|--:|--:|--:|
| check hit-shallow | 350 | +5.0% | 300µs | 650µs | -7.1% | 900µs |
| list_users many | 1 | +5.7% | 700.0ms | ~800.0ms | -2.4% | 810.0ms |

~ percentile computed from fewer than 100 samples
