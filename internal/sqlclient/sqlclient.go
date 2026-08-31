// Package sqlclient implements the upstream test runners' client
// interface over SQL calls to the fga schema, so the pinned
// conformance corpora drive the engine exactly as they drive the
// reference server.
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
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Client speaks the seven-method interface the upstream runners
// need (tests.ClientInterface at the pin). It is goroutine-safe:
// the pool is, and the client holds nothing else mutable.
type Client struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Client {
	return &Client{pool: pool}
}

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
	return nil, unimplemented("WriteAuthorizationModel", "phase 1")
}

func (c *Client) Write(
	ctx context.Context,
	in *openfgav1.WriteRequest,
	_ ...grpc.CallOption,
) (*openfgav1.WriteResponse, error) {
	return nil, unimplemented("Write", "phase 1")
}

func (c *Client) Check(
	ctx context.Context,
	in *openfgav1.CheckRequest,
	_ ...grpc.CallOption,
) (*openfgav1.CheckResponse, error) {
	return nil, unimplemented("Check", "phase 1")
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

func (c *Client) StreamedListObjects(
	ctx context.Context,
	in *openfgav1.StreamedListObjectsRequest,
	_ ...grpc.CallOption,
) (openfgav1.OpenFGAService_StreamedListObjectsClient, error) {
	return nil, unimplemented("StreamedListObjects", "phase 2")
}
