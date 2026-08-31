package conformance

import (
	"context"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/wrapperspb"

	"github.com/emfga/fga4postgres/internal/oracle"
)

// M35 — write cap, duplicates, on_duplicate/on_missing.
func TestProbeM35WriteSemantics(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	dsl := `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user, user with xcond]

condition xcond(x: int) {
  x > 0
}
`
	store, model := setup(t, client, dsl, nil)

	write := func(w *openfgav1.WriteRequestWrites,
		d *openfgav1.WriteRequestDeletes,
	) (string, int) {
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Writes:               w, Deletes: d,
		})
		if err == nil {
			return "OK", 0
		}
		s, _ := status.FromError(err)
		return s.Message(), int(s.Code())
	}

	// Cap: 101 total.
	var many []*openfgav1.TupleKey
	for i := 0; i < 101; i++ {
		many = append(many, tk("doc:1", "viewer",
			"user:u"+strings.Repeat("0", 3)+string(rune('a'+i%26))+
				strings.Repeat("x", i/26)))
	}
	msg, code := write(
		&openfgav1.WriteRequestWrites{TupleKeys: many}, nil)
	t.Logf("OBSERVED: 101 writes: code=%d msg=%q", code, msg)

	// Duplicate key within one writes list.
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys: []*openfgav1.TupleKey{
			tk("doc:2", "viewer", "user:anne"),
			tk("doc:2", "viewer", "user:anne"),
		}}, nil)
	t.Logf("OBSERVED: dup within writes: code=%d msg=%q",
		code, msg)

	// Same key in writes and deletes of one request.
	msg, code = write(
		&openfgav1.WriteRequestWrites{
			TupleKeys: []*openfgav1.TupleKey{
				tk("doc:3", "viewer", "user:anne")}},
		&openfgav1.WriteRequestDeletes{
			TupleKeys: []*openfgav1.TupleKeyWithoutCondition{{
				Object: "doc:3", Relation: "viewer",
				User: "user:anne"}}})
	t.Logf("OBSERVED: same key write+delete: code=%d msg=%q",
		code, msg)

	// Plain duplicate of an existing row.
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys: []*openfgav1.TupleKey{
			tk("doc:4", "viewer", "user:anne")}}, nil)
	t.Logf("OBSERVED: first write: code=%d msg=%q", code, msg)
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys: []*openfgav1.TupleKey{
			tk("doc:4", "viewer", "user:anne")}}, nil)
	t.Logf("OBSERVED: duplicate write: code=%d msg=%q", code, msg)

	// on_duplicate=ignore, identical row.
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys: []*openfgav1.TupleKey{
			tk("doc:4", "viewer", "user:anne")},
		OnDuplicate: "ignore"}, nil)
	t.Logf("OBSERVED: dup on_duplicate=ignore: code=%d msg=%q",
		code, msg)

	// on_duplicate=ignore, same key but different condition.
	condTK := tk("doc:4", "viewer", "user:anne")
	condTK.Condition = &openfgav1.RelationshipCondition{
		Name: "xcond",
	}
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys:   []*openfgav1.TupleKey{condTK},
		OnDuplicate: "ignore"}, nil)
	t.Logf("OBSERVED: cond-conflict on_duplicate=ignore: "+
		"code=%d msg=%q", code, msg)

	// Delete missing, plain and ignored.
	msg, code = write(nil, &openfgav1.WriteRequestDeletes{
		TupleKeys: []*openfgav1.TupleKeyWithoutCondition{{
			Object: "doc:9", Relation: "viewer",
			User: "user:ghost"}}})
	t.Logf("OBSERVED: delete missing: code=%d msg=%q", code, msg)
	msg, code = write(nil, &openfgav1.WriteRequestDeletes{
		TupleKeys: []*openfgav1.TupleKeyWithoutCondition{{
			Object: "doc:9", Relation: "viewer",
			User: "user:ghost"}},
		OnMissing: "ignore"})
	t.Logf("OBSERVED: delete missing on_missing=ignore: "+
		"code=%d msg=%q", code, msg)

	// Bad enum value.
	msg, code = write(&openfgav1.WriteRequestWrites{
		TupleKeys: []*openfgav1.TupleKey{
			tk("doc:5", "viewer", "user:anne")},
		OnDuplicate: "bogus"}, nil)
	t.Logf("OBSERVED: on_duplicate=bogus: code=%d msg=%q",
		code, msg)

	// Empty request.
	msg, code = write(nil, nil)
	t.Logf("OBSERVED: empty write request: code=%d msg=%q",
		code, msg)
}

