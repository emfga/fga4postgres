package sqlclient

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"

	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Compiled answers Check, ListObjects and ListUsers through a
// store's generated relation functions (sql/095_compiled.sql)
// instead of the generic resolver, so the corpora can prove the
// generated functions agree with upstream. Everything else —
// stores, models, tuple writes — goes through the plain client;
// CreateStore also creates a schema for the store and opts it in.
//
// The generated functions take uuids, not request strings, so the
// request validation the public API performs (malformed strings,
// unknown types and relations) has no generated counterpart. A
// request that cannot be routed to a function is handed to the
// plain client: it must then be refused there, and the refusal is
// recorded in Generic so the caller can report it. A routable
// request the generic API would answer is an error, never a
// silent fallback.
type Compiled struct {
	*Client

	mu      sync.Mutex
	generic []string
}

// MaxListResults is the list cap the caller applies on top of the
// uncapped __objects function, mirroring list_objects' default.
const MaxListResults = 1000

func NewCompiled(pool *pgxpool.Pool, ids *uuidmap.Map) *Compiled {
	return &Compiled{Client: New(pool, ids)}
}

// TakeGeneric returns and clears the reasons recorded since the
// last call for requests the plain client answered.
func (c *Compiled) TakeGeneric() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := c.generic
	c.generic = nil
	return out
}

func (c *Compiled) recordGeneric(reason string) {
	c.mu.Lock()
	c.generic = append(c.generic, reason)
	c.mu.Unlock()
}

// compiledSchema is the schema a store's functions live in.
func compiledSchema(storeID string) string {
	return "fgac_" + strings.ReplaceAll(storeID, "-", "")
}

func (c *Compiled) CreateStore(
	ctx context.Context,
	in *openfgav1.CreateStoreRequest,
	opts ...grpc.CallOption,
) (*openfgav1.CreateStoreResponse, error) {
	resp, err := c.Client.CreateStore(ctx, in, opts...)
	if err != nil {
		return nil, err
	}
	schema := compiledSchema(resp.GetId())
	_, err = c.pool.Exec(ctx, "CREATE SCHEMA "+schema)
	if err != nil {
		return nil, err
	}
	_, err = c.pool.Exec(ctx,
		"SELECT fga.enable_compiled_relations($1, $2)",
		resp.GetId(), schema)
	if err != nil {
		return nil, translate(err)
	}
	return resp, nil
}

func (c *Compiled) DeleteStore(
	ctx context.Context, storeID string,
) error {
	if err := c.Client.DeleteStore(ctx, storeID); err != nil {
		return err
	}
	_, err := c.pool.Exec(ctx,
		"DROP SCHEMA IF EXISTS "+compiledSchema(storeID)+" CASCADE")
	return err
}

// errNoRoute marks a request no generated function can answer.
var errNoRoute = errors.New("no compiled route")

var canonicalUUID = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func isID(s string) bool {
	return canonicalUUID.MatchString(s) &&
		s != "00000000-0000-0000-0000-000000000000"
}

// subject is a parsed, mapped request user.
type subject struct {
	typ, rel string
	id       *string // nil for the typed wildcard
}

func (c *Compiled) parseUser(s string) (subject, error) {
	rest, rel, _ := strings.Cut(c.mapUser(s), "#")
	typ, id, ok := strings.Cut(rest, ":")
	if !ok || typ == "" {
		return subject{}, errNoRoute
	}
	if id == "*" {
		if rel != "" {
			return subject{}, errNoRoute
		}
		return subject{typ: typ}, nil
	}
	if !isID(id) {
		return subject{}, errNoRoute
	}
	return subject{typ: typ, rel: rel, id: &id}, nil
}

func (c *Compiled) parseObject(s string) (string, string, error) {
	typ, id, ok := strings.Cut(c.mapObject(s), ":")
	if !ok || typ == "" || !isID(id) {
		return "", "", errNoRoute
	}
	return typ, id, nil
}

