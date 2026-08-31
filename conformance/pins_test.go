package conformance

import (
	"context"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"google.golang.org/grpc/status"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
)

// Pinned divergences, asserted from BOTH sides (tsfga's pattern,
// plan §2.2/§4): each test requires the oracle to accept what the
// engine refuses. If upstream ever starts refusing too — or the
// engine starts accepting — the pin turns red and its entry in
// docs/CONFORMANCE.md must be updated in the same change.
//
// These clients deliberately carry no uuid map: the raw corpus-
// style ids ARE the point.

func pinStores(t *testing.T) (eng *sqlclient.Client,
	engStore, engModel, oraStore, oraModel string) {
	t.Helper()
	ctx := context.Background()
	eng = sqlclient.New(testdb.Pool(t), nil)

	engStore, engModel = setup(t, eng, plainDSL, nil)
	oraStore, oraModel = setup(t, oracle.Client(t), plainDSL, nil)
	t.Cleanup(func() {
		_ = eng.DeleteStore(ctx, engStore)
		_, _ = oracle.Client(t).DeleteStore(ctx,
			&openfgav1.DeleteStoreRequest{StoreId: oraStore})
	})
	return
}

// checkOn runs one check and folds the outcome into
// (allowed, code): code 0 means no error.
func checkOn(
	t *testing.T, c probeClient, store, model,
	object, relation, user string,
) (bool, int) {
	t.Helper()
	resp, err := c.Check(context.Background(),
		&openfgav1.CheckRequest{
			StoreId:              store,
			AuthorizationModelId: model,
			TupleKey: &openfgav1.CheckRequestTupleKey{
				Object: object, Relation: relation, User: user,
			},
		})
	if err != nil {
		s, _ := status.FromError(err)
		return false, int(s.Code())
	}
	return resp.GetAllowed(), 0
}

// expectPin asserts the two sides of one pinned divergence.
func expectPin(
	t *testing.T, label string,
	engAllowed bool, engCode int, wantEngCode int,
	oraAllowed bool, oraCode int,
) {
	t.Helper()
	if engCode != wantEngCode {
		t.Errorf("%s: engine side of the pin moved: "+
			"code=%d allowed=%v, want refusal %d — update "+
			"docs/CONFORMANCE.md with this change",
			label, engCode, engAllowed, wantEngCode)
	}
	if oraCode != 0 || oraAllowed {
		t.Errorf("%s: oracle side of the pin moved: "+
			"code=%d allowed=%v, want accepted-and-false — the "+
			"divergence may have closed; update "+
			"docs/CONFORMANCE.md", label, oraCode, oraAllowed)
	}
}

func TestPinnedIDDomain(t *testing.T) {
	eng, engStore, engModel, oraStore, oraModel := pinStores(t)
	ora := oracle.Client(t)

	const okDoc = "doc:22222222-2222-7222-8222-222222222222"

	cases := []struct {
		label, object, user string
	}{
		{"PIN-ID-1 arbitrary string ids (refusing)",
			"doc:budget", "user:anne"},
		{"PIN-ID-2 non-canonical uuid spelling (refusing)",
			okDoc,
			"user:22222222-2222-7222-8222-22222222222A"},
		{"PIN-ID-3 nil uuid reserved as wildcard sentinel " +
			"(refusing)",
			okDoc,
			"user:00000000-0000-0000-0000-000000000000"},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			ea, ec := checkOn(t, eng, engStore, engModel,
				c.object, "viewer", c.user)
			oa, oc := checkOn(t, ora, oraStore, oraModel,
				c.object, "viewer", c.user)
			expectPin(t, c.label, ea, ec, 2000, oa, oc)
		})
	}
}

// PIN-ID-4: upstream-shaped ULID model ids are refused as
// not-found (uuidv7 model ids, workspace decision 3). One-sided by
// nature — the oracle's own model ids ARE ULIDs, which is the
// divergence — so the assert is that the engine refuses with the
// not-found code, and that the oracle accepts its own ULID id
// (implicitly proven by every replay case).
func TestPinnedULIDModelID(t *testing.T) {
	eng, engStore, _, _, _ := pinStores(t)
	_, code := checkOn(t, eng, engStore,
		"01ARZ3NDEKTSV4RRFFQ69G5FAV",
		"doc:22222222-2222-7222-8222-222222222222",
		"viewer", "user:33333333-3333-7333-8333-333333333333")
	if code != 2001 {
		t.Errorf("ULID model id: engine code %d, want 2001", code)
	}
}
