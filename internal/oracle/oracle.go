// Package oracle dials the compose-provided reference OpenFGA
// server (the conformance oracle, pinned to the target version).
package oracle

import (
	"sync"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/emfga/fga4postgres/internal/testdb"
)

// Addr resolves the oracle's gRPC address. OPENFGA_GRPC_ADDR wins
// (the containerised suite sets it to openfga:8081); otherwise
// localhost with the compose-published OPENFGA_GRPC_PORT.
func Addr() string {
	if a := testdb.Env("OPENFGA_GRPC_ADDR", ""); a != "" {
		return a
	}
	return "localhost:" + testdb.Env("OPENFGA_GRPC_PORT", "8081")
}

var (
	once   sync.Once
	client openfgav1.OpenFGAServiceClient
	err    error
)

// Client returns a process-wide gRPC client to the oracle. The
// stock generated client is goroutine-safe and already satisfies
// the upstream test runners' ClientInterface.
func Client(t testing.TB) openfgav1.OpenFGAServiceClient {
	t.Helper()
	once.Do(func() {
		var conn *grpc.ClientConn
		conn, err = grpc.NewClient(
			Addr(),
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err == nil {
			client = openfgav1.NewOpenFGAServiceClient(conn)
		}
	})
	if err != nil {
		t.Fatalf(
			"cannot dial the oracle at %s: %v\n"+
				"is the stack up? run: docker compose up -d --wait",
			Addr(), err,
		)
	}
	return client
}