// route finds the generated function of one kind for a relation of
// the requested model, after checking the subject names a type
// (and relation) of that model — the validation the generic API
// would otherwise do.
func (c *Compiled) route(
	ctx context.Context, storeID, modelID, typ, rel, kind,
	subjType, subjRel string,
) (string, error) {
	if modelID != "" && !isID(modelID) {
		return "", errNoRoute
	}
	var fn string
	err := c.pool.QueryRow(ctx, `
		WITH m AS (
		  SELECT coalesce(nullif($2, '')::uuid, (
		    SELECT id FROM fga.model WHERE store = $1::uuid
		    ORDER BY id DESC LIMIT 1)) AS id)
		SELECT format('%I.%I', n.nspname, p.proname)
		FROM m
		JOIN fga.compiled_relation r
		  ON r.store = $1::uuid AND r.model_id = m.id
		 AND r.type_name = $3 AND r.relation_name = $4
		JOIN pg_proc p ON p.oid = CASE $5
		  WHEN 'objects' THEN r.objects_fn::oid
		  WHEN 'subjects' THEN r.subjects_fn::oid
		  ELSE r.check_fn::oid END
		JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE EXISTS (
		    SELECT FROM fga.model_type t
		    WHERE t.store = $1::uuid AND t.model_id = m.id
		      AND t.type_name = $6)
		  AND ($7 = '' OR EXISTS (
		    SELECT FROM fga.model_relation x
		    WHERE x.store = $1::uuid AND x.model_id = m.id
		      AND x.type_name = $6 AND x.relation_name = $7))`,
		storeID, modelID, typ, rel, kind, subjType, subjRel,
	).Scan(&fn)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", errNoRoute
	}
	return fn, err
}

func contextJSON(s *structpb.Struct) ([]byte, error) {
	if s == nil {
		return []byte("{}"), nil
	}
	return marshal.Marshal(s)
}

func (c *Compiled) tuplesJSON(
	keys []*openfgav1.TupleKey,
) ([]byte, error) {
	parts := make([]string, 0, len(keys))
	for _, tk := range keys {
		b, err := marshal.Marshal(c.mapTuple(tk))
		if err != nil {
			return nil, err
		}
		parts = append(parts, string(b))
	}
	return []byte("[" + strings.Join(parts, ",") + "]"), nil
}

// noRoute hands an unroutable request to the plain client, which
// must refuse it.
func (c *Compiled) noRoute(kind string, err error) error {
	if err == nil {
		return status.Error(codes.Internal, "compiled: the generic "+
			"API answers a "+kind+" request no generated "+
			"function was routed to")
	}
	c.recordGeneric(kind)
	return err
}

func (c *Compiled) Check(
	ctx context.Context,
	in *openfgav1.CheckRequest,
	opts ...grpc.CallOption,
) (*openfgav1.CheckResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	tk := in.GetTupleKey()
	objType, objID, err := c.parseObject(tk.GetObject())
	var subj subject
	if err == nil {
		subj, err = c.parseUser(tk.GetUser())
	}
	var fn string
	if err == nil {
		fn, err = c.route(ctx, in.GetStoreId(),
			in.GetAuthorizationModelId(), objType, tk.GetRelation(),
			"check", subj.typ, subj.rel)
	}
	if errors.Is(err, errNoRoute) {
		_, gerr := c.Client.Check(ctx, in, opts...)
		return nil, c.noRoute("check", gerr)
	}
	if err != nil {
		return nil, err
	}
	reqCtx, err := contextJSON(in.GetContext())
	if err != nil {
		return nil, err
	}
	ctxTuples, err := c.tuplesJSON(
		in.GetContextualTuples().GetTupleKeys())
	if err != nil {
		return nil, err
	}
	var allowed bool
	err = c.pool.QueryRow(ctx, fmt.Sprintf(
		"SELECT %s($1::uuid, $2, $3::uuid, $4, $5, $6::jsonb, "+
			"$7::jsonb)", fn),
		objID, subj.typ, subj.id, subj.rel, subj.id == nil,
		reqCtx, ctxTuples,
	).Scan(&allowed)
	if err != nil {
		return nil, translate(err)
	}
	return &openfgav1.CheckResponse{Allowed: allowed}, nil
}

