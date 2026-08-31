package bench

import (
	"bytes"

	"github.com/google/uuid"
)

// Tuple is one fga.tuple row minus store and ulid: the store is
// fixed per load and the loader assigns ulids (monotonic,
// client-side) as it copies.
type Tuple struct {
	ObjectType      string
	ObjectID        uuid.UUID
	Relation        string
	SubjectType     string
	SubjectID       uuid.UUID
	SubjectRelation string
}

// pkLess orders tuples like the fga.tuple primary key within one
// store: (object_type, object_id, relation, subject_type,
// subject_id, subject_relation). Postgres compares uuid columns
// bytewise, matching bytes.Compare; the text columns here are
// fixed ASCII words, identical under C and locale collations.
func pkLess(a, b Tuple) bool {
	if a.ObjectType != b.ObjectType {
		return a.ObjectType < b.ObjectType
	}
	if c := bytes.Compare(
		a.ObjectID[:], b.ObjectID[:]); c != 0 {
		return c < 0
	}
	if a.Relation != b.Relation {
		return a.Relation < b.Relation
	}
	if a.SubjectType != b.SubjectType {
		return a.SubjectType < b.SubjectType
	}
	if c := bytes.Compare(
		a.SubjectID[:], b.SubjectID[:]); c != 0 {
		return c < 0
	}
	return a.SubjectRelation < b.SubjectRelation
}
