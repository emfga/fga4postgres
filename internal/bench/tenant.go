package bench

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// tenant — a finite four-level tenant hierarchy with role
// ladders: platform → account → project → environment, plus
// invoices under accounts. 6 types, 37 relations, only [user]
// grants; every permission is a ladder of computed usersets and
// `x from parent`. The measured relation is environment#can_view,
// which flattens to four grant places: the leaf and its project
// ({admin, maintainer, writer, reader}), the account ({owner,
// admin, maintainer, writer, reader}) and the platform ({admin,
// support, auditor}).
//
// It is the compiled-relations scenario: the generic engine on
// the fixture store (not opted in), then the same store opted in
// for the generated __check / __objects and fga.check, and a
// name-sorted page of 50 leaves from a table of the consumer's
// own, filtered through __objects.
//
// Geometry: one platform; accounts of tProjects projects ×
// tEnvs environments (250 leaves) and tInvoices invoices each.
// Accounts: 20 at 100k (5,000 leaves) and size/2,500 from 1m
// (100,000 leaves at 1m) — see tAccounts.
//
// Measured subjects, one class per list variant:
//   - "all": tAdmins platform admins padmin-k see every leaf.
//   - "many": one account admin aadmin-a per account sees that
//     account's 250 leaves.
//   - "few": one leaf reader lreader-a per account is reader on
//     three leaves at fixed offsets of accounts a, a+1, a+2.
//
// The "few" and "many" reaches are size-invariant; "all" grows
// with the leaf count on purpose — it is the envelope a
// set-shaped __objects page pays (page cost grows with the
// subject's visible set).
//
// Background: every remaining tuple of the size is a direct
// grant on a leaf, cycling the seven directly assignable
// environment relations, to users user-0..U-1 (U = size/10).
// Background users never coincide with a measured subject, so
// they add rows to scan without changing any measured reach.
type tenantScenario struct{}

const (
	tProjects = 5  // projects per account
	tEnvs     = 50 // environments per project
	tLeaves   = tProjects * tEnvs
	tInvoices = 10 // invoices per account
	tAdmins   = 10 // platform admins
	tUserDiv  = 10
	// tPerAccount counts the fixed tuples of one account: its
	// parent edge, its admin, its projects' and leaves' parent
	// edges, its invoices' parent edges and its reader's three
	// leaf grants.
	tPerAccount = 1 + 1 + tProjects + tLeaves + tInvoices + 3
)

// tReaderOffsets are the leaf offsets (within an account) of a
// leaf reader's three grants, one per account a, a+1, a+2. They
// are distinct, so no leaf carries two readers' grants.
var tReaderOffsets = [3]int{17, 133, 241}

// tLeafRelations are environment's directly assignable
// relations, the background grants' cycle.
var tLeafRelations = []string{
	"admin", "maintainer", "writer", "reader", "deployer",
	"can_view_costs", "can_read_secrets",
}

// tAccounts holds the PR budget size (100k) to the 5,000 leaves
// the compiled page was first measured at; from 1m on, one
// account per 2,500 tuples gives 100,000 leaves at 1m. Only the
// "all" class sees the difference: an account is 250 leaves at
// every size.
func tAccounts(size Size) int {
	if size.Tuples <= 100_000 {
		return size.Tuples / 5_000
	}
	return size.Tuples / 2_500
}

func tUsers(size Size) int { return size.Tuples / tUserDiv }

// tFill is the number of background grants: the size minus every
// fixed tuple.
func tFill(size Size) int {
	return size.Tuples - tPerAccount*tAccounts(size) - tAdmins
}

func (tenantScenario) Name() string { return "tenant" }
func (tenantScenario) Model() []byte {
	return model("tenant")
}

// Variants: the generic engine first (the store is not opted in
// while they run), then the compiled cases, each of which opts
// the store in for its own duration. Generic list_objects has no
// "all" case: the engine resolves a platform admin's leaves one
// check at a time, measured at ~7 s per call at 5,000 leaves and
// beyond a 120 s statement bound at 100,000.
func (tenantScenario) Variants() []Variant {
	return []Variant{
		{"check", "hit-shallow"},
		{"check", "hit-deep"},
		{"check", "miss"},
		{"list_objects", "few"},
		{"list_objects", "many"},
		{"compiled_check", "hit-shallow"},
		{"compiled_check", "hit-deep"},
		{"compiled_check", "miss"},
		{"check_opted_in", "hit-shallow"},
		{"check_opted_in", "hit-deep"},
		{"check_opted_in", "miss"},
		{"compiled_objects", "few"},
		{"compiled_objects", "many"},
		{"compiled_objects", "all"},
		{"compiled_page", "few"},
		{"compiled_page", "many"},
		{"compiled_page", "all"},
	}
}

