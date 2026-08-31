# Benchmark report

## direct @ 100k (seed 1)

- engine 0.1.0, PostgreSQL 18.6, go1.25.7
- linux/amd64, 8× Example CPU, governor performance
- storage volume; loaded 100000 rows in 0.7s
- commit aaaaaaaaaaaa
- closed-loop warm-cache service times, single connection — not latency under load

| case | ops/s | p50 | p95 | p99 | mean |
|---|--:|--:|--:|--:|--:|
| check hit-shallow | 350 | 300µs | 650µs | 900µs | 340µs |
| list_users many | 1 | 700.0ms | ~800.0ms | ~810.0ms | 705.0ms |

~ percentile computed from fewer than 100 samples
