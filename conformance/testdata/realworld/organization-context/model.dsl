model
  schema 1.1

type user

type organization
  relations
    define member: [user]
    define project_manager: [user] and user_in_context
    define base_project_editor: [user] or project_manager
    define project_editor: base_project_editor and user_in_context
    define user_in_context: [user]

type project
  relations
    define owner: [organization]
    define partner: [organization]
    define manager: project_manager from owner
    define editor: manager or project_editor from owner or project_editor from partner
    define can_delete: manager
    define can_edit: editor
    define can_view: editor
