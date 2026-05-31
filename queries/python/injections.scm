;; extends

;; Inject markdown into mo.md("..." or r"..." or f"..." or """...""")
;; Handles: mo.md("text") and mo.md(text="...") and mo.md(r"""...""")
(call
  function: (attribute
    object: (identifier) @_mo (#eq? @_mo "mo")
    attribute: (identifier) @_fn (#eq? @_fn "md"))
  arguments: (argument_list
    (string
      (string_content) @injection.content))
  (#set! injection.language "markdown"))

;; Handle keyword arg: mo.md(text="...")
(call
  function: (attribute
    object: (identifier) @_mo (#eq? @_mo "mo")
    attribute: (identifier) @_fn (#eq? @_fn "md"))
  arguments: (argument_list
    (keyword_argument
      name: (identifier) @_kw (#eq? @_kw "text")
      value: (string
        (string_content) @injection.content)))
  (#set! injection.language "markdown"))

;; Inject SQL into mo.sql("...") calls
(call
  function: (attribute
    object: (identifier) @_mo (#eq? @_mo "mo")
    attribute: (identifier) @_fn (#eq? @_fn "sql"))
  arguments: (argument_list
    (string
      (string_content) @injection.content))
  (#set! injection.language "sql"))

;; Also handle assignment: result = mo.sql(f"...")
(assignment
  right: (call
    function: (attribute
      object: (identifier) @_mo (#eq? @_mo "mo")
      attribute: (identifier) @_fn (#eq? @_fn "sql"))
    arguments: (argument_list
      (string
        (string_content) @injection.content)))
  (#set! injection.language "sql"))
