// Package sqlclient implements the upstream test runners' client
// interface over SQL calls to the fga schema, so the pinned
// conformance corpora drive the engine exactly as they drive the
// reference server.
//
// The adapter owns three translations (workspace decision 5):
// proto to the engine's jsonb request shapes (snake_case
// protojson), engine SQLSTATEs back to the gRPC codes upstream
// carries, and the deterministic uuid-mapping of corpus string ids
// into the engine's uuid-only id domain. It also mirrors the
// server's proto-shape validation (generated protovalidate
// methods) so shape errors surface as gRPC InvalidArgument exact
// as they do at the oracle (measurements.md M10 step 1).
//
// Methods land on the plan's phase schedule; a method whose engine
// surface does not exist yet returns a typed Unimplemented error
// naming its phase, which the skip machinery turns into a printed
// skip rather than a silent absence.
package sqlclient

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// Client speaks the seven-method interface the upstream runners
// need (tests.ClientInterface at the pin). It is goroutine-safe:
// the pool and the uuid map are, and the client holds nothing
// else mutable.
type Client struct {
	pool *pgxpool.Pool
	ids  *uuidmap.Map
}

// New builds a client. ids may be nil for callers that already
// speak uuids (the engine's native id domain).
func New(pool *pgxpool.Pool, ids *uuidmap.Map) *Client {
	return &Client{pool: pool, ids: ids}
}

var marshal = protojson.MarshalOptions{UseProtoNames: true}

// translate maps engine SQLSTATEs from the reserved YF class to
// the gRPC status codes upstream carries (docs/ERRORS.md holds the
// rule: YF1nn -> 2000+nn, YF5nn -> 5000+nn). Anything outside the
// class passes through untouched, so infrastructure failure stays
// distinguishable from engine refusal by construction.
func translate(err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return err
	}
	code := pgErr.Code
	if len(code) != 5 || code[:2] != "YF" {
		return err
	}
	nn := int(code[3]-'0')*10 + int(code[4]-'0')
	switch code[2] {
	case '1':
		return status.Error(codes.Code(2000+nn), pgErr.Message)
	case '5':
		return status.Error(codes.Code(5000+nn), pgErr.Message)
	}
	return err
}

// dummyULID satisfies upstream's 26-char ULID patterns during
// proto-shape validation. Engine store and model ids are uuids
// (the pinned id-domain divergence), so those two fields are
// exempted from the pattern by substitution before validating —
// every other field keeps the server's exact shape rules.
const dummyULID = "00000000000000000000000000"

// validate mirrors the gRPC server's protovalidate interceptor,
// with the id-domain exemption above.
func validate(in proto.Message) error {
	c := proto.Clone(in)
	switch m := c.(type) {
	case *openfgav1.CheckRequest:
		m.StoreId = dummyULID
		if m.AuthorizationModelId != "" {
			m.AuthorizationModelId = dummyULID
		}
	case *openfgav1.WriteRequest:
		m.StoreId = dummyULID
		if m.AuthorizationModelId != "" {
			m.AuthorizationModelId = dummyULID
		}
	case *openfgav1.WriteAuthorizationModelRequest:
		m.StoreId = dummyULID
	}
	v, ok := c.(interface{ Validate() error })
	if !ok {
		return nil
	}
	if err := v.Validate(); err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}
	return nil
}

// mapObject rewrites the id segment of "type:id" through the uuid
// map. Strings without the shape pass through untouched — the
// engine refuses them natively, which is the point.
func (c *Client) mapObject(s string) string {
	if c.ids == nil {
		return s
	}
	typ, id, ok := strings.Cut(s, ":")
	if !ok || typ == "" || id == "" {
		return s
	}
	return typ + ":" + c.ids.ID(id)
}