// M39 — the remaining tuple-write gate rules: implicit tuples,
// wildcard shapes, condition context parameter checks, control
// characters.
func TestProbeM39WriteGates(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	dsl := `model
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
	store, model := setup(t, client, dsl, nil)

	try := func(label string, tuple *openfgav1.TupleKey) {
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Writes: &openfgav1.WriteRequestWrites{
				TupleKeys: []*openfgav1.TupleKey{tuple}},
		})
		code, msg := 0, "OK"
		if err != nil {
			s, _ := status.FromError(err)
			code, msg = int(s.Code()), truncate(s.Message(), 140)
		}
		t.Logf("OBSERVED: %s: code=%d msg=%q", label, code, msg)
	}

	// Implicit tuple.
	try("implicit doc:1#viewer@doc:1#viewer",
		tk("doc:1", "viewer", "doc:1#viewer"))
	// Wildcard shapes.
	try("object wildcard doc:*",
		tk("doc:*", "viewer", "user:anne"))
	try("subject wildcard-with-relation user:*#viewer",
		tk("doc:1", "viewer", "user:*#viewer"))
	// Subject with empty relation after #.
	try("subject trailing hash", tk("doc:1", "viewer", "user:a#"))
	// Type-only user.
	try("type-only user", tk("doc:1", "viewer", "user:"))

	condT := func(c map[string]any) *openfgav1.TupleKey {
		v, err := structpb.NewStruct(c)
		if err != nil {
			t.Fatalf("struct: %v", err)
		}
		x := tk("doc:1", "bound", "user:anne")
		x.Condition = &openfgav1.RelationshipCondition{
			Name: "icond", Context: v,
		}
		return x
	}
	// Undeclared context parameter at write.
	try("undeclared context param",
		condT(map[string]any{"x": 1, "ghost": 2}))
	// Value not coercible to the declared type.
	try("uncoercible param value",
		condT(map[string]any{"x": "not-an-int"}))
	// Declared and coercible: the accepted baseline.
	try("declared coercible param",
		condT(map[string]any{"x": 5}))
	// Control character in a context string value / key.
	try("tab in context string value",
		condT(map[string]any{"x": 1, "s": "a\tb"}))
	try("newline in context key",
		condT(map[string]any{"x": 1, "k\ny": "v"}))
	// Condition not admitted for this restriction (viewer has
	// no conditioned facet).
	badFacet := tk("doc:1", "viewer", "user:anne")
	badFacet.Condition = &openfgav1.RelationshipCondition{
		Name: "icond"}
	try("condition not admitted for facet", badFacet)
	// Condition name with forbidden chars (scanned before
	// lookup?).
	dirty := tk("doc:1", "bound", "user:anne")
	dirty.Condition = &openfgav1.RelationshipCondition{
		Name: "no such"}
	try("condition name forbidden chars", dirty)
}

// M25 — tuple field length limits at write time.
func TestProbeM25FieldLengths(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	store, model := setup(t, client, `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user]
`, nil)

	try := func(label, object, relation, user string) {
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Writes: &openfgav1.WriteRequestWrites{
				TupleKeys: []*openfgav1.TupleKey{
					tk(object, relation, user)}},
		})
		code, msg := 0, "OK"
		if err != nil {
			s, _ := status.FromError(err)
			code, msg = int(s.Code()), s.Message()
		}
		t.Logf("OBSERVED: %s: code=%d msg=%q", label, code, msg)
	}

	// object total ("type:id") boundary: 256.
	try("object 256 total",
		"doc:"+strings.Repeat("a", 252), "viewer", "user:anne")
	try("object 257 total",
		"doc:"+strings.Repeat("a", 253), "viewer", "user:anne")
	// user boundary: 512.
	try("user 512 total", "doc:1", "viewer",
		"user:"+strings.Repeat("b", 507))
	try("user 513 total", "doc:1", "viewer",
		"user:"+strings.Repeat("b", 508))
	// relation boundary: 50.
	try("relation 51 chars", "doc:1",
		strings.Repeat("r", 51), "user:anne")
}

// M26/M27/M28 — Read filter rules, token/filter mismatch, page
// size.
func TestProbeM26To28Read(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	var tuples []*openfgav1.TupleKey
	for _, u := range []string{"anne", "bob", "carl"} {
		tuples = append(tuples,
			tk("doc:1", "viewer", "user:"+u),
			tk("doc:2", "viewer", "user:"+u))
	}
	store, _ := setup(t, client, `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user]
