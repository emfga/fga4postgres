package conformance

import (
	"context"
	"fmt"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// probeClient is the seven-method surface probes and the replayer
// share, satisfied by both the oracle client and the sqlclient.
type probeClient interface {
	CreateStore(
		ctx context.Context, in *openfgav1.CreateStoreRequest,
		opts ...grpc.CallOption,
	) (*openfgav1.CreateStoreResponse, error)
	WriteAuthorizationModel(
		ctx context.Context,
		in *openfgav1.WriteAuthorizationModelRequest,
		opts ...grpc.CallOption,
	) (*openfgav1.WriteAuthorizationModelResponse, error)
	Write(
		ctx context.Context, in *openfgav1.WriteRequest,
		opts ...grpc.CallOption,
	) (*openfgav1.WriteResponse, error)
	Check(
		ctx context.Context, in *openfgav1.CheckRequest,
		opts ...grpc.CallOption,
	) (*openfgav1.CheckResponse, error)
}

// bothSides returns the two engines for a differential probe: the
// oracle raw, and the sqlclient with a probe-scoped uuid map so
// corpus-style ids work.
func bothSides(t *testing.T, suite string) []side {
	return []side{
		{name: "engine", client: sqlclient.New(
			testdb.Pool(t), uuidmap.New("probe/"+suite))},
		{name: "oracle", client: oracle.Client(t)},
	}
}

// setup creates a fresh store, writes the DSL model, and writes
// the tuples in upstream-sized chunks of 40.
func setup(
	t testing.TB, client probeClient, dsl string,
	tuples []*openfgav1.TupleKey,
) (storeID, modelID string) {
	t.Helper()
	ctx := context.Background()

	store, err := client.CreateStore(
		ctx, &openfgav1.CreateStoreRequest{Name: t.Name()},
	)
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	storeID = store.GetId()

	model, err := parser.TransformDSLToProto(dsl)
	if err != nil {
		t.Fatalf("bad DSL in probe: %v", err)
	}
	wm, err := client.WriteAuthorizationModel(
		ctx, &openfgav1.WriteAuthorizationModelRequest{
			StoreId:         storeID,
			SchemaVersion:   model.GetSchemaVersion(),
			TypeDefinitions: model.GetTypeDefinitions(),
			Conditions:      model.GetConditions(),
		},
	)
	if err != nil {
		t.Fatalf("write model: %v", err)
	}
	modelID = wm.GetAuthorizationModelId()

	for start := 0; start < len(tuples); start += 40 {
		end := min(start+40, len(tuples))
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              storeID,
			AuthorizationModelId: modelID,
			Writes: &openfgav1.WriteRequestWrites{
				TupleKeys: tuples[start:end],
			},
		})
		if err != nil {
			t.Fatalf("write tuples [%d:%d]: %v", start, end, err)
		}
	}
	return storeID, modelID
}

func tk(object, relation, user string) *openfgav1.TupleKey {
	return &openfgav1.TupleKey{
		Object: object, Relation: relation, User: user,
	}
}

type checkResult struct {
	allowed bool
	code    int // gRPC/openfga code; 0 on success
	err     error
}

func (r checkResult) String() string {
	if r.err != nil {
		return fmt.Sprintf("error(code=%d: %v)", r.code, r.err)
	}
	return fmt.Sprintf("allowed=%v", r.allowed)
}

func doCheck(
	t testing.TB, client probeClient, storeID, modelID string,
	object, relation, user string,
	ctxTuples []*openfgav1.TupleKey, reqCtx *structpb.Struct,
) checkResult {
	t.Helper()
	req := &openfgav1.CheckRequest{
		StoreId:              storeID,
		AuthorizationModelId: modelID,
		TupleKey: &openfgav1.CheckRequestTupleKey{
			Object: object, Relation: relation, User: user,
		},
		Context: reqCtx,
	}
	if len(ctxTuples) > 0 {
		req.ContextualTuples = &openfgav1.ContextualTupleKeys{
			TupleKeys: ctxTuples,
		}
	}
	resp, err := client.Check(context.Background(), req)
	if err != nil {
		s, _ := status.FromError(err)
		return checkResult{code: int(s.Code()), err: err}
	}
	return checkResult{allowed: resp.GetAllowed()}
}

// chainGroupsDSL is the userset-dispatch ladder every depth probe
// uses: group:g0..gN with member edges climbing the index.
const chainGroupsDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user, group#member]
`

// groupChain returns tuples linking group:g0..g<n> by member, with
// user:anne at the bottom. Checking group:g<n>#member costs one
// dispatch per link.
func groupChain(n int) []*openfgav1.TupleKey {
	tuples := []*openfgav1.TupleKey{
		tk("group:g0", "member", "user:anne"),
	}
	for i := 1; i <= n; i++ {
		tuples = append(tuples, tk(
			fmt.Sprintf("group:g%d", i), "member",
			fmt.Sprintf("group:g%d#member", i-1),
		))
	}
	return tuples
}

// computedChainDSL builds r0: [user] and r1..r<n> each a computed
// userset of the previous.
func computedChainDSL(n int) string {
	var sb strings.Builder
	sb.WriteString("model\n  schema 1.1\n")
	sb.WriteString("type user\ntype doc\n  relations\n")
	sb.WriteString("    define r0: [user]\n")
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&sb, "    define r%d: r%d\n", i, i-1)
	}
	return sb.String()
}
