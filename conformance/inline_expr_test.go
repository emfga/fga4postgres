package conformance

import (
	"context"
	"flag"
	"regexp"
	"strings"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"github.com/openfga/language/pkg/go/transformer"
	"google.golang.org/grpc/status"

	"github.com/emfga/fga4postgres/internal/corpus"
	"github.com/emfga/fga4postgres/internal/skiplist"
)

// The engine refuses models with inline conditions
// ([user with $expression], upstream's experimental
// inline_expressions) at write (PIN-EXPR-1). The corpus cases
// that use them cannot pass, so they are excluded by name and
// every exclusion is printed in the skip register.
const inlineExprReason = "inline $expression conditions are " +
	"refused at model write (PIN-EXPR-1)"

func usesInlineExpression(tc corpus.Test) bool {
	for _, s := range tc.Stages {
		if strings.Contains(s.Model, "$expression") {
			return true
		}
	}
	return false
}

// inlineExpressionCases names the corpus tests that use inline
// conditions, in corpus order.
func inlineExpressionCases() ([]string, error) {
	files, err := corpus.Load()
	if err != nil {
		return nil, err
	}
	var names []string
	for _, f := range files {
		for _, tc := range f.Tests {
			if usesInlineExpression(tc) {
				names = append(names, tc.Name)
			}
		}
	}
	return names, nil
}

// The imported upstream runners start their own subtests and
// cannot call skiplist.Skip, so their inline-expression cases
// are removed with -test.skip before m.Run. Any -skip the caller
// passed is kept as another alternative.
func skipImportedInlineCases() error {
	names, err := inlineExpressionCases()
	if err != nil || len(names) == 0 {
		return err
	}
	quoted := make([]string, len(names))
	for i, n := range names {
		quoted[i] = regexp.QuoteMeta(n)
	}
	pattern := "TestImported.*Runners/RunAll.*/.*/^(" +
		strings.Join(quoted, "|") + ")(_ctxTuples)?$"
	if prev := flag.Lookup("test.skip").Value.String(); prev != "" {
		pattern = prev + "|" + pattern
	}
	return flag.Set("test.skip", pattern)
}

// The exclusions above are invisible to go test by construction;
// this test lists them, one skipped subtest per runner and case,
// so they reach the register and skipgen's harvest.
func TestImportedRunnerExclusions(t *testing.T) {
	names, err := inlineExpressionCases()
	if err != nil {
		t.Fatal(err)
	}
	if len(names) == 0 {
		t.Fatal("no inline $expression cases in the corpus; " +
			"drop the exclusion")
	}
	for _, runner := range []string{
		"Check", "ListObjects", "ListUsers",
	} {
		t.Run(runner, func(t *testing.T) {
			for _, n := range names {
				t.Run(n, func(t *testing.T) {
					skiplist.Skip(t, inlineExprReason)
				})
			}
		})
	}
}

// PIN-EXPR-1, refusing: the engine refuses a model with an inline
// condition with 2000 (validation_error). The oracle runs with
// upstream's default flags and refuses it with 2000 too; with
// inline_expressions on, upstream accepts it. This turns red when
// upstream enables the feature by default.
func TestPinnedInlineExpressionRefused(t *testing.T) {
	const dsl = `model
  schema 1.1
type user
type document
  relations
    define viewer: [user with $expression]
`
	model, err := transformer.TransformDSLToProto(dsl)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	for _, s := range bothSides(t, "pin-expr-1") {
		st, err := s.client.CreateStore(ctx,
			&openfgav1.CreateStoreRequest{Name: t.Name()})
		if err != nil {
			t.Fatalf("%s: create store: %v", s.name, err)
		}
		_, err = s.client.WriteAuthorizationModel(ctx,
			&openfgav1.WriteAuthorizationModelRequest{
				StoreId:         st.GetId(),
				SchemaVersion:   model.GetSchemaVersion(),
				TypeDefinitions: model.GetTypeDefinitions(),
				Conditions:      model.GetConditions(),
			})
		if code := int(status.Code(err)); code != 2000 {
			t.Errorf("%s: write model: %v, want code 2000",
				s.name, err)
		}
	}
}
