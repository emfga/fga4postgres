model
  schema 1.1

type user

type folder
  relations
    define editor: [user]

type document
  relations
    define parent: [folder]
    define editor: [user] or editor from parent