// mapUser handles "type:id", "type:id#relation" and the "type:*"
// wildcard (never mapped).
func (c *Client) mapUser(s string) string {
	if c.ids == nil {
		return s
	}
	rest, rel, hasRel := strings.Cut(s, "#")
	typ, id, ok := strings.Cut(rest, ":")
	if !ok || typ == "" || id == "" || id == "*" {
		return s
	}
	mapped := typ + ":" + c.ids.ID(id)
	if hasRel {
		mapped += "#" + rel
	}
	return mapped
}

func (c *Client) mapTuple(
	tk *openfgav1.TupleKey,
) *openfgav1.TupleKey {
	if c.ids == nil || tk == nil {
		return tk
	}
	out := proto.Clone(tk).(*openfgav1.TupleKey)
	out.Object = c.mapObject(out.GetObject())
	out.User = c.mapUser(out.GetUser())
	return out
}

func unimplemented(method, phase string) error {
	return status.Error(codes.Unimplemented, fmt.Sprintf(
		"fga4postgres: %s arrives in plan %s", method, phase,
	))
}

func (c *Client) CreateStore(
	ctx context.Context,
	in *openfgav1.CreateStoreRequest,
	_ ...grpc.CallOption,
) (*openfgav1.CreateStoreResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	var (
		id, name  string
		createdAt time.Time
	)
	err := c.pool.QueryRow(ctx,
		"SELECT id, name, created_at FROM fga.create_store($1)",
		in.GetName(),
	).Scan(&id, &name, &createdAt)
	if err != nil {
		return nil, translate(err)
	}
	return &openfgav1.CreateStoreResponse{
		Id:        id,
		Name:      name,
		CreatedAt: timestamppb.New(createdAt),
		UpdatedAt: timestamppb.New(createdAt),
	}, nil
}

// DeleteStore is not part of the runners' interface; the suite
// calls it from t.Cleanup so corpus stores do not accumulate.
func (c *Client) DeleteStore(
	ctx context.Context, storeID string,
) error {
	_, err := c.pool.Exec(
		ctx, "SELECT fga.delete_store($1)", storeID,
	)
	return translate(err)
}

