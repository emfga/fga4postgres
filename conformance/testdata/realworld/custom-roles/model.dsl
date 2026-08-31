model
  schema 1.1

type user

type role
  relations
    define assignee: [user]

type asset-category
  relations
    define viewer: [user, role#assignee] or editor
    define editor: [user, role#assignee]
