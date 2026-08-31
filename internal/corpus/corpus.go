// Package corpus loads the pinned upstream YAML conformance corpus
// straight from the openfga module's embedded assets — the bytes
// come from the pin, never from copied files — and classifies each
// case's feature set so skip decisions are computed, not listed by
// hand.
//
// The structs mirror the shapes upstream's runners decode into
// (internal/test/{check,listobjects,listusers} at the pin, which
// are internal and therefore not importable).
package corpus

import (
	"fmt"
	"regexp"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"
	"github.com/openfga/openfga/assets"
	"google.golang.org/protobuf/types/known/structpb"
	"sigs.k8s.io/yaml"
)

// Files is the corpus at the pin. The check/listobjects/listusers
// runners all read these same two files.
var Files = []string{
	"tests/consolidated_1_1_tests.yaml",
	"tests/abac_tests.yaml",
}

type File struct {
	Name  string // base name without extension, for subtest names
	Tests []Test
}

type Test struct {
	Name   string
	Stages []*Stage
}

type Stage struct {
	Name                  string
	Model                 string
	Tuples                []*openfgav1.TupleKey
	CheckAssertions       []*CheckAssertion       `json:"checkAssertions"`
	ListObjectsAssertions []*ListObjectsAssertion `json:"listObjectsAssertions"`
	ListUsersAssertions   []*ListUsersAssertion   `json:"listUsersAssertions"`
}

type CheckAssertion struct {
	Name             string
	ContextualTuples []*openfgav1.TupleKey `json:"contextualTuples"`
	Context          *structpb.Struct
	Tuple            *openfgav1.TupleKey
	Expectation      bool
	ErrorCode        int `json:"errorCode"`

	ListObjectsErrorCode int
	ListUsersErrorCode   int
}

type ListObjectsAssertion struct {
	Request          *openfgav1.ListObjectsRequest
	ContextualTuples []*openfgav1.TupleKey `json:"contextualTuples"`
	Context          *structpb.Struct
	Expectation      []string
	ErrorCode        int `json:"errorCode"`
}

type ListUsersAssertion struct {
	Request          *ListUsersRequest
	ContextualTuples []*openfgav1.TupleKey `json:"contextualTuples"`
	Context          *structpb.Struct
	Expectation      []string
	ErrorCode        int `json:"errorCode"`
}

type ListUsersRequest struct {
	Object   string
	Relation string
	Filters  []string `json:"filters"`
}

// Load reads and decodes the whole corpus from the pinned module.
func Load() ([]File, error) {
	var out []File
	for _, path := range Files {
		b, err := assets.EmbedTests.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", path, err)
		}
		var doc struct{ Tests []Test }
		if err := yaml.Unmarshal(b, &doc); err != nil {
			return nil, fmt.Errorf("decode %s: %w", path, err)
		}
		name := regexp.MustCompile(`^tests/|\.yaml$`).
			ReplaceAllString(path, "")
		out = append(out, File{Name: name, Tests: doc.Tests})
	}
	return out, nil
}

// conditionDecl spots condition declarations in the DSL model text
// without a parser: both the block form ("condition name(...)") and
// inline type restrictions ("[user with cond]").
var conditionDecl = regexp.MustCompile(
	`(?m)^\s*condition\s+\w+\s*\(|\[[^\]]*\bwith\s+\w+`,
)

// Features is one test case's computed feature set — the input to
// every phase's mechanical skip decision.
type Features struct {
	Conditions  bool // model, tuples, or assertions use conditions
	MultiStage  bool
	Check       int // assertion counts
	ListObjects int
	ListUsers   int
	CtxTuples   int // total contextual tuples across assertions
}

func Classify(tc Test) Features {
	var f Features
	f.MultiStage = len(tc.Stages) > 1
	for _, s := range tc.Stages {
		if conditionDecl.MatchString(s.Model) {
			f.Conditions = true
		}
		for _, tup := range s.Tuples {
			if tup.GetCondition() != nil {
				f.Conditions = true
			}
		}
		f.Check += len(s.CheckAssertions)
		f.ListObjects += len(s.ListObjectsAssertions)
		f.ListUsers += len(s.ListUsersAssertions)
		for _, a := range s.CheckAssertions {
			f.CtxTuples += len(a.ContextualTuples)
			if a.Context != nil {
				f.Conditions = true
			}
			for _, tup := range a.ContextualTuples {
				if tup.GetCondition() != nil {
					f.Conditions = true
				}
			}
		}
		for _, a := range s.ListObjectsAssertions {
			f.CtxTuples += len(a.ContextualTuples)
			if a.Context != nil {
				f.Conditions = true
			}
			for _, tup := range a.ContextualTuples {
				if tup.GetCondition() != nil {
					f.Conditions = true
				}
			}
		}
		for _, a := range s.ListUsersAssertions {
			f.CtxTuples += len(a.ContextualTuples)
			if a.Context != nil {
				f.Conditions = true
			}
			for _, tup := range a.ContextualTuples {
				if tup.GetCondition() != nil {
					f.Conditions = true
				}
			}
		}
	}
	return f
}
