package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	parser "github.com/openfga/language/pkg/go/transformer"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
	"sigs.k8s.io/yaml"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
	"github.com/emfga/fga4postgres/internal/uuidmap"
)

// The real-world model sweep: tsfga's ported fixtures — the
// openfga sample stores plus large
// production models (theopenlane: 1054 DSL lines) — written to
// both engines and swept with a seeded differential sample of
// checks plus one list_objects per fixture. No expectation
// files: the oracle IS the expectation, refusals included.
//
// checksPerFixture bounds the sweep so the suite stays fast; the
// sample is seeded by the suite seed, so a failure reproduces
// with FGA_SEED.
const checksPerFixture = 150

type rwTuple struct {
	User      string `json:"user"`
	Relation  string `json:"relation"`
	Object    string `json:"object"`
	Condition *struct {
		Name    string         `json:"name"`
		Context map[string]any `json:"context"`
	} `json:"condition"`
}

func TestRealWorldModels(t *testing.T) {
	root := filepath.Join("testdata", "realworld")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("reading %s: %v", root, err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		t.Run(e.Name(), func(t *testing.T) {
			runRealWorld(t, filepath.Join(root, e.Name()))
		})
	}
}

// loadRealWorld reads one fixture directory into its DSL and
// tuple set.
func loadRealWorld(t *testing.T, dir string,
) (string, []*openfgav1.TupleKey) {
	t.Helper()
	dslBytes, err := os.ReadFile(filepath.Join(dir, "model.dsl"))
	if err != nil {
		t.Fatalf("model.dsl: %v", err)
	}
	tupleBytes, err := os.ReadFile(
		filepath.Join(dir, "tuples.yaml"))
	if err != nil {
		t.Fatalf("tuples.yaml: %v", err)
	}
	var raw []rwTuple
	if err := yaml.Unmarshal(tupleBytes, &raw); err != nil {
		t.Fatalf("tuples.yaml: %v", err)
	}
	var tuples []*openfgav1.TupleKey
	for _, r := range raw {
		x := tk(r.Object, r.Relation, r.User)
		if r.Condition != nil {
			x.Condition = &openfgav1.RelationshipCondition{
				Name: r.Condition.Name,
			}
			if r.Condition.Context != nil {
				v, err := structpb.NewStruct(normalizeYAML(
					r.Condition.Context))
				if err != nil {
					t.Fatalf("condition context: %v", err)
				}
				x.Condition.Context = v
			}
		}
		tuples = append(tuples, x)
	}
	return string(dslBytes), tuples
}