func (c *Compiled) ListObjects(
	ctx context.Context,
	in *openfgav1.ListObjectsRequest,
	opts ...grpc.CallOption,
) (*openfgav1.ListObjectsResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	subj, err := c.parseUser(in.GetUser())
	var fn string
	if err == nil {
		fn, err = c.route(ctx, in.GetStoreId(),
			in.GetAuthorizationModelId(), in.GetType(),
			in.GetRelation(), "objects", subj.typ, subj.rel)
	}
	if errors.Is(err, errNoRoute) {
		_, gerr := c.Client.ListObjects(ctx, in, opts...)
		return nil, c.noRoute("list_objects", gerr)
	}
	if err != nil {
		return nil, err
	}
	reqCtx, err := contextJSON(in.GetContext())
	if err != nil {
		return nil, err
	}
	ctxTuples, err := c.tuplesJSON(
		in.GetContextualTuples().GetTupleKeys())
	if err != nil {
		return nil, err
	}
	rows, err := c.pool.Query(ctx, fmt.Sprintf(
		"SELECT x::text FROM %s($1, $2::uuid, $3, $4, $5::jsonb, "+
			"$6::jsonb) AS x LIMIT %d", fn, MaxListResults),
		subj.typ, subj.id, subj.rel, subj.id == nil,
		reqCtx, ctxTuples)
	if err != nil {
		return nil, translate(err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, translate(err)
	}
	resp := &openfgav1.ListObjectsResponse{}
	for _, id := range ids {
		if c.ids != nil {
			id = c.ids.Back(id)
		}
		resp.Objects = append(resp.Objects, in.GetType()+":"+id)
	}
	return resp, nil
}

// ListUsers returns the generated function's final list: concrete
// subjects of the filter type (userset ids when the filter names a
// relation). It never returns a typed wildcard — the function
// expands wildcards over a registered subject source or refuses.
func (c *Compiled) ListUsers(
	ctx context.Context,
	in *openfgav1.ListUsersRequest,
	opts ...grpc.CallOption,
) (*openfgav1.ListUsersResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	filter := in.GetUserFilters()[0]
	objID := in.GetObject().GetId()
	if c.ids != nil {
		objID = c.ids.ID(objID)
	}
	var fn string
	err := errNoRoute
	if isID(objID) {
		fn, err = c.route(ctx, in.GetStoreId(),
			in.GetAuthorizationModelId(), in.GetObject().GetType(),
			in.GetRelation(), "subjects", filter.GetType(),
			filter.GetRelation())
	}
	if errors.Is(err, errNoRoute) {
		_, gerr := c.Client.ListUsers(ctx, in, opts...)
		return nil, c.noRoute("list_users", gerr)
	}
	if err != nil {
		return nil, err
	}
	reqCtx, err := contextJSON(in.GetContext())
	if err != nil {
		return nil, err
	}
	ctxTuples, err := c.tuplesJSON(in.GetContextualTuples())
	if err != nil {
		return nil, err
	}
	rows, err := c.pool.Query(ctx, fmt.Sprintf(
		"SELECT x::text FROM %s($1::uuid, $2, $3, $4::jsonb, "+
			"$5::jsonb) AS x", fn),
		objID, filter.GetType(), filter.GetRelation(),
		reqCtx, ctxTuples)
	if err != nil {
		return nil, translate(err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, translate(err)
	}
	resp := &openfgav1.ListUsersResponse{}
	for _, id := range ids {
		if c.ids != nil {
			id = c.ids.Back(id)
		}
		var u *openfgav1.User
		if filter.GetRelation() != "" {
			u = &openfgav1.User{User: &openfgav1.User_Userset{
				Userset: &openfgav1.UsersetUser{
					Type: filter.GetType(), Id: id,
					Relation: filter.GetRelation(),
				}}}
		} else {
			u = &openfgav1.User{User: &openfgav1.User_Object{
				Object: &openfgav1.Object{
					Type: filter.GetType(), Id: id,
				}}}
		}
		resp.Users = append(resp.Users, u)
	}
	return resp, nil
}

// RegisterSubjectSource plays the application's part in decision
// 8: it creates a table in the store's schema holding the given
// ids (request strings, mapped like any other) of one subject type
// and registers it as that type's subject source, which regenerates
// the store's functions. Calling it again for the same type adds
// ids to the same table.
func (c *Compiled) RegisterSubjectSource(
	ctx context.Context, storeID, subjectType string, ids []string,
) error {
	schema := compiledSchema(storeID)
	table := fmt.Sprintf("source_%x", []byte(subjectType))
	if len(table) > 63 {
		return fmt.Errorf("subject type %q: table name too long",
			subjectType)
	}
	mapped := make([]string, len(ids))
	for i, id := range ids {
		mapped[i] = id
		if c.ids != nil {
			mapped[i] = c.ids.ID(id)
		}
	}
	_, err := c.pool.Exec(ctx, fmt.Sprintf(
		"CREATE TABLE IF NOT EXISTS %s.%s (subject_id uuid PRIMARY KEY)",
		schema, table))
	if err != nil {
		return translate(err)
	}
	_, err = c.pool.Exec(ctx, fmt.Sprintf(`
		INSERT INTO %s.%s
		SELECT DISTINCT unnest($1::uuid[]) ON CONFLICT DO NOTHING`,
		schema, table), mapped)
	if err != nil {
		return translate(err)
	}
	_, err = c.pool.Exec(ctx, `
		SELECT fga.enable_compiled_relations(cs.store,
		  cs.target_schema, coalesce(cs.subject_sources, '{}')
		    || jsonb_build_object($2::text, format('%s.%s(subject_id)',
		         cs.target_schema, $3::text)))
		FROM fga.compiled_store cs WHERE cs.store = $1::uuid`,
		storeID, subjectType, table)
	return translate(err)
}