`, tuples)

	read := func(label string, tk *openfgav1.ReadRequestTupleKey,
		pageSize int32, token string,
	) string {
		req := &openfgav1.ReadRequest{
			StoreId: store, TupleKey: tk,
			ContinuationToken: token,
		}
		if pageSize > 0 {
			req.PageSize = wrapInt32(pageSize)
		}
		resp, err := client.Read(ctx, req)
		if err != nil {
			s, _ := status.FromError(err)
			t.Logf("OBSERVED: %s: code=%d msg=%q",
				label, int(s.Code()), s.Message())
			return ""
		}
		t.Logf("OBSERVED: %s: %d tuples, token=%q",
			label, len(resp.GetTuples()),
			truncate(resp.GetContinuationToken(), 20))
		return resp.GetContinuationToken()
	}

	read("no filter", nil, 0, "")
	read("type-only object + relation",
		&openfgav1.ReadRequestTupleKey{
			Object: "doc:", Relation: "viewer"}, 0, "")
	read("relation without object",
		&openfgav1.ReadRequestTupleKey{Relation: "viewer"}, 0, "")
	read("user only",
		&openfgav1.ReadRequestTupleKey{User: "user:anne"}, 0, "")
	read("type-only object, no relation",
		&openfgav1.ReadRequestTupleKey{Object: "doc:"}, 0, "")
	read("full object only",
		&openfgav1.ReadRequestTupleKey{Object: "doc:1"}, 0, "")

	// Token reuse under a different filter.
	tok := read("page 1 of doc:1",
		&openfgav1.ReadRequestTupleKey{Object: "doc:1"}, 2, "")
	if tok != "" {
		read("token with changed filter (doc:2)",
			&openfgav1.ReadRequestTupleKey{Object: "doc:2"}, 2,
			tok)
		read("token with same filter",
			&openfgav1.ReadRequestTupleKey{Object: "doc:1"}, 2,
			tok)
	}
	read("garbage token",
		&openfgav1.ReadRequestTupleKey{Object: "doc:1"}, 2,
		"not-a-token")

	// Page size boundaries.
	read("page_size 100", nil, 100, "")
	read("page_size 101", nil, 101, "")
	read("page_size 0 default", nil, 0, "")
}

// M29 — condition context byte limit at tuple write.
func TestProbeM29ContextLimit(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	store, model := setup(t, client, `model
  schema 1.1
type user
type doc
  relations
    define viewer: [user with strcond]

