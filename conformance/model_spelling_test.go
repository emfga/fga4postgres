package conformance

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"testing"

	openfgav1 "github.com/openfga/api/proto/openfga/v1"

	"github.com/emfga/fga4postgres/internal/oracle"
	"github.com/emfga/fga4postgres/internal/sqlclient"
	"github.com/emfga/fga4postgres/internal/testdb"
)

// Upstream's HTTP API decodes a model with protojson, which takes a
// field under its proto name and under its JSON name, and discards a
// key it does not recognise. Where the two names differ a model has
// two spellings: the rewrite's computedUserset and tupleToUserset,
// and the computedUserset inside a tupleToUserset. Every other model
// field is named the same both ways, so its camelCase form is an
// unknown key and the model reads as if the field were absent. These
// tests send the same JSON to the oracle's HTTP API and to the
// engine, and compare.

// spellingModel is a model whose doc type has the given relations,
// beside a user type and a group type with members.
func spellingModel(relations string) string {
	return `{"schema_version": "1.1", "type_definitions": [
	  {"type": "user"},
	  {"type": "group",
	   "relations": {"member": {"this": {}}},
	   "metadata": {"relations": {
	     "member": {"directly_related_user_types": [{"type": "user"}]}}}},
	  {"type": "doc",
	   "relations": ` + relations + `,
	   "metadata": {"relations": {
	     "editor": {"directly_related_user_types": [{"type": "user"}]},
	     "blocked": {"directly_related_user_types": [{"type": "user"}]},
	     "parent": {"directly_related_user_types": [{"type": "group"}]}
	   }}}]}`
}

// The same doc relations in upstream's two spellings: viewer reaches
// editors, members of the parent group, and both at once, except
// blocked users.
const (
	snakeRelations = `{
	  "editor": {"this": {}}, "blocked": {"this": {}},
	  "parent": {"this": {}},
	  "viewer": {"difference": {
	    "base": {"union": {"child": [
	      {"computed_userset": {"relation": "editor"}},
	      {"tuple_to_userset": {
	        "tupleset": {"relation": "parent"},
	        "computed_userset": {"relation": "member"}}}]}},
	    "subtract": {"computed_userset": {"relation": "blocked"}}}},
	  "both": {"intersection": {"child": [
	    {"computed_userset": {"relation": "editor"}},
	    {"tuple_to_userset": {
	      "tupleset": {"relation": "parent"},
	      "computed_userset": {"relation": "member"}}}]}}}`
	camelRelations = `{
	  "editor": {"this": {}}, "blocked": {"this": {}},
	  "parent": {"this": {}},
	  "viewer": {"difference": {
	    "base": {"union": {"child": [
	      {"computedUserset": {"relation": "editor"}},
	      {"tupleToUserset": {
	        "tupleset": {"relation": "parent"},
	        "computedUserset": {"relation": "member"}}}]}},
	    "subtract": {"computedUserset": {"relation": "blocked"}}}},
	  "both": {"intersection": {"child": [
	    {"computedUserset": {"relation": "editor"}},
	    {"tupleToUserset": {
	      "tupleset": {"relation": "parent"},
	      "computedUserset": {"relation": "member"}}}]}}}`
)

func TestModelJSONSpellings(t *testing.T) {
	for _, c := range []struct{ name, model string }{
		{"snake_case rewrite", spellingModel(snakeRelations)},
		{"camelCase rewrite", spellingModel(camelRelations)},
		{"both spellings in one rewrite", spellingModel(`{
		  "editor": {"this": {}},
		  "viewer": {"computed_userset": {"relation": "editor"},
		             "computedUserset": {"relation": "editor"}}}`)},
		{"both spellings in one tupleToUserset", spellingModel(`{
		  "parent": {"this": {}},
		  "viewer": {"tuple_to_userset": {
		    "tupleset": {"relation": "parent"},
		    "computed_userset": {"relation": "member"},
		    "computedUserset": {"relation": "member"}}}}`)},
		{"camelCase directlyRelatedUserTypes",
			`{"schema_version": "1.1", "type_definitions": [
			  {"type": "user"},
			  {"type": "doc", "relations": {"viewer": {"this": {}}},
			   "metadata": {"relations": {"viewer":
			     {"directlyRelatedUserTypes": [{"type": "user"}]}}}}]}`},
	} {
		t.Run(c.name, func(t *testing.T) {
			want := oracleWriteModel(t, c.model)
			got := engineWriteModel(t, c.model)
			if got != want {
				t.Errorf("engine answered %d, oracle %d", got, want)
			}
		})
	}
}