func runRealWorld(t *testing.T, dir string) {
	ctx := context.Background()

	dslStr, tuples := loadRealWorld(t, dir)
	dslBytes := []byte(dslStr)
	model, err := parser.TransformDSLToProto(dslStr)
	if err != nil {
		t.Fatalf("bad DSL: %v", err)
	}

	// Relations per type, objects and concrete users from the
	// tuples, all sorted for determinism.
	relsByType := map[string][]string{}
	for _, td := range model.GetTypeDefinitions() {
		var rels []string
		for name := range td.GetRelations() {
			rels = append(rels, name)
		}
		sort.Strings(rels)
		relsByType[td.GetType()] = rels
	}
	objSet, userSet := map[string]bool{}, map[string]bool{}
	for _, x := range tuples {
		objSet[x.GetObject()] = true
		u := x.GetUser()
		if !strings.Contains(u, "#") &&
			!strings.HasSuffix(u, ":*") {
			userSet[u] = true
		}
		// Userset subjects reference objects too.
		if i := strings.IndexByte(u, '#'); i >= 0 {
			objSet[u[:i]] = true
		}
	}
	var objects, users []string
	for o := range objSet {
		objects = append(objects, o)
	}
	for u := range userSet {
		users = append(users, u)
	}
	sort.Strings(objects)
	sort.Strings(users)

	type probe struct{ object, relation, user string }
	var all []probe
	for _, o := range objects {
		typ, _, _ := strings.Cut(o, ":")
		for _, rel := range relsByType[typ] {
			for _, u := range users {
				all = append(all, probe{o, rel, u})
			}
		}
	}
	rng := rand.New(rand.NewSource(suiteSeed))
	rng.Shuffle(len(all), func(i, j int) {
		all[i], all[j] = all[j], all[i]
	})
	if len(all) > checksPerFixture {
		all = all[:checksPerFixture]
	}

	eng := sqlclient.New(testdb.Pool(t),
		uuidmap.New("realworld/"+filepath.Base(dir)))
	ora := oracle.Client(t)
	engStore, engModel := setup(t, eng, string(dslBytes), tuples)
	oraStore, oraModel := setup(t, ora, string(dslBytes), tuples)

	outcome := func(c probeClient, store, mdl string,
		p probe,
	) (string, string) {
		resp, err := c.Check(ctx, &openfgav1.CheckRequest{
			StoreId:              store,
			AuthorizationModelId: mdl,
			TupleKey: &openfgav1.CheckRequestTupleKey{
				Object: p.object, Relation: p.relation,
				User: p.user,
			},
		})
		if err != nil {
			s, _ := status.FromError(err)
			return fmt.Sprintf("code=%d", int(s.Code())),
				s.Message()
		}
		return fmt.Sprintf("allowed=%v", resp.GetAllowed()), ""
	}
	for _, p := range all {
		e, emsg := outcome(eng, engStore, engModel, p)
		o, omsg := outcome(ora, oraStore, oraModel, p)
		if e == o {
			continue
		}
		// Two documented strategy-dependent classes
		// (PIN-DEPTH-1 and the sibling-object condition-error
		// race, docs/CONFORMANCE.md): near the depth boundary
		// the engines may disagree between allowed=false and
		// 2002, and upstream's user-first iteration can surface
		// (nondeterministically) a 2000 condition error from a
		// sibling object's tuple where plain resolution answers
		// false. Tolerated in both directions; never
		// true-vs-anything.
		if (strings.HasPrefix(e, "code=2") &&
			o == "allowed=false") ||
			(e == "allowed=false" &&
				strings.HasPrefix(o, "code=2")) {
			t.Logf("documented divergence class "+
				"(docs/CONFORMANCE.md) at "+
				"%s#%s@%s: engine %s (%s), oracle %s (%s)",
				p.object, p.relation, p.user, e, emsg, o, omsg)
			continue
		}
		t.Errorf("check %s#%s@%s: engine %s (%s), oracle %s "+
			"(%s)", p.object, p.relation, p.user,
			e, emsg, o, omsg)
	}

	// One list_objects sweep on a seeded probe.
	if len(all) > 0 {
		p := all[0]
		typ, _, _ := strings.Cut(p.object, ":")
		engResp, engErr := eng.ListObjects(ctx,
			&openfgav1.ListObjectsRequest{
				StoreId:              engStore,
				AuthorizationModelId: engModel,
				Type:                 typ,
				Relation:             p.relation,
				User:                 p.user,
			})
		oraResp, oraErr := ora.ListObjects(ctx,
			&openfgav1.ListObjectsRequest{
				StoreId:              oraStore,
				AuthorizationModelId: oraModel,
				Type:                 typ,
				Relation:             p.relation,
				User:                 p.user,
			})
		engOut := listOutcome(engResp, engErr)
		oraOut := listOutcome(oraResp, oraErr)
		if engOut != oraOut {
			// The same strategy-dependent class as checks:
			// one side refuses 2xxx where the other
			// resolves — upstream's optimized reverse expansion
			// and the engine's over-approximated reachability
			// prune draw the relevant-edge boundary differently
			// on large models. A result-set mismatch without a
			// refusal still fails.
			if strings.HasPrefix(engOut, "code=2") !=
				strings.HasPrefix(oraOut, "code=2") {
				t.Logf("documented divergence class "+
					"(docs/CONFORMANCE.md) "+
					"at list_objects %s#%s@%s: engine %s, "+
					"oracle %s", typ, p.relation, p.user,
					engOut, oraOut)
			} else {
				t.Errorf("list_objects %s#%s@%s: engine %s, "+
					"oracle %s", typ, p.relation, p.user,
					engOut, oraOut)
			}
		}
	}
}

func listOutcome(resp *openfgav1.ListObjectsResponse,
	err error,
) string {
	if err != nil {
		s, _ := status.FromError(err)
		return fmt.Sprintf("code=%d", int(s.Code()))
	}
	objs := append([]string(nil), resp.GetObjects()...)
	sort.Strings(objs)
	return strings.Join(objs, ",")
}

// normalizeYAML round-trips a decoded YAML map through JSON so
// structpb accepts it (yaml decodes nested maps and numbers into
// shapes structpb.NewStruct refuses).
func normalizeYAML(m map[string]any) map[string]any {
	b, err := json.Marshal(m)
	if err != nil {
		return m
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		return m
	}
	return out
}