condition strcond(s: string) {
  s != ""
}
`, nil)

	try := func(label string, n int) {
		v, _ := structpb.NewStruct(map[string]any{
			"s": strings.Repeat("x", n),
		})
		tuple := tk("doc:1", "viewer", "user:anne")
		tuple.Condition = &openfgav1.RelationshipCondition{
			Name: "strcond", Context: v,
		}
		_, err := client.Write(ctx, &openfgav1.WriteRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			Writes: &openfgav1.WriteRequestWrites{
				TupleKeys: []*openfgav1.TupleKey{tuple}},
		})
		code, msg := 0, "OK"
		if err != nil {
			s, _ := status.FromError(err)
			code, msg = int(s.Code()), truncate(s.Message(), 120)
		}
		t.Logf("OBSERVED: %s (%d byte string): code=%d msg=%q",
			label, n, code, msg)
		if err == nil {
			_, _ = client.Write(ctx, &openfgav1.WriteRequest{
				StoreId:              store,
				AuthorizationModelId: model,
				Deletes: &openfgav1.WriteRequestDeletes{
					TupleKeys: []*openfgav1.
						TupleKeyWithoutCondition{{
						Object: "doc:1", Relation: "viewer",
						User: "user:anne"}}},
			})
		}
	}

	for _, n := range []int{30000, 32700, 32800, 40000} {
		try("context", n)
	}
}

// M16 — model-write refusal codes for the CONFIG-* rules, sent as
// raw protos so the DSL parser cannot pre-empt the server.
func TestProbeM16ModelValidation(t *testing.T) {
	client := oracle.Client(t)
	ctx := context.Background()

	newStore := func() string {
		s, err := client.CreateStore(ctx,
			&openfgav1.CreateStoreRequest{Name: t.Name()})
		if err != nil {
			t.Fatalf("create store: %v", err)
		}
		return s.GetId()
	}

	tryModel := func(label string,
		tds []*openfgav1.TypeDefinition,
		conds map[string]*openfgav1.Condition,
	) {
		_, err := client.WriteAuthorizationModel(ctx,
			&openfgav1.WriteAuthorizationModelRequest{
				StoreId:         newStore(),
				SchemaVersion:   "1.1",
				TypeDefinitions: tds,
				Conditions:      conds,
			})
		code, msg := 0, "OK"
		if err != nil {
			s, _ := status.FromError(err)
			code, msg = int(s.Code()), truncate(s.Message(), 160)
		}
		t.Logf("OBSERVED: %s: code=%d msg=%q", label, code, msg)
	}

	this := &openfgav1.Userset{
		Userset: &openfgav1.Userset_This{
			This: &openfgav1.DirectUserset{}}}
	userRef := func() []*openfgav1.RelationReference {
		return []*openfgav1.RelationReference{{Type: "user"}}
	}
	userType := &openfgav1.TypeDefinition{Type: "user"}
	docType := func(rels map[string]*openfgav1.Userset,
		meta map[string]*openfgav1.RelationMetadata,
	) *openfgav1.TypeDefinition {
		return &openfgav1.TypeDefinition{
			Type: "doc", Relations: rels,
			Metadata: &openfgav1.Metadata{Relations: meta},
		}
	}

	tryModel("valid baseline",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}},
		)}, nil)

	tryModel("relation name 51 chars",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{
				strings.Repeat("r", 51): this},
			map[string]*openfgav1.RelationMetadata{
				strings.Repeat("r", 51): {
					DirectlyRelatedUserTypes: userRef()}},
		)}, nil)

	tryModel("type name 255 chars",
		[]*openfgav1.TypeDefinition{userType, {
			Type: strings.Repeat("t", 255),
			Relations: map[string]*openfgav1.Userset{
				"viewer": this},
			Metadata: &openfgav1.Metadata{
				Relations: map[string]*openfgav1.
					RelationMetadata{"viewer": {
					DirectlyRelatedUserTypes: userRef()}}},
		}}, nil)

	tryModel("reserved relation name self",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"self": this},
			map[string]*openfgav1.RelationMetadata{
				"self": {DirectlyRelatedUserTypes: userRef()}},
		)}, nil)

	tryModel("reserved type name this",
		[]*openfgav1.TypeDefinition{userType, {
			Type: "this",
			Relations: map[string]*openfgav1.Userset{
				"viewer": this},
			Metadata: &openfgav1.Metadata{
				Relations: map[string]*openfgav1.
					RelationMetadata{"viewer": {
					DirectlyRelatedUserTypes: userRef()}}},
		}}, nil)

	tryModel("restriction names undefined condition",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: []*openfgav1.
					RelationReference{{Type: "user",
					Condition: "ghost"}}}},
		)}, nil)

	tryModel("restriction names undefined type",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: []*openfgav1.
					RelationReference{{Type: "ghost"}}}},
		)}, nil)

	tryModel("rewrite names undefined relation",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{
				"viewer": {Userset: &openfgav1.
					Userset_ComputedUserset{
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: "ghost"}}}},
			map[string]*openfgav1.RelationMetadata{"viewer": {}},
		)}, nil)

	tryModel("rewrite names itself",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{
				"viewer": {Userset: &openfgav1.
					Userset_ComputedUserset{
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: "viewer"}}}},
			map[string]*openfgav1.RelationMetadata{"viewer": {}},
		)}, nil)

	tryModel("two-relation rewrite cycle",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{
				"a": {Userset: &openfgav1.Userset_ComputedUserset{
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: "b"}}},
				"b": {Userset: &openfgav1.Userset_ComputedUserset{
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: "a"}}}},
			map[string]*openfgav1.RelationMetadata{
				"a": {}, "b": {}},
		)}, nil)

	tryModel("relation admits and rewrites nothing",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {}},
		)}, nil)

	tryModel("single-operand intersection",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{
				"viewer": {Userset: &openfgav1.
					Userset_Intersection{
					Intersection: &openfgav1.Usersets{
						Child: []*openfgav1.Userset{this}}}}},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}},
		)}, nil)

	ttuViewer := &openfgav1.Userset{
		Userset: &openfgav1.Userset_TupleToUserset{
			TupleToUserset: &openfgav1.TupleToUserset{
				Tupleset: &openfgav1.ObjectRelation{
					Relation: "parent"},
				ComputedUserset: &openfgav1.ObjectRelation{
					Relation: "viewer"}}}}
	folderType := &openfgav1.TypeDefinition{
		Type: "folder",
		Relations: map[string]*openfgav1.Userset{
			"viewer": this},
		Metadata: &openfgav1.Metadata{
			Relations: map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}}},
	}

	tryModel("tupleset admits userset",
		[]*openfgav1.TypeDefinition{userType, folderType, docType(
			map[string]*openfgav1.Userset{
				"parent": this, "viewer": ttuViewer},
			map[string]*openfgav1.RelationMetadata{
				"parent": {DirectlyRelatedUserTypes: []*openfgav1.
					RelationReference{{Type: "folder",
					RelationOrWildcard: &openfgav1.
						RelationReference_Relation{
						Relation: "viewer"}}}},
				"viewer": {}},
		)}, nil)

	tryModel("tupleset admits wildcard",
		[]*openfgav1.TypeDefinition{userType, folderType, docType(
			map[string]*openfgav1.Userset{
				"parent": this, "viewer": ttuViewer},
			map[string]*openfgav1.RelationMetadata{
				"parent": {DirectlyRelatedUserTypes: []*openfgav1.
					RelationReference{{Type: "folder",
					RelationOrWildcard: &openfgav1.
						RelationReference_Wildcard{
						Wildcard: &openfgav1.Wildcard{}}}}},
				"viewer": {}},
		)}, nil)

	tryModel("tupleset rewrites (not direct)",
		[]*openfgav1.TypeDefinition{userType, folderType, docType(
			map[string]*openfgav1.Userset{
				"owner": this,
				"parent": {Userset: &openfgav1.
					Userset_ComputedUserset{
					ComputedUserset: &openfgav1.ObjectRelation{
						Relation: "owner"}}},
				"viewer": ttuViewer},
			map[string]*openfgav1.RelationMetadata{
				"owner": {DirectlyRelatedUserTypes: []*openfgav1.
					RelationReference{{Type: "folder"}}},
				"parent": {}, "viewer": {}},
		)}, nil)

	tryModel("condition name malformed",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}},
		)},
		map[string]*openfgav1.Condition{
			"bad name": {Name: "bad name", Expression: "true"}})

	tryModel("condition expression does not compile",
		[]*openfgav1.TypeDefinition{userType, docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}},
		)},
		map[string]*openfgav1.Condition{
			"c1": {Name: "c1", Expression: "((("}})

	tryModel("no types at all", nil, nil)

	tryModel("model without type user referenced",
		[]*openfgav1.TypeDefinition{docType(
			map[string]*openfgav1.Userset{"viewer": this},
			map[string]*openfgav1.RelationMetadata{
				"viewer": {DirectlyRelatedUserTypes: userRef()}},
		)}, nil)

	// Schema version gate.
	_, err := client.WriteAuthorizationModel(ctx,
		&openfgav1.WriteAuthorizationModelRequest{
			StoreId:       newStore(),
			SchemaVersion: "1.0",
			TypeDefinitions: []*openfgav1.TypeDefinition{
				userType},
		})
	if err != nil {
		s, _ := status.FromError(err)
		t.Logf("OBSERVED: schema 1.0: code=%d msg=%q",
			int(s.Code()), truncate(s.Message(), 160))
	} else {
		t.Logf("OBSERVED: schema 1.0: OK")
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func wrapInt32(v int32) *wrapperspb.Int32Value {
	return wrapperspb.Int32(v)
}

// keep the DSL parser import honest for model-shaped probes that
// may grow here.
var _ = parser.TransformDSLToProto