func tEnvName(l int) string { return fmt.Sprintf("env-%d", l) }

func tProjectName(p int) string {
	return fmt.Sprintf("project-%d", p)
}

func tAccountName(a int) string {
	return fmt.Sprintf("account-%d", a)
}

// tReaderLeaf is leaf reader a's k-th leaf.
func tReaderLeaf(a, k, accounts int) int {
	return ((a+k)%accounts)*tLeaves + tReaderOffsets[k]
}

func (s tenantScenario) Generate(
	seed uint64, size Size, emit func(Tuple) error,
) error {
	ns := namespace(s.Name(), seed)
	accounts := tAccounts(size)
	leaves := accounts * tLeaves
	fill := tFill(size)
	users := tUsers(size)
	id := func(name string) uuid.UUID { return entity(ns, name) }
	platform := id("platform")
	rows := make([]Tuple, 0, 16)

	// Object types in PK order: account, environment, invoice,
	// platform, project.
	for _, ref := range sortedRefs(accounts, func(i int) uuid.UUID {
		return id(tAccountName(i))
	}) {
		rows = append(rows[:0], Tuple{
			ObjectType: "account", ObjectID: ref.id,
			Relation: "parent", SubjectType: "platform",
			SubjectID: platform,
		}, Tuple{
			ObjectType: "account", ObjectID: ref.id,
			Relation: "admin", SubjectType: "user",
			SubjectID: id(fmt.Sprintf("aadmin-%d", ref.idx)),
		})
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}

	for _, ref := range sortedRefs(leaves, func(i int) uuid.UUID {
		return id(tEnvName(i))
	}) {
		l := ref.idx
		rows = append(rows[:0], Tuple{
			ObjectType: "environment", ObjectID: ref.id,
			Relation: "parent", SubjectType: "project",
			SubjectID: id(tProjectName(l / tEnvs)),
		})
		for k, off := range tReaderOffsets {
			if l%tLeaves != off {
				continue
			}
			a := (l/tLeaves - k + accounts) % accounts
			rows = append(rows, Tuple{
				ObjectType: "environment", ObjectID: ref.id,
				Relation: "reader", SubjectType: "user",
				SubjectID: id(fmt.Sprintf("lreader-%d", a)),
			})
		}
		// Background slot j sits on leaf (j/7) % leaves in round
		// j / (7·leaves). The user index adds the round, so two
		// rounds' grants of one (leaf, relation) — 7·leaves·m
		// slots apart — differ by m·(7·leaves + 1), never a
		// multiple of U (TestTenantFillUnique).
		for round := 0; ; round++ {
			base := (round*leaves + l) * len(tLeafRelations)
			if base >= fill {
				break
			}
			for r, rel := range tLeafRelations {
				j := base + r
				if j >= fill {
					break
				}
				rows = append(rows, Tuple{
					ObjectType:  "environment",
					ObjectID:    ref.id,
					Relation:    rel,
					SubjectType: "user",
					SubjectID: id(fmt.Sprintf(
						"user-%d", (j+round)%users)),
				})
			}
		}
		if err := emitObject(rows, emit); err != nil {
			return err
		}
	}

	for _, ref := range sortedRefs(accounts*tInvoices,
		func(i int) uuid.UUID {
			return id(fmt.Sprintf("invoice-%d", i))
		},
	) {
		if err := emit(Tuple{
			ObjectType: "invoice", ObjectID: ref.id,
			Relation: "parent", SubjectType: "account",
			SubjectID: id(tAccountName(ref.idx / tInvoices)),
		}); err != nil {
			return err
		}
	}

	rows = rows[:0]
	for k := 0; k < tAdmins; k++ {
		rows = append(rows, Tuple{
			ObjectType: "platform", ObjectID: platform,
			Relation: "admin", SubjectType: "user",
			SubjectID: id(fmt.Sprintf("padmin-%d", k)),
		})
	}
	if err := emitObject(rows, emit); err != nil {
		return err
	}

	for _, ref := range sortedRefs(accounts*tProjects,
		func(i int) uuid.UUID { return id(tProjectName(i)) },
	) {
		if err := emit(Tuple{
			ObjectType: "project", ObjectID: ref.id,
			Relation: "parent", SubjectType: "account",
			SubjectID: id(tAccountName(ref.idx / tProjects)),
		}); err != nil {
			return err
		}
	}
	return nil
}