// A camelCase model answers exactly as upstream answers it, on every
// rewrite operator the spelling reaches.
func TestCamelCaseModelAnswers(t *testing.T) {
	id := func(n int) string {
		return fmt.Sprintf("01900000-0000-7000-8000-%012d", n)
	}
	anne, bob, carl := "user:"+id(1), "user:"+id(2), "user:"+id(3)
	team, doc := "group:"+id(10), "doc:"+id(20)
	writes := mustJSON(t, map[string]any{"writes": map[string]any{
		"tuple_keys": []map[string]string{
			{"user": anne, "relation": "editor", "object": doc},
			{"user": team, "relation": "parent", "object": doc},
			{"user": anne, "relation": "member", "object": team},
			{"user": bob, "relation": "member", "object": team},
			{"user": bob, "relation": "blocked", "object": doc},
		}}})

	oracleStore := oracleCreateStore(t)
	oraclePost(t, "/stores/"+oracleStore+"/authorization-models",
		spellingModel(camelRelations))
	oraclePost(t, "/stores/"+oracleStore+"/write", writes)
	engineStore := engineCreateStore(t)
	engineCall(t, "fga.write_authorization_model", engineStore,
		spellingModel(camelRelations))
	engineCall(t, "fga.write", engineStore, writes)

	for _, user := range []string{anne, bob, carl} {
		for _, rel := range []string{"viewer", "both"} {
			check := mustJSON(t, map[string]any{"tuple_key": map[string]string{
				"user": user, "relation": rel, "object": doc}})
			var want, got struct{ Allowed bool }
			decode(t, oraclePost(t, "/stores/"+oracleStore+"/check", check),
				&want)
			decode(t, engineCall(t, "fga.check", engineStore, check), &got)
			if got != want {
				t.Errorf("%s %s: engine %v, oracle %v",
					user, rel, got.Allowed, want.Allowed)
			}
		}
	}
}

// oracleWriteModel writes model through the oracle's HTTP API and
// returns upstream's error code, 0 when it accepted the model.
func oracleWriteModel(t *testing.T, model string) int {
	t.Helper()
	status, body := oracleDo(t, http.MethodPost,
		"/stores/"+oracleCreateStore(t)+"/authorization-models", model)
	if status == http.StatusCreated {
		return 0
	}
	var e struct{ Code string }
	decode(t, body, &e)
	code, ok := openfgav1.ErrorCode_value[e.Code]
	if !ok {
		t.Fatalf("oracle answered %d with unknown code %q: %s",
			status, e.Code, body)
	}
	return int(code)
}

// engineWriteModel is oracleWriteModel for the engine, through SQL.
func engineWriteModel(t *testing.T, model string) int {
	t.Helper()
	_, err := testdb.Pool(t).Exec(context.Background(),
		"SELECT fga.write_authorization_model($1, $2::jsonb)",
		engineCreateStore(t), model)
	return int(sqlclient.Code(err))
}

func oracleCreateStore(t *testing.T) string {
	t.Helper()
	var store struct{ ID string }
	decode(t, oraclePost(t, "/stores", `{"name": "spelling"}`), &store)
	t.Cleanup(func() {
		oracleDo(t, http.MethodDelete, "/stores/"+store.ID, "")
	})
	return store.ID
}

func oraclePost(t *testing.T, path, body string) []byte {
	t.Helper()
	status, resp := oracleDo(t, http.MethodPost, path, body)
	if status/100 != 2 {
		t.Fatalf("POST %s: %d %s", path, status, resp)
	}
	return resp
}

func oracleDo(t *testing.T, method, path, body string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, oracle.URL()+path,
		bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v\nis the stack up? run: "+
			"docker compose up -d --wait", method, path, err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, b
}

func engineCreateStore(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	var store string
	err := testdb.Pool(t).QueryRow(ctx,
		"SELECT id FROM fga.create_store('spelling')").Scan(&store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = testdb.Pool(t).Exec(context.Background(),
			"SELECT fga.delete_store($1)", store)
	})
	return store
}

// engineCall runs fn(store, request) and returns its jsonb answer.
func engineCall(t *testing.T, fn, store, request string) []byte {
	t.Helper()
	var out []byte
	err := testdb.Pool(t).QueryRow(context.Background(),
		"SELECT "+fn+"($1, $2::jsonb)", store, request).Scan(&out)
	if err != nil {
		t.Fatalf("%s: %v", fn, err)
	}
	return out
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func decode(t *testing.T, b []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
}
