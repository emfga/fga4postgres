package conformance

import (
	"context"
	"fmt"
	"sort"
	"strings"
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

// gateClient extends the probe surface with Read — the two
// methods this file exercises beyond the shared probeClient.
type gateClient interface {
	probeClient
	Read(ctx context.Context, in *openfgav1.ReadRequest,
		opts ...grpc.CallOption) (*openfgav1.ReadResponse, error)
}

func gateSides(t *testing.T, suite string) map[string]gateClient {
	return map[string]gateClient{
		"engine": sqlclient.New(
			testdb.Pool(t), uuidmap.New("gates/"+suite)),
		"oracle": oracle.Client(t),
	}
}

const gatesDSL = `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user, user:*, doc#viewer]
    define bound: [user with icond]

condition icond(x: int) {
  x > 0
}
`

// The write/delete refusal matrix, every rule asserted
// differentially — the same request against both engines must
// refuse with the same code (or succeed on both).
func TestWriteGateMatrix(t *testing.T) {
	ctx := context.Background()

	condTuple := func(c map[string]any) *openfgav1.TupleKey {
		x := tk("doc:1", "bound", "user:anne")
		x.Condition = &openfgav1.RelationshipCondition{
			Name: "icond",
		}
		if c != nil {
			v, err := structpb.NewStruct(c)
			if err != nil {
				t.Fatalf("struct: %v", err)
			}
			x.Condition.Context = v
		}
		return x
	}

	var many []*openfgav1.TupleKey
	for i := 0; i < 101; i++ {
		many = append(many, tk("doc:1", "viewer",
			fmt.Sprintf("user:u%d", i)))
	}

	w := func(tks ...*openfgav1.TupleKey,
	) *openfgav1.WriteRequestWrites {
		return &openfgav1.WriteRequestWrites{TupleKeys: tks}
	}
	del := func(object, relation, user string,
	) *openfgav1.WriteRequestDeletes {
		return &openfgav1.WriteRequestDeletes{
			TupleKeys: []*openfgav1.TupleKeyWithoutCondition{{
				Object: object, Relation: relation, User: user,
			}},
		}
	}

	cases := []struct {
		name     string
		writes   *openfgav1.WriteRequestWrites
		deletes  *openfgav1.WriteRequestDeletes
		wantCode int
	}{
		{"cap 101 operations", w(many...), nil, 2053},
		{"duplicate within writes", w(
			tk("doc:2", "viewer", "user:anne"),
			tk("doc:2", "viewer", "user:anne")), nil, 2004},
		{"same key in writes and deletes", w(
			tk("doc:3", "viewer", "user:anne")),
			del("doc:3", "viewer", "user:anne"), 2004},
		{"empty request", nil, nil, 2003},
		{"delete missing tuple", nil,
			del("doc:9", "viewer", "user:ghost"), 2017},
		{"delete missing on_missing=ignore", nil,
			&openfgav1.WriteRequestDeletes{
				TupleKeys: []*openfgav1.
					TupleKeyWithoutCondition{{
					Object: "doc:9", Relation: "viewer",
					User: "user:ghost"}},
				OnMissing: "ignore"}, 0},
		{"bogus on_duplicate", &openfgav1.WriteRequestWrites{
			TupleKeys: []*openfgav1.TupleKey{
				tk("doc:5", "viewer", "user:anne")},
			OnDuplicate: "bogus"}, nil, 2000},
		{"implicit tuple", w(
			tk("doc:1", "viewer", "doc:1#viewer")), nil, 2000},
		{"object typed wildcard", w(
			tk("doc:*", "viewer", "user:anne")), nil, 2000},
		{"wildcard subject with relation", w(
			tk("doc:1", "viewer", "user:*#viewer")), nil, 2000},
		{"subject trailing hash", w(
			tk("doc:1", "viewer", "user:a#")), nil, 2000},
		{"type-only user", w(
			tk("doc:1", "viewer", "user:")), nil, 2000},
		{"relation undefined", w(
			tk("doc:1", "ghost", "user:anne")), nil, 2000},
		{"subject not admitted", w(
			tk("doc:1", "bound", "doc:2#viewer")), nil, 2000},
		{"condition not admitted for facet", w(func() *openfgav1.TupleKey {
			x := tk("doc:1", "viewer", "user:anne")
			x.Condition = &openfgav1.RelationshipCondition{
				Name: "icond"}
			return x
		}()), nil, 2000},
		{"condition undefined", w(func() *openfgav1.TupleKey {
			x := tk("doc:1", "bound", "user:anne")
			x.Condition = &openfgav1.RelationshipCondition{
				Name: "ghost"}
			return x
		}()), nil, 2000},
		{"condition missing", w(
			tk("doc:1", "bound", "user:anne")), nil, 2000},
		{"undeclared context parameter", w(condTuple(
			map[string]any{"x": 1, "ghost": 2})), nil, 2000},
		{"uncoercible parameter value", w(condTuple(
			map[string]any{"x": "not-an-int"})), nil, 2000},
		{"tab in context string value", w(condTuple(
			map[string]any{"x": 1, "s": "a\tb"})), nil, 2000},
		{"newline in context key", w(condTuple(
			map[string]any{"x": 1, "k\ny": "v"})), nil, 2000},
		{"declared coercible parameter", w(condTuple(
			map[string]any{"x": 5})), nil, 0},
		{"object 257 total", w(tk(
			"doc:"+strings.Repeat("a", 253), "viewer",
			"user:anne")), nil, 3},
		{"user 513 total", w(tk("doc:1", "viewer",
			"user:"+strings.Repeat("b", 508))), nil, 3},
		{"relation 51 chars", w(tk("doc:1",
			strings.Repeat("r", 51), "user:anne")), nil, 3},
	}

	for name, client := range gateSides(t, "writegates") {
		t.Run(name, func(t *testing.T) {
			store, model := setup(t, client, gatesDSL, nil)
			for _, tc := range cases {
				_, err := client.Write(ctx,
					&openfgav1.WriteRequest{
						StoreId:              store,
						AuthorizationModelId: model,
						Writes:               tc.writes,
						Deletes:              tc.deletes,
					})
				got := 0
				if err != nil {
					s, _ := status.FromError(err)
					got = int(s.Code())
				}
				if got != tc.wantCode {
					t.Errorf("%s: got code %d, want %d (err %v)",
						tc.name, got, tc.wantCode, err)
				}
			}
		})
	}
}

// on_duplicate semantics: ignore tolerates the identical
// row; a same-key row with a different condition aborts (gRPC
// 10) even under ignore; the plain duplicate stays 2017.
func TestWriteOnDuplicate(t *testing.T) {
	ctx := context.Background()
	for name, client := range gateSides(t, "ondup") {
		t.Run(name, func(t *testing.T) {
			store, model := setup(t, client, gatesDSL,
				[]*openfgav1.TupleKey{
					tk("doc:1", "viewer", "user:anne")})
			write := func(onDup string,
				tuple *openfgav1.TupleKey,
			) int {
				_, err := client.Write(ctx,
					&openfgav1.WriteRequest{
						StoreId:              store,
						AuthorizationModelId: model,
						Writes: &openfgav1.WriteRequestWrites{
							TupleKeys: []*openfgav1.TupleKey{
								tuple},
							OnDuplicate: onDup,
						},
					})
				if err == nil {
					return 0
				}
				s, _ := status.FromError(err)
				return int(s.Code())
			}

			if got := write("",
				tk("doc:1", "viewer", "user:anne")); got != 2017 {
				t.Errorf("plain duplicate: got %d, want 2017",
					got)
			}
			if got := write("ignore",
				tk("doc:1", "viewer", "user:anne")); got != 0 {
				t.Errorf("ignore duplicate: got %d, want 0", got)
			}
			condTK := tk("doc:1", "viewer", "user:anne")
			condTK.Condition = &openfgav1.RelationshipCondition{
				Name: "icond"}
			// The facet [user] admits no condition, so route the
			// conflict through a conditioned facet instead.
			condTK = tk("doc:2", "bound", "user:anne")
			condTK.Condition = &openfgav1.RelationshipCondition{
				Name: "icond"}
			if got := write("", condTK); got != 0 {
				t.Fatalf("seed conditioned row: got %d", got)
			}
			v, _ := structpb.NewStruct(map[string]any{"x": 7})
			condTK2 := tk("doc:2", "bound", "user:anne")
			condTK2.Condition = &openfgav1.RelationshipCondition{
				Name: "icond", Context: v}
			if got := write("ignore", condTK2); got != 10 {
				t.Errorf("condition conflict under ignore: "+
					"got %d, want 10", got)
			}
			if got := write("ignore", condTK); got != 0 {
				t.Errorf("identical conditioned row under "+
					"ignore: got %d, want 0", got)
			}
		})
	}
}

// fga.read against upstream's Read: filters, refusals, and
// pagination completeness. Timestamps are not compared (each
// engine stamps its own writes).
func TestReadDifferential(t *testing.T) {
	ctx := context.Background()

	tuples := []*openfgav1.TupleKey{
		tk("doc:1", "viewer", "user:anne"),
		tk("doc:1", "viewer", "user:bob"),
		tk("doc:1", "viewer", "user:*"),
		tk("doc:2", "viewer", "user:anne"),
		tk("doc:2", "viewer", "doc:1#viewer"),
	}

	keyStrings := func(resp *openfgav1.ReadResponse) []string {
		var out []string
		for _, tup := range resp.GetTuples() {
			k := tup.GetKey()
			out = append(out, k.GetObject()+"#"+
				k.GetRelation()+"@"+k.GetUser())
		}
		sort.Strings(out)
		return out
	}

	filters := []struct {
		name string
		tk   *openfgav1.ReadRequestTupleKey
	}{
		{"no filter", nil},
		{"full object", &openfgav1.ReadRequestTupleKey{
			Object: "doc:1"}},
		{"object and relation", &openfgav1.ReadRequestTupleKey{
			Object: "doc:1", Relation: "viewer"}},
		{"object and user", &openfgav1.ReadRequestTupleKey{
			Object: "doc:1", User: "user:anne"}},
		{"type-only object and user",
			&openfgav1.ReadRequestTupleKey{
				Object: "doc:", User: "user:anne"}},
		{"userset user filter", &openfgav1.ReadRequestTupleKey{
			Object: "doc:", User: "doc:1#viewer"}},
		{"wildcard user filter", &openfgav1.ReadRequestTupleKey{
			Object: "doc:", User: "user:*"}},
	}
	refusals := []struct {
		name     string
		tk       *openfgav1.ReadRequestTupleKey
		token    string
		wantCode int
	}{
		{"type-only object alone",
			&openfgav1.ReadRequestTupleKey{Object: "doc:"},
			"", 2000},
		{"relation without object",
			&openfgav1.ReadRequestTupleKey{Relation: "viewer"},
			"", 2000},
		{"user only", &openfgav1.ReadRequestTupleKey{
			User: "user:anne"}, "", 2000},
		{"garbage token", &openfgav1.ReadRequestTupleKey{
			Object: "doc:1"}, "not-a-token", 2007},
	}

	results := map[string]map[string][]string{}
	for name, client := range gateSides(t, "read") {
		t.Run(name, func(t *testing.T) {
			store, _ := setup(t, client, gatesDSL, tuples)
			results[name] = map[string][]string{}
			for _, f := range filters {
				resp, err := client.Read(ctx,
					&openfgav1.ReadRequest{
						StoreId: store, TupleKey: f.tk})
				if err != nil {
					t.Errorf("%s: unexpected error %v",
						f.name, err)
					continue
				}
				results[name][f.name] = keyStrings(resp)
			}
			for _, r := range refusals {
				_, err := client.Read(ctx, &openfgav1.ReadRequest{
					StoreId: store, TupleKey: r.tk,
					ContinuationToken: r.token})
				s, _ := status.FromError(err)
				if int(s.Code()) != r.wantCode {
					t.Errorf("%s: got code %d, want %d",
						r.name, int(s.Code()), r.wantCode)
				}
			}

			// Keyset pagination: pages of 2 must union to the
			// full set without loss or repetition.
			var (
				got   []string
				token string
			)
			for range 10 {
				resp, err := client.Read(ctx,
					&openfgav1.ReadRequest{
						StoreId:           store,
						PageSize:          wrapInt32(2),
						ContinuationToken: token,
					})
				if err != nil {
					t.Fatalf("paged read: %v", err)
				}
				got = append(got, keyStrings(resp)...)
				token = resp.GetContinuationToken()
				if token == "" {
					break
				}
			}
			sort.Strings(got)
			want := results[name]["no filter"]
			if strings.Join(got, "\n") !=
				strings.Join(want, "\n") {
				t.Errorf("paged union mismatch:\n got %v\nwant %v",
					got, want)
			}
		})
	}

	if len(results["engine"]) > 0 && len(results["oracle"]) > 0 {
		for _, f := range filters {
			e := strings.Join(results["engine"][f.name], "\n")
			o := strings.Join(results["oracle"][f.name], "\n")
			if e != o {
				t.Errorf("filter %q: engine %v, oracle %v",
					f.name, results["engine"][f.name],
					results["oracle"][f.name])
			}
		}
	}
}

// The CONFIG-* model validation matrix, asserted
// differentially: raw protos so the DSL parser cannot
// pre-empt either server. Every rule must refuse with the same
// code on both engines (2056 from validation, 3 from the proto
// shape).
func TestModelGateMatrix(t *testing.T) {
	ctx := context.Background()

	this := &openfgav1.Userset{
		Userset: &openfgav1.Userset_This{
			This: &openfgav1.DirectUserset{}}}
	computed := func(rel string) *openfgav1.Userset {
		return &openfgav1.Userset{
			Userset: &openfgav1.Userset_ComputedUserset{
				ComputedUserset: &openfgav1.ObjectRelation{
					Relation: rel}}}
	}
	userRef := []*openfgav1.RelationReference{{Type: "user"}}
	userType := &openfgav1.TypeDefinition{Type: "user"}
	docType := func(rels map[string]*openfgav1.Userset,
		meta map[string]*openfgav1.RelationMetadata,
	) *openfgav1.TypeDefinition {
		return &openfgav1.TypeDefinition{
			Type: "doc", Relations: rels,
			Metadata: &openfgav1.Metadata{Relations: meta},
		}
	}
	ttu := func(tupleset, rel string) *openfgav1.Userset {
		return &openfgav1.Userset{
			Userset: &openfgav1.Userset_TupleToUserset{
				TupleToUserset: &openfgav1.TupleToUserset{
					Tupleset: &openfgav1.ObjectRelation{
						Relation: tupleset},
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: rel}}}}
	}
	folderType := &openfgav1.TypeDefinition{
		Type: "folder",
		Relations: map[string]*openfgav1.Userset{
			"viewer": this},
		Metadata: &openfgav1.Metadata{
			Relations: map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef}}},
	}
	folderRef := func(ref *openfgav1.RelationReference,
	) *openfgav1.RelationMetadata {
		return &openfgav1.RelationMetadata{
			DirectlyRelatedUserTypes: []*openfgav1.
				RelationReference{ref}}
	}

	cases := []struct {
		name     string
		tds      []*openfgav1.TypeDefinition
		conds    map[string]*openfgav1.Condition
		version  string
		wantCode int
	}{
		{"valid baseline", []*openfgav1.TypeDefinition{
			userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {
						DirectlyRelatedUserTypes: userRef}},
			)}, nil, "1.1", 0},
		{"reserved relation name self",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"self": this},
				map[string]*openfgav1.RelationMetadata{
					"self": {
						DirectlyRelatedUserTypes: userRef}},
			)}, nil, "1.1", 2056},
		{"reserved type name this",
			[]*openfgav1.TypeDefinition{userType, {
				Type: "this",
				Relations: map[string]*openfgav1.Userset{
					"viewer": this},
				Metadata: &openfgav1.Metadata{
					Relations: map[string]*openfgav1.
						RelationMetadata{"viewer": {
						DirectlyRelatedUserTypes: userRef}}},
			}}, nil, "1.1", 2056},
		{"undefined condition in restriction",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": folderRef(
						&openfgav1.RelationReference{
							Type: "user", Condition: "ghost"})},
			)}, nil, "1.1", 2056},
		{"undefined type in restriction",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": folderRef(
						&openfgav1.RelationReference{
							Type: "ghost"})},
			)}, nil, "1.1", 2056},
		{"rewrite names undefined relation",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{
					"viewer": computed("ghost")},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {}},
			)}, nil, "1.1", 2056},
		{"rewrite names itself",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{
					"viewer": computed("viewer")},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {}},
			)}, nil, "1.1", 2056},
		{"two-relation rewrite cycle",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{
					"a": computed("b"), "b": computed("a")},
				map[string]*openfgav1.RelationMetadata{
					"a": {}, "b": {}},
			)}, nil, "1.1", 2056},
		{"assignable relation with no restrictions",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {}},
			)}, nil, "1.1", 2056},
		{"single-operand intersection",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{
					"viewer": {Userset: &openfgav1.
						Userset_Intersection{
						Intersection: &openfgav1.Usersets{
							Child: []*openfgav1.Userset{
								this}}}}},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {
						DirectlyRelatedUserTypes: userRef}},
			)}, nil, "1.1", 2056},
		{"tupleset admits userset",
			[]*openfgav1.TypeDefinition{userType, folderType,
				docType(
					map[string]*openfgav1.Userset{
						"parent": this,
						"viewer": ttu("parent", "viewer")},
					map[string]*openfgav1.RelationMetadata{
						"parent": folderRef(
							&openfgav1.RelationReference{
								Type: "folder",
								RelationOrWildcard: &openfgav1.
									RelationReference_Relation{
									Relation: "viewer"}}),
						"viewer": {}},
				)}, nil, "1.1", 2056},
		{"tupleset admits wildcard",
			[]*openfgav1.TypeDefinition{userType, folderType,
				docType(
					map[string]*openfgav1.Userset{
						"parent": this,
						"viewer": ttu("parent", "viewer")},
					map[string]*openfgav1.RelationMetadata{
						"parent": folderRef(
							&openfgav1.RelationReference{
								Type: "folder",
								RelationOrWildcard: &openfgav1.
									RelationReference_Wildcard{
									Wildcard: &openfgav1.
										Wildcard{}}}),
						"viewer": {}},
				)}, nil, "1.1", 2056},
		{"tupleset rewrites (not direct)",
			[]*openfgav1.TypeDefinition{userType, folderType,
				docType(
					map[string]*openfgav1.Userset{
						"owner":  this,
						"parent": computed("owner"),
						"viewer": ttu("parent", "viewer")},
					map[string]*openfgav1.RelationMetadata{
						"owner": folderRef(
							&openfgav1.RelationReference{
								Type: "folder"}),
						"parent": {}, "viewer": {}},
				)}, nil, "1.1", 2056},
		{"condition does not compile",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {
						DirectlyRelatedUserTypes: userRef}},
			)},
			map[string]*openfgav1.Condition{
				"c1": {Name: "c1", Expression: "((("}},
			"1.1", 2056},
		{"single-operand union",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{
					"viewer": {Userset: &openfgav1.
						Userset_Union{
						Union: &openfgav1.Usersets{
							Child: []*openfgav1.Userset{
								this}}}}},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {
						DirectlyRelatedUserTypes: userRef}},
			)}, nil, "1.1", 2056},
		{"condition key does not match name",
			[]*openfgav1.TypeDefinition{userType, docType(
				map[string]*openfgav1.Userset{"viewer": this},
				map[string]*openfgav1.RelationMetadata{
					"viewer": {
						DirectlyRelatedUserTypes: userRef}},
			)},
			map[string]*openfgav1.Condition{
				"c1": {Name: "c2", Expression: "true"}},
			"1.1", 2056},
		{"schema version 1.0",
			[]*openfgav1.TypeDefinition{userType},
			nil, "1.0", 2056},
	}

	for name, client := range gateSides(t, "modelgates") {
		t.Run(name, func(t *testing.T) {
			for _, tc := range cases {
				store, err := client.CreateStore(ctx,
					&openfgav1.CreateStoreRequest{
						Name: t.Name()})
				if err != nil {
					t.Fatalf("create store: %v", err)
				}
				_, err = client.WriteAuthorizationModel(ctx,
					&openfgav1.WriteAuthorizationModelRequest{
						StoreId:         store.GetId(),
						SchemaVersion:   tc.version,
						TypeDefinitions: tc.tds,
						Conditions:      tc.conds,
					})
				got := 0
				if err != nil {
					s, _ := status.FromError(err)
					got = int(s.Code())
				}
				if got != tc.wantCode {
					t.Errorf("%s: got code %d, want %d (err %v)",
						tc.name, got, tc.wantCode, err)
				}
			}
		})
	}
}