func (c *Client) WriteAuthorizationModel(
	ctx context.Context,
	in *openfgav1.WriteAuthorizationModelRequest,
	_ ...grpc.CallOption,
) (*openfgav1.WriteAuthorizationModelResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	req, err := marshal.Marshal(in)
	if err != nil {
		return nil, err
	}
	var out []byte
	err = c.pool.QueryRow(ctx,
		"SELECT fga.write_authorization_model($1, $2)",
		in.GetStoreId(), req,
	).Scan(&out)
	if err != nil {
		return nil, translate(err)
	}
	resp := &openfgav1.WriteAuthorizationModelResponse{}
	if err := protojson.Unmarshal(out, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func (c *Client) Write(
	ctx context.Context,
	in *openfgav1.WriteRequest,
	_ ...grpc.CallOption,
) (*openfgav1.WriteResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	mapped := proto.Clone(in).(*openfgav1.WriteRequest)
	for i, tk := range mapped.GetWrites().GetTupleKeys() {
		mapped.Writes.TupleKeys[i] = c.mapTuple(tk)
	}
	for i, tk := range mapped.GetDeletes().GetTupleKeys() {
		del := mapped.Deletes.TupleKeys[i]
		del.Object = c.mapObject(tk.GetObject())
		del.User = c.mapUser(tk.GetUser())
	}
	req, err := marshal.Marshal(mapped)
	if err != nil {
		return nil, err
	}
	_, err = c.pool.Exec(ctx,
		"SELECT fga.write($1, $2)", in.GetStoreId(), req)
	if err != nil {
		return nil, translate(err)
	}
	return &openfgav1.WriteResponse{}, nil
}

func (c *Client) Check(
	ctx context.Context,
	in *openfgav1.CheckRequest,
	_ ...grpc.CallOption,
) (*openfgav1.CheckResponse, error) {
	if err := validate(in); err != nil {
		return nil, err
	}
	mapped := proto.Clone(in).(*openfgav1.CheckRequest)
	if tk := mapped.GetTupleKey(); tk != nil {
		tk.Object = c.mapObject(tk.GetObject())
		tk.User = c.mapUser(tk.GetUser())
	}
	for i, tk := range mapped.GetContextualTuples().GetTupleKeys() {
		mapped.ContextualTuples.TupleKeys[i] = c.mapTuple(tk)
	}
	req, err := marshal.Marshal(mapped)
	if err != nil {
		return nil, err
	}
	var out []byte
	err = c.pool.QueryRow(ctx,
		"SELECT fga.check($1, $2)", in.GetStoreId(), req,
	).Scan(&out)
	if err != nil {
		return nil, translate(err)
	}
	resp := &openfgav1.CheckResponse{}
	if err := protojson.Unmarshal(out, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func (c *Client) ListObjects(
	ctx context.Context,
	in *openfgav1.ListObjectsRequest,
	_ ...grpc.CallOption,
) (*openfgav1.ListObjectsResponse, error) {
	return nil, unimplemented("ListObjects", "phase 3")
}

func (c *Client) ListUsers(
	ctx context.Context,
	in *openfgav1.ListUsersRequest,
	_ ...grpc.CallOption,
) (*openfgav1.ListUsersResponse, error) {
	return nil, unimplemented("ListUsers", "phase 5")
}

// StreamedListObjects adapts the unary ListObjects into the
// client-stream shape the upstream runners consume. Like the real
// server, errors surface on the first Recv, not on the call
// itself. One deliberate divergence carried over from the unary
// path (plan §1.5): a condition evaluation error always fails the
// stream, where upstream may have streamed partial results first.
func (c *Client) StreamedListObjects(
	ctx context.Context,
	in *openfgav1.StreamedListObjectsRequest,
	_ ...grpc.CallOption,
) (openfgav1.OpenFGAService_StreamedListObjectsClient, error) {
	resp, err := c.ListObjects(ctx, &openfgav1.ListObjectsRequest{
		StoreId:              in.GetStoreId(),
		AuthorizationModelId: in.GetAuthorizationModelId(),
		Type:                 in.GetType(),
		Relation:             in.GetRelation(),
		User:                 in.GetUser(),
		ContextualTuples:     in.GetContextualTuples(),
		Context:              in.GetContext(),
	})
	s := &streamedListObjects{ctx: ctx}
	if err != nil {
		s.err = err
	} else {
		s.objects = resp.GetObjects()
	}
	return s, nil
}

type streamedListObjects struct {
	ctx     context.Context
	objects []string
	err     error
	i       int
}

func (s *streamedListObjects) Recv() (
	*openfgav1.StreamedListObjectsResponse, error,
) {
	if s.err != nil {
		return nil, s.err
	}
	if s.i >= len(s.objects) {
		return nil, io.EOF
	}
	obj := s.objects[s.i]
	s.i++
	return &openfgav1.StreamedListObjectsResponse{
		Object: obj,
	}, nil
}

func (s *streamedListObjects) Header() (metadata.MD, error) {
	return nil, nil
}
func (s *streamedListObjects) Trailer() metadata.MD { return nil }
func (s *streamedListObjects) CloseSend() error     { return nil }
func (s *streamedListObjects) Context() context.Context {
	return s.ctx
}
func (s *streamedListObjects) SendMsg(any) error {
	return status.Error(codes.Unimplemented,
		"fga4postgres: client stream is receive-only")
}
func (s *streamedListObjects) RecvMsg(m any) error {
	resp, err := s.Recv()
	if err != nil {
		return err
	}
	out, ok := m.(*openfgav1.StreamedListObjectsResponse)
	if !ok {
		return status.Error(codes.Internal,
			"fga4postgres: unexpected message type")
	}
	proto.Merge(out, resp)
	return nil
}
