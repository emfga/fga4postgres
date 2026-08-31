package bench

import (
	"bufio"
	"context"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Env is the result file's environment block: everything needed
// to judge whether two result files are comparable. Capture is
// best-effort and recorded, never enforced (decision 7) —
// benchreport warns on mismatches, the binary refuses nothing.
type Env struct {
	EngineVersion string            `json:"engine_version"`
	PGVersion     string            `json:"pg_version"`
	PGSettings    map[string]string `json:"pg_settings"`
	OS            string            `json:"os"`
	Arch          string            `json:"arch"`
	CPUModel      string            `json:"cpu_model"`
	CPUCount      int               `json:"cpu_count"`
	Governor      string            `json:"governor"`
	Storage       string            `json:"storage"`
	GoVersion     string            `json:"go_version"`
	GitCommit     string            `json:"git_commit"`
	GitDirty      bool              `json:"git_dirty"`
	NDeadTupStart int64             `json:"n_dead_tup_start"`
	NDeadTupEnd   int64             `json:"n_dead_tup_end"`
}

// settingsOfRecord is the fixed list always captured; on top of
// it every non-default row rides along so any tuning shows up
// (plan §4).
var settingsOfRecord = []string{
	"shared_buffers", "work_mem", "effective_cache_size",
	"max_parallel_workers_per_gather", "random_page_cost",
	"jit", "checkpoint_timeout", "max_wal_size",
	"full_page_writes", "huge_pages",
}

// CaptureEnv assembles the block. Database errors surface (a
// result without its engine version is not a result); host
// probes degrade to "unknown".
func CaptureEnv(
	ctx context.Context, pool *pgxpool.Pool,
) (Env, error) {
	e := Env{
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
		CPUCount:  runtime.NumCPU(),
		CPUModel:  cpuModel(),
		Governor:  governor(),
		GoVersion: runtime.Version(),
		Storage:   Storage(ctx, pool),
	}
	e.GitCommit, e.GitDirty = gitState()

	if err := pool.QueryRow(ctx,
		"SELECT fga.version()").Scan(
		&e.EngineVersion); err != nil {
		return e, err
	}
	if err := pool.QueryRow(ctx,
		"SHOW server_version").Scan(&e.PGVersion); err != nil {
		return e, err
	}
	e.PGSettings = map[string]string{}
	rows, err := pool.Query(ctx, `
		SELECT name, setting FROM pg_settings
		WHERE name = ANY($1)
		   OR source NOT IN ('default', 'override')`,
		settingsOfRecord)
	if err != nil {
		return e, err
	}
	defer rows.Close()
	for rows.Next() {
		var name, setting string
		if err := rows.Scan(&name, &setting); err != nil {
			return e, err
		}
		e.PGSettings[name] = setting
	}
	return e, rows.Err()
}

// DeadTuples reads pg_stat_user_tables for fga.tuple, so write
// churn left behind by the mutating cases is visible in the
// result (plan §4). The view lags the stats collector slightly;
// that is fine for a pollution indicator.
func DeadTuples(
	ctx context.Context, pool *pgxpool.Pool,
) int64 {
	var n int64
	_ = pool.QueryRow(ctx, `
		SELECT coalesce(n_dead_tup, 0)
		FROM pg_stat_user_tables
		WHERE schemaname = 'fga' AND relname = 'tuple'`,
	).Scan(&n)
	return n
}

func cpuModel() string {
	f, err := os.Open("/proc/cpuinfo")
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), ":"); ok &&
			strings.TrimSpace(k) == "model name" {
			return strings.TrimSpace(v)
		}
	}
	return "unknown"
}

func governor() string {
	b, err := os.ReadFile("/sys/devices/system/cpu/cpu0" +
		"/cpufreq/scaling_governor")
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(b))
}

// gitState describes the harness checkout. Reinstall-before-run
// is unconditional (plan §3), so the installed schema matches
// this commit whenever dirty is false.
func gitState() (commit string, dirty bool) {
	root, err := RepoRoot()
	if err != nil {
		return "unknown", false
	}
	out, err := exec.Command(
		"git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		return "unknown", false
	}
	commit = strings.TrimSpace(string(out))
	st, err := exec.Command(
		"git", "-C", root, "status", "--porcelain").Output()
	if err != nil {
		return commit, false
	}
	return commit, len(strings.TrimSpace(string(st))) > 0
}
