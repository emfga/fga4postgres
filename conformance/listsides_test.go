package conformance

// Helpers for differential tests that also call the list APIs.

import (
	"context"
	"strconv"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// listClient is the probe surface plus the two list APIs.
type listClient interface {
	probeClient
	ListObjects(ctx context.Context,
		in *openfgav1.ListObjectsRequest, opts ...grpc.CallOption,
	) (*openfgav1.ListObjectsResponse, error)
	ListUsers(ctx context.Context,
		in *openfgav1.ListUsersRequest, opts ...grpc.CallOption,
	) (*openfgav1.ListUsersResponse, error)
}

type listSide struct {
	name   string
	client listClient
}

func listSides(t *testing.T, suite string) []listSide {
	return []listSide{
		{"engine", sqlclient.New(
			testdb.Pool(t), uuidmap.New("sides/"+suite))},
		{"oracle", oracle.Client(t)},
	}
}

// kv builds a map from alternating keys and values.
func kv(pairs ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i < len(pairs); i += 2 {
		m[pairs[i].(string)] = pairs[i+1]
	}
	return m
}

func toStruct(t testing.TB, m map[string]any) *structpb.Struct {
	t.Helper()
	if m == nil {
		return nil
	}
	s, err := structpb.NewStruct(m)
	if err != nil {
		t.Fatalf("struct: %v", err)
	}
	return s
}

// condTK is a tuple key carrying a condition (none when name is
// empty).
func condTK(t testing.TB, obj, rel, user, name string,
	ctx map[string]any,
) *openfgav1.TupleKey {
	x := tk(obj, rel, user)
	if name != "" {
		x.Condition = &openfgav1.RelationshipCondition{
			Name: name, Context: toStruct(t, ctx)}
	}
	return x
}

// outcome renders an answer or a refusal as one comparable string.
func outcome(allowed bool, err error) string {
	if err != nil {
		s, _ := status.FromError(err)
		return strconv.Itoa(int(s.Code()))
	}
	return strconv.FormatBool(allowed)
}
