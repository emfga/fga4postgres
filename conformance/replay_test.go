package conformance

import (
	"context"
	"fmt"
	"hash/fnv"
	"math/rand"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/skiplist"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// The YAML replayer, mirroring upstream's runner contract:
// every test runs twice — once normal,
// once with the stage tuples handed as contextual tuples; fresh
// store per test on both engines; tuples seeded-shuffled and
// written in chunks of 40; assertions checked against the corpus
// expectation on BOTH engines, which is also the differential
// assert (both sides must land on the same answer to both pass).

const writeChunk = 40

// caseRand derives a per-case shuffle source from the suite seed
// (printed by TestMain) and the case name, so one failing case
// reproduces without replaying the whole file.
func caseRand(name string) *rand.Rand {
	h := fnv.New64a()
	fmt.Fprintf(h, "%d/%s", suiteSeed, name)
	return rand.New(rand.NewSource(int64(h.Sum64())))
}

func shuffledTuples(
	rng *rand.Rand, in []*openfgav1.TupleKey,
) []*openfgav1.TupleKey {
	out := make([]*openfgav1.TupleKey, len(in))
	copy(out, in)
	rng.Shuffle(len(out), func(i, j int) {
		out[i], out[j] = out[j], out[i]
	})
	return out
}

// replayMode is how a corpus case is replayed: normal, with the
// stage tuples handed as contextual tuples (upstream's own second
// run), or answered by the store's compiled relation functions.
type replayMode int

const (
	modeNormal replayMode = iota
	modeCtxTuples
	modeCompiled
)

// engineForCase builds the sqlclient with a per-file uuid map —
// deterministic across runs, disjoint across files. In compiled
// mode the client opts every store in and answers through the
// generated functions.
func engineForCase(
	t *testing.T, file string, mode replayMode,
) probeClient {
	ids := uuidmap.New("yaml/" + file)
	if mode == modeCompiled {
		return sqlclient.NewCompiled(testdb.Pool(t), ids)
	}
	return sqlclient.New(testdb.Pool(t), ids)
}

func engineName(mode replayMode) string {
	if mode == modeCompiled {
		return "compiled"
	}
	return "engine"
}

// storeDeleter is the engine clients' cleanup hook.
type storeDeleter interface {
	DeleteStore(ctx context.Context, storeID string) error
}

var delegatedVia = regexp.MustCompile(`^reaches \S+ \((.*)\)$`)

// reportDelegated names, through the skip register, every relation
// of the stage's model the generator left on the delegated
// strategy: its answers still come from a generated function, but
// one that calls the generic resolver, so the compiled strategies
// are not what this case exercised for it.
func reportDelegated(t *testing.T, engine *side) {
	t.Helper()
	rows, err := testdb.Pool(t).Query(context.Background(), `
		SELECT type_name || '#' || relation_name, reason
		FROM fga.compiled_relation
		WHERE store = $1 AND model_id = $2
		  AND strategy = 'delegated'
		ORDER BY 1`, engine.storeID, engine.modelID)
	if err != nil {
		t.Fatal(err)
	}
	type entry struct{ rel, reason string }
	var delegated []entry
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.rel, &e.reason); err != nil {
			t.Fatal(err)
		}
		delegated = append(delegated, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	for _, e := range delegated {
		reason := e.reason
		if m := delegatedVia.FindStringSubmatch(reason); m != nil {
			reason = "depends on a delegated relation: " + m[1]
		}
		t.Run("delegated/"+e.rel, func(t *testing.T) {
			skiplist.Skip(t, "compiled: relation delegated to the "+
				"generic resolver: "+reason)
		})
	}
}

// reportGeneric records, after a compiled-mode assertion, what the
// compiled path did not answer itself.
func reportGeneric(
	t *testing.T, engine *side, ctxTuples bool,
) {
	t.Helper()
	c, ok := engine.client.(*sqlclient.Compiled)
	if !ok {
		return
	}
	if len(c.TakeGeneric()) > 0 {
		t.Run("generic_validation", func(t *testing.T) {
			skiplist.Skip(t, "compiled: request refused by the "+
				"generic API's validation (no generated function "+
				"takes request strings)")
		})
	}
	if ctxTuples {
		t.Run("contextual_tuples", func(t *testing.T) {
			skiplist.Skip(t, "compiled: contextual tuples take "+
				"the delegated path (P1.6)")
		})
	}
}

type side struct {
	name    string
	client  probeClient
	storeID string
	modelID string
}

func runCheckReplay(
	t *testing.T, file string, tc corpus.Test, mode replayMode,
) {
	ctx := context.Background()
	rng := caseRand(t.Name())
	ctxVariant := mode == modeCtxTuples

	if ctxVariant {
		if len(tc.Stages) > 1 {
			skiplist.Skip(t, "ctxTuples variant skips multi-stage "+
				"tests (upstream contract)")
		}
		for _, s := range tc.Stages {
			if len(s.Tuples) > 100 {
				skiplist.Skip(t, "ctxTuples variant skips stages "+
					"over 100 tuples (API cap)")
			}
		}
	}

	sides := []*side{
		{name: engineName(mode), client: engineForCase(t, file, mode)},
		{name: "oracle", client: oracle.Client(t)},
	}
	for _, s := range sides {
		resp, err := s.client.CreateStore(ctx,
			&openfgav1.CreateStoreRequest{Name: tc.Name})
		if err != nil {
			t.Fatalf("%s: create store: %v", s.name, err)
		}
		s.storeID = resp.GetId()
	}
	t.Cleanup(func() {
		_ = sides[0].client.(storeDeleter).
			DeleteStore(ctx, sides[0].storeID)
		_, _ = oracle.Client(t).DeleteStore(ctx,
			&openfgav1.DeleteStoreRequest{StoreId: sides[1].storeID})
	})

	for stageNum, stage := range tc.Stages {
		st := stage
		t.Run(fmt.Sprintf("stage_%d", stageNum), func(t *testing.T) {
			writeStageBoth(t, rng, sides, st, ctxVariant)
			if mode == modeCompiled {
				reportDelegated(t, sides[0])
			}
			for i, a := range st.CheckAssertions {
				name := a.Name
				if name == "" {
					name = fmt.Sprintf("assertion_%d", i)
				}
				assertion := a
				t.Run(name, func(t *testing.T) {
					runCheckAssertion(
						t, rng, sides, st, assertion, ctxVariant)
					reportGeneric(t, sides[0],
						len(assertion.ContextualTuples) > 0)
				})
			}
		})
	}
}

// writeStageBoth writes one stage's model and tuples to both
// sides. The oracle refusing the model is upstream's own
// modelgraph gate — a named skip, not a failure. In the ctx
// variant tuples are not written; assertions carry them instead.
func writeStageBoth(
	t *testing.T, rng *rand.Rand, sides []*side,
	st *corpus.Stage, ctxVariant bool,
) {
	t.Helper()
	ctx := context.Background()
	model, err := parser.TransformDSLToProto(st.Model)
	if err != nil {
		t.Fatalf("model DSL: %v", err)
	}
	for _, s := range sides {
		resp, err := s.client.WriteAuthorizationModel(ctx,
			&openfgav1.WriteAuthorizationModelRequest{
				StoreId:         s.storeID,
				SchemaVersion:   model.GetSchemaVersion(),
				TypeDefinitions: model.GetTypeDefinitions(),
				Conditions:      model.GetConditions(),
			})
		if err != nil {
			if s.name == "oracle" {
				skiplist.Skip(t,
					"oracle refused the stage model: "+err.Error())
			}
			t.Fatalf("%s: write model: %v", s.name, err)
		}
		s.modelID = resp.GetAuthorizationModelId()
	}

	if !ctxVariant && len(st.Tuples) > 0 {
		tuples := shuffledTuples(rng, st.Tuples)
		for start := 0; start < len(tuples); start += writeChunk {
			end := min(start+writeChunk, len(tuples))
			for _, s := range sides {
				_, err := s.client.Write(ctx,
					&openfgav1.WriteRequest{
						StoreId:              s.storeID,
						AuthorizationModelId: s.modelID,
						Writes: &openfgav1.WriteRequestWrites{
							TupleKeys: tuples[start:end],
						},
					})
				if err != nil {
					t.Fatalf("%s: write tuples [%d:%d] "+
						"(seed %d): %v",
						s.name, start, end, suiteSeed, err)
				}
			}
		}
	}
}

// runListObjectsReplay mirrors the upstream listobjects runner:
// unary set-compare per assertion, plus a confirming Check for
// every returned object, as upstream's runner does. The
// streamed variant
// is exercised implicitly — the sqlclient adapts it over the same
// unary path — so it carries no separate assert here.
func runListObjectsReplay(
	t *testing.T, file string, tc corpus.Test, mode replayMode,
) {
	ctx := context.Background()
	rng := caseRand(t.Name())
	ctxVariant := mode == modeCtxTuples

	if ctxVariant {
		if len(tc.Stages) > 1 {
			skiplist.Skip(t, "ctxTuples variant skips multi-stage "+
				"tests (upstream contract)")
		}
		for _, s := range tc.Stages {
			if len(s.Tuples) > 100 {
				skiplist.Skip(t, "ctxTuples variant skips stages "+
					"over 100 tuples (API cap)")
			}
		}
	}

	sides := []*side{
		{name: engineName(mode), client: engineForCase(t, file, mode)},
		{name: "oracle", client: oracle.Client(t)},
	}
	for _, s := range sides {
		resp, err := s.client.CreateStore(ctx,
			&openfgav1.CreateStoreRequest{Name: tc.Name})
		if err != nil {
			t.Fatalf("%s: create store: %v", s.name, err)
		}
		s.storeID = resp.GetId()
	}
	t.Cleanup(func() {
		_ = sides[0].client.(storeDeleter).
			DeleteStore(ctx, sides[0].storeID)
		_, _ = oracle.Client(t).DeleteStore(ctx,
			&openfgav1.DeleteStoreRequest{StoreId: sides[1].storeID})
	})

	for stageNum, stage := range tc.Stages {
		st := stage
		t.Run(fmt.Sprintf("stage_%d", stageNum), func(t *testing.T) {
			writeStageBoth(t, rng, sides, st, ctxVariant)
			if mode == modeCompiled {
				reportDelegated(t, sides[0])
			}
			for i, a := range st.ListObjectsAssertions {
				assertion := a
				t.Run(fmt.Sprintf("assertion_%d", i),
					func(t *testing.T) {
						runListObjectsAssertion(
							t, rng, sides, st, assertion, ctxVariant)
						reportGeneric(t, sides[0],
							len(assertion.ContextualTuples) > 0)
					})
			}
		})
	}
}

func runListObjectsAssertion(
	t *testing.T, rng *rand.Rand, sides []*side,
	stage *corpus.Stage, a *corpus.ListObjectsAssertion,
	ctxVariant bool,
) {
	ctx := context.Background()

	ctxTuples := a.ContextualTuples
	if ctxVariant {
		ctxTuples = append(append([]*openfgav1.TupleKey{},
			ctxTuples...), stage.Tuples...)
	}
	ctxTuples = shuffledTuples(rng, ctxTuples)

	for _, s := range sides {
		req := proto.Clone(a.Request).(*openfgav1.ListObjectsRequest)
		req.StoreId = s.storeID
		req.AuthorizationModelId = s.modelID
		req.Context = a.Context
		if len(ctxTuples) > 0 {
			keys := make([]*openfgav1.TupleKey, len(ctxTuples))
			for i, ct := range ctxTuples {
				keys[i] = proto.Clone(ct).(*openfgav1.TupleKey)
			}
			req.ContextualTuples = &openfgav1.ContextualTupleKeys{
				TupleKeys: keys,
			}
		}

		resp, err := s.client.(interface {
			ListObjects(context.Context,
				*openfgav1.ListObjectsRequest,
				...grpc.CallOption,
			) (*openfgav1.ListObjectsResponse, error)
		}).ListObjects(ctx, req)

		if a.ErrorCode != 0 {
			if err == nil {
				t.Errorf("%s: want error code %d, got %v",
					s.name, a.ErrorCode, resp.GetObjects())
				continue
			}
			st2, _ := status.FromError(err)
			if int(st2.Code()) != a.ErrorCode {
				t.Errorf("%s: error code %d, want %d (%v)",
					s.name, int(st2.Code()), a.ErrorCode, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error (seed %d): %v",
				s.name, suiteSeed, err)
			continue
		}
		got := append([]string{}, resp.GetObjects()...)
		want := append([]string{}, a.Expectation...)
		sort.Strings(got)
		sort.Strings(want)
		if !slices.Equal(got, want) {
			t.Errorf("%s: objects %v, want %v (seed %d)",
				s.name, got, want, suiteSeed)
			continue
		}

		// Every returned object must also check true.
		for _, obj := range resp.GetObjects() {
			cr, err := s.client.Check(ctx, &openfgav1.CheckRequest{
				StoreId:              s.storeID,
				AuthorizationModelId: s.modelID,
				TupleKey: &openfgav1.CheckRequestTupleKey{
					Object:   obj,
					Relation: a.Request.GetRelation(),
					User:     a.Request.GetUser(),
				},
				Context:          a.Context,
				ContextualTuples: req.GetContextualTuples(),
			})
			if err != nil || !cr.GetAllowed() {
				t.Errorf("%s: confirming check for %s: "+
					"allowed=%v err=%v",
					s.name, obj, cr.GetAllowed(), err)
			}
		}
	}
}

// runListUsersReplay mirrors the upstream listusers runner:
// set-compare the formatted users against the expectation.
func runListUsersReplay(
	t *testing.T, file string, tc corpus.Test, mode replayMode,
) {
	ctx := context.Background()
	rng := caseRand(t.Name())
	ctxVariant := mode == modeCtxTuples

	if ctxVariant {
		if len(tc.Stages) > 1 {
			skiplist.Skip(t, "ctxTuples variant skips multi-stage "+
				"tests (upstream contract)")
		}
		for _, s := range tc.Stages {
			if len(s.Tuples) > 100 {
				skiplist.Skip(t, "ctxTuples variant skips stages "+
					"over 100 tuples (API cap)")
			}
		}
	}

	sides := []*side{
		{name: engineName(mode), client: engineForCase(t, file, mode)},
		{name: "oracle", client: oracle.Client(t)},
	}
	for _, s := range sides {
		resp, err := s.client.CreateStore(ctx,
			&openfgav1.CreateStoreRequest{Name: tc.Name})
		if err != nil {
			t.Fatalf("%s: create store: %v", s.name, err)
		}
		s.storeID = resp.GetId()
	}
	t.Cleanup(func() {
		_ = sides[0].client.(storeDeleter).
			DeleteStore(ctx, sides[0].storeID)
		_, _ = oracle.Client(t).DeleteStore(ctx,
			&openfgav1.DeleteStoreRequest{StoreId: sides[1].storeID})
	})

	for stageNum, stage := range tc.Stages {
		st := stage
		t.Run(fmt.Sprintf("stage_%d", stageNum), func(t *testing.T) {
			writeStageBoth(t, rng, sides, st, ctxVariant)
			if mode == modeCompiled {
				reportDelegated(t, sides[0])
			}
			for i, a := range st.ListUsersAssertions {
				assertion := a
				t.Run(fmt.Sprintf("assertion_%d", i),
					func(t *testing.T) {
						if mode == modeCompiled &&
							hasWildcard(assertion.Expectation) {
							skiplist.Skip(t, "compiled: __subjects "+
								"returns the final list, so a wildcard "+
								"answer is compared against per-user "+
								"check over a subject source (P1.8)")
						}
						runListUsersAssertion(
							t, rng, sides, st, assertion, ctxVariant)
						reportGeneric(t, sides[0],
							len(assertion.ContextualTuples) > 0)
					})
			}
		})
	}
}

func hasWildcard(users []string) bool {
	for _, u := range users {
		if strings.HasSuffix(u, ":*") {
			return true
		}
	}
	return false
}

func luFilterProto(f string) *openfgav1.UserTypeFilter {
	typ, rel, ok := strings.Cut(f, "#")
	uf := &openfgav1.UserTypeFilter{Type: typ}
	if ok {
		uf.Relation = rel
	}
	return uf
}

func luUserString(u *openfgav1.User) string {
	switch x := u.GetUser().(type) {
	case *openfgav1.User_Object:
		return x.Object.GetType() + ":" + x.Object.GetId()
	case *openfgav1.User_Userset:
		return x.Userset.GetType() + ":" + x.Userset.GetId() +
			"#" + x.Userset.GetRelation()
	case *openfgav1.User_Wildcard:
		return x.Wildcard.GetType() + ":*"
	}
	return "?"
}

func runListUsersAssertion(
	t *testing.T, rng *rand.Rand, sides []*side,
	stage *corpus.Stage, a *corpus.ListUsersAssertion,
	ctxVariant bool,
) {
	ctx := context.Background()

	ctxTuples := a.ContextualTuples
	if ctxVariant {
		ctxTuples = append(append([]*openfgav1.TupleKey{},
			ctxTuples...), stage.Tuples...)
	}
	ctxTuples = shuffledTuples(rng, ctxTuples)

	objType, objID, _ := strings.Cut(a.Request.Object, ":")
	var filters []*openfgav1.UserTypeFilter
	for _, f := range a.Request.Filters {
		filters = append(filters, luFilterProto(f))
	}

	for _, s := range sides {
		req := &openfgav1.ListUsersRequest{
			StoreId:              s.storeID,
			AuthorizationModelId: s.modelID,
			Object: &openfgav1.Object{
				Type: objType, Id: objID,
			},
			Relation:    a.Request.Relation,
			UserFilters: filters,
			Context:     a.Context,
		}
		if len(ctxTuples) > 0 {
			keys := make([]*openfgav1.TupleKey, len(ctxTuples))
			for i, ct := range ctxTuples {
				keys[i] = proto.Clone(ct).(*openfgav1.TupleKey)
			}
			req.ContextualTuples = keys
		}

		resp, err := s.client.(interface {
			ListUsers(context.Context,
				*openfgav1.ListUsersRequest,
				...grpc.CallOption,
			) (*openfgav1.ListUsersResponse, error)
		}).ListUsers(ctx, req)

		if a.ErrorCode != 0 {
			if err == nil {
				t.Errorf("%s: want error code %d, got %v",
					s.name, a.ErrorCode, resp.GetUsers())
				continue
			}
			st2, _ := status.FromError(err)
			if int(st2.Code()) != a.ErrorCode {
				t.Errorf("%s: error code %d, want %d (%v)",
					s.name, int(st2.Code()), a.ErrorCode, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error (seed %d): %v",
				s.name, suiteSeed, err)
			continue
		}
		var got []string
		for _, u := range resp.GetUsers() {
			got = append(got, luUserString(u))
		}
		want := append([]string{}, a.Expectation...)
		sort.Strings(got)
		sort.Strings(want)
		if !slices.Equal(got, want) {
			t.Errorf("%s: users %v, want %v (seed %d)",
				s.name, got, want, suiteSeed)
		}
	}
}

func runCheckAssertion(
	t *testing.T, rng *rand.Rand, sides []*side,
	stage *corpus.Stage, a *corpus.CheckAssertion,
	ctxVariant bool,
) {
	ctx := context.Background()

	ctxTuples := a.ContextualTuples
	if ctxVariant {
		ctxTuples = append(append([]*openfgav1.TupleKey{},
			ctxTuples...), stage.Tuples...)
	}
	ctxTuples = shuffledTuples(rng, ctxTuples)

	for _, s := range sides {
		var tk *openfgav1.CheckRequestTupleKey
		if a.Tuple != nil {
			tk = &openfgav1.CheckRequestTupleKey{
				Object:   a.Tuple.GetObject(),
				Relation: a.Tuple.GetRelation(),
				User:     a.Tuple.GetUser(),
			}
		}
		req := &openfgav1.CheckRequest{
			StoreId:              s.storeID,
			AuthorizationModelId: s.modelID,
			TupleKey:             tk,
			Context:              a.Context,
		}
		if len(ctxTuples) > 0 {
			keys := make([]*openfgav1.TupleKey, len(ctxTuples))
			for i, ct := range ctxTuples {
				keys[i] = proto.Clone(ct).(*openfgav1.TupleKey)
			}
			req.ContextualTuples = &openfgav1.ContextualTupleKeys{
				TupleKeys: keys,
			}
		}

		resp, err := s.client.Check(ctx, req)
		if a.ErrorCode == 0 {
			if err != nil {
				t.Errorf("%s: unexpected error (seed %d): %v",
					s.name, suiteSeed, err)
				continue
			}
			if resp.GetAllowed() != a.Expectation {
				t.Errorf("%s: allowed=%v, want %v (seed %d)",
					s.name, resp.GetAllowed(), a.Expectation,
					suiteSeed)
			}
			continue
		}
		if err == nil {
			t.Errorf("%s: want error code %d, got allowed=%v",
				s.name, a.ErrorCode, resp.GetAllowed())
			continue
		}
		st, _ := status.FromError(err)
		if int(st.Code()) != a.ErrorCode {
			t.Errorf("%s: error code %d, want %d (%v)",
				s.name, int(st.Code()), a.ErrorCode, err)
		}
	}
}
