package conformance

import (
	"context"
	"testing"
)

// strategiesDSL compiles to every strategy: doc#owner flattened,
// doc#editor a set operation, doc#signed conditioned, group#member
// recursive (nested groups) and doc#guest delegated (a conditioned
// userset grant).
const strategiesDSL = `model
  schema 1.1
type user
type group
  relations
    define member: [user, group#member]
type doc
  relations
    define owner: [user]
    define blocked: [user]
    define editor: owner but not blocked
    define signed: [user with fresh]
    define guest: [group#member with fresh]
condition fresh(age: int) {
  age < 10
}
`

// The SET clause rule is per kind, whatever the strategy: __check
// carries search_path, __objects and __subjects carry nothing.
func TestCompiledConfigPerKind(t *testing.T) {
	ctx := context.Background()
	client := compiledEngine(t)
	storeID, _ := setup(t, client, strategiesDSL, nil)
	t.Cleanup(func() { _ = client.DeleteStore(ctx, storeID) })
	enableCompiled(t, storeID, compiledSchema(t))

	seen := map[string]bool{}
	for _, f := range registeredFns(t, storeID) {
		seen[f.strategy] = true
		fnShape(t, f)
	}
	for _, s := range []string{"flattened", "setop", "conditioned",
		"recursive", "delegated"} {
		if !seen[s] {
			t.Errorf("no relation compiled to %s: %v", s, seen)
		}
	}
}