// Query serves the check rules to check, compiled_check and
// check_opted_in alike, and the list rules to list_objects,
// compiled_objects and compiled_page, so the generic and the
// compiled case of one rule measure the same query stream.
func (s tenantScenario) Query(
	seed uint64, size Size, v Variant, i int,
) Query {
	ns := namespace(s.Name(), seed)
	accounts := tAccounts(size)
	li := uint64(i)
	user := func(format string, n int) string {
		return "user:" + entity(ns,
			fmt.Sprintf(format, n)).String()
	}
	leaf := func(l int) string {
		return "environment:" + entity(ns, tEnvName(l)).String()
	}
	list := func(u string) Query {
		return Query{Type: "environment", Relation: "can_view",
			User: u}
	}
	switch v.Feature {
	case "check", "compiled_check", "check_opted_in":
		switch v.Name {
		case "hit-shallow":
			// A direct reader grant on the leaf itself.
			a := rndBelow(seed, accounts, 'q', 1, li)
			k := rndBelow(seed, len(tReaderOffsets), 'q', 2, li)
			return Query{
				Object:   leaf(tReaderLeaf(a, k, accounts)),
				Relation: "can_view",
				User:     user("lreader-%d", a)}
		case "hit-deep":
			// Granted three parent hops up, on the platform.
			k := rndBelow(seed, tAdmins, 'q', 3, li)
			l := rndBelow(seed, accounts*tLeaves, 'q', 4, li)
			return Query{Object: leaf(l), Relation: "can_view",
				User: user("padmin-%d", k)}
		case "miss":
			// A leaf reader on a leaf of an account outside its
			// three: the resolver walks every grant place.
			a := rndBelow(seed, accounts, 'q', 5, li)
			b := (a + 3 + rndBelow(
				seed, accounts-3, 'q', 6, li)) % accounts
			o := rndBelow(seed, tLeaves, 'q', 7, li)
			return Query{Object: leaf(b*tLeaves + o),
				Relation: "can_view",
				User:     user("lreader-%d", a)}
		}
	case "list_objects", "compiled_objects", "compiled_page":
		switch v.Name {
		case "few":
			return list(user("lreader-%d",
				rndBelow(seed, accounts, 'q', 8, li)))
		case "many":
			return list(user("aadmin-%d",
				rndBelow(seed, accounts, 'q', 9, li)))
		case "all":
			return list(user("padmin-%d",
				rndBelow(seed, tAdmins, 'q', 10, li)))
		}
	}
	return Query{}
}

// LoadAppTables creates the consumer's own leaf table the page
// case filters: every environment with a name uncorrelated with
// its id or its place in the hierarchy, indexed for the ORDER BY.
func (s tenantScenario) LoadAppTables(
	ctx context.Context, pool *pgxpool.Pool, schema string,
	seed uint64, size Size,
) error {
	ns := namespace(s.Name(), seed)
	table := pgx.Identifier{schema, "environment"}
	q := table.Sanitize()
	for _, stmt := range []string{
		"CREATE SCHEMA IF NOT EXISTS " +
			pgx.Identifier{schema}.Sanitize(),
		"DROP TABLE IF EXISTS " + q,
		"CREATE TABLE " + q + " (id uuid PRIMARY KEY, " +
			"name text NOT NULL)",
	} {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			return err
		}
	}
	leaves := tAccounts(size) * tLeaves
	i := 0
	if _, err := pool.CopyFrom(ctx, table,
		[]string{"id", "name"},
		pgx.CopyFromFunc(func() ([]any, error) {
			if i == leaves {
				return nil, nil
			}
			name := rnd(seed, 'n', uint64(i))
			row := []any{
				entity(ns, tEnvName(i)).String(),
				fmt.Sprintf("env %016x", name),
			}
			i++
			return row, nil
		}),
	); err != nil {
		return err
	}
	for _, stmt := range []string{
		"CREATE INDEX ON " + q + " (name)",
		"ANALYZE " + q,
	} {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			return err
		}
	}
	return nil
}
