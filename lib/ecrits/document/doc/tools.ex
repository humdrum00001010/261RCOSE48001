defmodule Ecrits.Doc.Tools do
  @moduledoc """
  Reflective MCP tool surface for the document-editing abstraction (design §4.4).

  A *small* set of generic, document-addressed tools — every tool takes a
  `document` id and operates on that document (not just the one being viewed):

  | tool             | risk  | maps to |
  |------------------|-------|---------|
  | `doc.context`    | read  | current document metadata |
  | `doc.list`       | read  | nothing — see below |
  | `doc.open`       | read  | the (path, kind) handle, if a viewer holds it |
  | `doc.create`     | write | a file on disk + its handle |
  | `doc.read`       | read  | one `doc.find` ref -> nearby structural context |
  | `doc.find`       | read  | the viewer's `find` verb |
  | `doc.get`        | read  | the office viewer's `get` verb |
  | `doc.set`        | write | the viewer's `set` verb — UNIVERSAL property setter |
  | `doc.edit`       | write | the viewer's `edit` verb |
  | `doc.save`       | write | the viewer's exported bytes -> disk |

  EVERY document verb runs against the browser WASM model held by a viewing
  LiveView. Until 2026-07-29 each also had a server arm backed by
  `Ecrits.Doc.Pool`'s Editors; that registry could hold no document, so those
  arms were unreachable and went with it. The consequence the agent sees: **no
  viewer means no document** — `doc.list` is always empty (nothing enumerates
  documents any more), and a doc.* call on a file nobody has open is
  `document_not_found`.

  `doc.read` is an anchor clarifier: `doc.find` discovers refs, then
  `doc.read {ref, nearby: ...}` returns a tiny structural neighborhood (siblings,
  row/column/header context). Table context is compacted by common
  section/paragraph/control anchor and never dumps the whole grid by default.

  Tools run against a context map. `:session_path` (the workspace root) is what
  makes routing possible at all — it keys the `Ecrits.Workspace.Session` that
  owns the viewer registry. The **per-agent** form (design invariant 3) adds
  `:agent_id` (the calling agent, from its `/mcp/doc-tools/<agent_id>` url) and
  `:active_doc` (THAT agent's own active document id). In an agent context:

    * `doc.context` returns only the agent's OWN current document, so two agents
      never see each other's doc;
    * `doc.open` FAILS with `already_open` for an already-open doc (invariant 1)
      and records per-agent ownership;
    * `doc.edit` is `:forbidden` when another agent owns the doc (invariant 2),
      while an unowned (human-opened) doc is editable and lazily claimed.

  Results are JSON-shaped maps so the layer is testable server-side without a
  browser or an MCP transport. Errors that the agent is expected to act on
  (capability gaps, already_open/forbidden) are returned as structured maps
  mirroring the design's example payloads.
  """

  import Ecrits.Guards

  alias Ecrits.Doc.BrowserBridge
  alias Ecrits.Doc.DocumentId
  alias Ecrits.Doc.Op
  alias Ecrits.Doc.Read.Nearby
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Document.ByteSpool
  alias Ecrits.Workspace.Session

  @namespace "doc"

  # PubSub topic the workspace LiveView subscribes to so an agent file-write
  # (doc.create-clone / doc.save) refreshes the file tree LIVE — without waiting
  # for the (unreliable, fsevents-coalesced) FS watcher or the turn-end refresh.
  # The message carries the ABSOLUTE written path; each LiveView filters it to
  # paths under its own workspace root, so a write outside any open workspace
  # (a temp/scratch file) is ignored rather than spamming every tree.
  @workspace_files_topic "workspace:files"
  @workspace_files_pubsub Ecrits.PubSub

  @doc "PubSub topic the workspace LiveView subscribes to for agent file-writes."
  @spec workspace_files_topic() :: String.t()
  def workspace_files_topic, do: @workspace_files_topic

  @find_text_limit 48

  @tools [
    %{
      "namespace" => @namespace,
      "name" => "context",
      "description" =>
        "Current document metadata only. current_document is null or has document, " <>
          "name, path, kind, backing, and active. Use doc.list when you need the " <>
          "open-document catalog.",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "list",
      "description" =>
        "Always empty: nothing enumerates documents. Use doc.context for the " <>
          "document this caller is bound to.",
      "risk" => "read",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}},
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "open",
      "description" =>
        "The handle for a document a workspace tab currently holds. Returns " <>
          "{document, kind}, or `no_viewer` — nothing loads a document server-side.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx", "docx", "pptx", "xlsx"]}
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "create",
      "description" =>
        "Create a NEW output document at `path` (kind from extension). Use only " <>
          "when the user explicitly asks for a new/output document; never for " <>
          "read-only read/inspect/summarize tasks. doc.open never creates files. " <>
          "Optional `from` clones an existing file or open doc " <>
          "(byte-copy — inherits ALL template formatting; then replace content in " <>
          "place, don't rebuild its tables). Blank pptx/docx: " <>
          "design it yourself per this server's instructions (the design guide). " <>
          "Quick fixed-template pptx: pass `deck` {title, subtitle, slides:[...]}. " <>
          "Save with doc.save.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "minLength" => 1},
          "kind" => %{"type" => "string", "enum" => ["hwp", "hwpx", "docx", "pptx", "xlsx"]},
          "from" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Optional template to clone: an existing document file path OR an " <>
                "open document id. The file is byte-copied to `path` so the new document " <>
                "inherits all of the template's formatting."
          },
          "deck" => %{
            "type" => "object",
            "description" =>
              "PPTX-only scratch deck spec. Include slides with title/subtitle plus cards, metrics, and roadmap/steps for a designed deck.",
            "properties" => %{
              "title" => %{"type" => "string"},
              "subtitle" => %{"type" => "string"},
              "slides" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "title" => %{"type" => "string"},
                    "subtitle" => %{"type" => "string"},
                    "section" => %{"type" => "string"},
                    "bullets" => %{"type" => "array", "items" => %{"type" => "string"}},
                    "roadmap" => %{"type" => "array", "items" => %{"type" => "string"}},
                    "cards" => %{
                      "type" => "array",
                      "items" => %{
                        "type" => "object",
                        "properties" => %{
                          "title" => %{"type" => "string"},
                          "body" => %{"type" => "string"}
                        }
                      }
                    },
                    "metrics" => %{
                      "type" => "array",
                      "items" => %{
                        "type" => "object",
                        "properties" => %{
                          "label" => %{"type" => "string"},
                          "value" => %{"type" => "string"},
                          "delta" => %{"type" => "string"}
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        },
        "required" => ["path"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "read",
      "description" =>
        "Clarify one ref from doc.find. Returns nearby structural elements/table row/column context.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" =>
              "Document id/path. For the current/open document, call doc.context and use current_document.document."
          },
          "ref" => %{"type" => "string", "description" => "Anchor ref from doc.find."},
          "nearby" => %{
            "type" => "object",
            "description" =>
              "For text: before/after sibling count. For cell: row/column/headers booleans.",
            "properties" => %{
              "before" => %{"type" => "integer", "minimum" => 0, "maximum" => 10},
              "after" => %{"type" => "integer", "minimum" => 0, "maximum" => 10},
              "unit" => %{"type" => "string", "enum" => ["element"], "default" => "element"},
              "row" => %{"type" => "boolean"},
              "column" => %{"type" => "boolean"},
              "headers" => %{"type" => "boolean"}
            }
          },
          "include" => %{
            "type" => "array",
            "items" => %{
              "type" => "string",
              "enum" => ["text", "refs", "table_headers", "row_labels"]
            }
          }
        },
        "required" => ["document", "ref"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "find",
      "description" =>
        "Find text or elements. Use type:\"fillable\" for writable blanks/cells/inline gaps; " <>
          "type:\"formula_cell\" for spreadsheet formula cells when the engine exposes formula metadata. " <>
          "Returns compact text snippets; use doc.read/doc.get for full context. Batch with patterns:[].",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" =>
              "Document id/path. For the current/open document, call doc.context and use current_document.document."
          },
          "pattern" => %{"type" => "string"},
          "marker" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Optional literal marker inside a matched element. Each match then returns " <>
                "marker_offset and a canonical before_marker_ref whose offset is immediately " <>
                "before that marker. Pass before_marker_ref verbatim for native insertion."
          },
          "patterns" => %{
            "type" => "array",
            "description" =>
              "Batch form: several literal/regex patterns in one call; top-level all/regex/type/case_sensitive apply to each.",
            "items" => %{"type" => "string"}
          },
          "case_sensitive" => %{"type" => "boolean", "default" => false},
          "all" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "Return EVERY addressable element (body paragraphs AND table cells, " <>
                "empty cells included) and treat `pattern` as a regex. `pattern` is " <>
                "optional in this mode."
          },
          "regex" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "Treat `pattern` as a regular expression (implied by `all`)."
          },
          "type" => %{
            "type" => "string",
            "enum" => ~w(fillable empty_cell cell filled_cell formula_cell paragraph empty
                 table picture shape equation field form
                 header footer footnote endnote bookmark hyperlink
                 ruby auto_number new_number section_def column_def
                 page_number_pos page_hide hidden_comment char_overlap unknown),
            "description" =>
              "Element filter. `fillable` = writable blank/form/placeholder targets only; " <>
                "`formula_cell` = spreadsheet cells with formula metadata."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 2000,
            "description" => "Max matches returned."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "get",
      "description" => "Inspect ref(s): type, values, settable props, child refs.",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "refs" => %{
            "type" => "array",
            "description" => "Batch form: inspect every ref in this array; per-ref result.",
            "items" => %{"type" => "string"}
          },
          "props" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    },
    %{
      "namespace" => @namespace,
      "name" => "set",
      "description" =>
        "Set element props. char (default): Bold/Italic/Underline/TextColor/FontSize(pt). " <>
          "paragraph (props.kind:\"paragraph\"): Alignment:left|center|right|justify — center titles, " <>
          "right-align dates/signatures. cell (props.kind:\"cell\"): BackgroundColor. " <>
          "Use doc.get for prop names. Batch with sets:[{ref,props}].",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ref" => %{"type" => "string"},
          "props" => %{"type" => "object"},
          "sets" => %{
            "type" => "array",
            "description" =>
              "Batch form: an array of `{ref, props}` objects, each like the single form.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "ref" => %{"type" => "string"},
                "props" => %{"type" => "object"}
              },
              "required" => ["ref", "props"]
            }
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "edit",
      "description" =>
        "Apply ONE structural edit (`op`) or many in one call (`ops:[...]` — " <>
          "best-effort, per-op results; batch related edits). Op families: " <>
          "text: insert_text/replace_text/set_cell/delete_range. " <>
          "Paragraphs: insert_paragraph {ref, text, style?} / delete_paragraph / " <>
          "split / merge — refs like \"p3\" from doc.find, or \"end\". " <>
          "For existing HWP paragraph division, use split at offsets; " <>
          "replace_text with newlines does NOT create HWP paragraph nodes. " <>
          "Tables: insert_table {ref, rows, cols, cells?, header?} — pass cells:[[\"r0c0\",\"r0c1\"],[\"r1c0\",..]] " <>
          "(row-major) to CREATE AND FILL the table in ONE op (the reliable way to make a data " <>
          "table; do NOT insert_table empty then type values as body text — they'd land outside the " <>
          "table). header:true shades row 0 gray for a real-document header (use it for data tables). " <>
          "insert_table_row/insert_table_column {ref, below?/right?, count?} — count inserts " <>
          "N rows/cols in ONE op (\"add 10 rows\" = count:10), delete_table_row/_column, " <>
          "merge_cells {ref, start_row.., end_col}, split_cell — use a cell ref from " <>
          "doc.find; row/col default to that cell's own position. To edit ONE existing cell use " <>
          "set_cell {ref(from doc.find), text}. Table-op replies " <>
          "echo rows_after/cols_after — CHECK them against what you intended. " <>
          "Objects: insert_picture {src}, insert_shape, set_geometry {ref, x?, y?, " <>
          "w?, h?}, delete_node {ref}. Notes: insert_footnote/insert_endnote " <>
          "{ref, text}, insert_equation {ref, script}. Slides (pptx): insert_slide " <>
          "{name}; coordinates use the deck's actual slide size in 1/100 mm. " <>
          "Check doc.render slide_size/pixel_width/pixel_height before placing shapes. " <>
          "Layout: set_columns {count, from, " <>
          "to} — footnoted paragraphs must stay outside the range. " <>
          "Authoring pptx/docx slides/sections? Follow this server's instructions " <>
          "(the design guide); doc.render after each slide/section and LOOK at it.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "ops" => %{
            "type" => "array",
            "description" =>
              "Batch form: an array of op objects (each shaped like `op`). Applied " <>
                "best-effort with a per-op result; supply EITHER `op` (single) OR `ops`.",
            "items" => %{"type" => "object"}
          },
          "op" => %{
            "type" => "object",
            "description" =>
              "Edit object. Common: replace_text {query,replacement,ref?,all?}; insert_text {ref,text}; set_cell {ref,text}; delete_range {ref,count}; insert_table {ref,rows,cols}; set_columns {ref,count}.",
            "properties" => %{
              "op" => %{
                "type" => "string",
                "enum" =>
                  ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge insert_table insert_table_row delete_table_row insert_table_column delete_table_column merge_cells split_cell delete_node insert_picture set_cell insert_equation insert_footnote insert_endnote insert_shape set_columns insert_slide set_geometry)
              },
              "rows" => %{"type" => "integer", "description" => "insert_table: number of rows."},
              "cols" => %{
                "type" => "integer",
                "description" => "insert_table: number of columns."
              },
              "cells" => %{
                "type" => "array",
                "description" =>
                  "insert_table: row-major cell text [[r0c0,r0c1,..],[r1c0,..],..] — creates AND fills the table in one op. \\n in a cell splits it into cell paragraphs.",
                "items" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              "header" => %{
                "type" => "boolean",
                "description" =>
                  "insert_table: shade row 0 with a light-gray fill (real-document header look). Use for any data table with a header row. Optional header_color overrides the fill."
              },
              "header_color" => %{
                "type" => "string",
                "description" =>
                  "insert_table: header row fill color (hex, e.g. \"#d9d9d9\"); implies header."
              },
              "query" => %{
                "type" => "string",
                "description" => "replace_text: literal text to find."
              },
              "replacement" => %{
                "type" => "string",
                "description" =>
                  "replace_text: text to substitute in. Newlines are folded to spaces; for existing HWP paragraph division use split instead. REQUIRED for replace_text."
              },
              "ref" => %{
                "type" => "string",
                "description" =>
                  "Target element ref (from doc.find). Scopes the edit to that element/paragraph. XLSX insert_picture uses a cell ref like sheet[Sheet1]/cell[A1]."
              },
              "src" => %{
                "type" => "string",
                "description" =>
                  "insert_picture: local image file path to embed. For HWP/browser documents use a plain local path or file:// URL; the server reads it and sends inline image bytes to the editor."
              },
              "all" => %{
                "type" => "boolean",
                "description" =>
                  "replace_text: replace EVERY match (default false = first match only)."
              },
              "text" => %{
                "type" => "string",
                "description" =>
                  "insert_text: text to insert. set_cell: the cell's new content (\\n splits into cell paragraphs)."
              },
              "at" => %{
                "type" => "integer",
                "description" => "char offset within the target paragraph."
              },
              "count" => %{
                "type" => "integer",
                "description" =>
                  "delete_range: number of chars to delete. set_columns: number of columns."
              },
              "script" => %{
                "type" => "string",
                "description" =>
                  "insert_equation: HWP equation markup (the equation editor's source string), e.g. \"x^2 + y^2 = z^2\" or \"sqrt {a over b}\". REQUIRED for insert_equation."
              },
              "font_size" => %{
                "type" => "integer",
                "description" =>
                  "insert_equation: equation font size in HWPUNIT (point×100; 1000 = 10pt). Defaults to 1000."
              },
              "color" => %{
                "type" => "integer",
                "description" =>
                  "insert_equation: packed 0xBBGGRR color of the equation (default 0 = black)."
              },
              "shape_type" => %{
                "type" => "string",
                "description" =>
                  "insert_shape: shape kind — \"rectangle\" (default), \"ellipse\", \"line\", or \"textbox\"."
              },
              "width" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape: shape width in HWPUNIT (e.g. 8504 ≈ 3cm). HWP insert_picture: optional placed width in HWPUNIT; omit with height to use the image's natural aspect at the default size."
              },
              "height" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape: shape height in HWPUNIT. HWP insert_picture: optional placed height in HWPUNIT; omit with width to use the image's natural aspect at the default size."
              },
              "x" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture: horizontal position. Slide form (with `page`): 1/100 mm. HWP shape form (with `ref`): HWPUNIT offset (default 0)."
              },
              "y" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture: vertical position. Slide form (with `page`): 1/100 mm. HWP shape form (with `ref`): HWPUNIT offset (default 0)."
              },
              "w" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture (Office form): width in 1/100 mm, relative to the deck/page or spreadsheet cell anchor. REQUIRED for slide pictures with `page`; optional for DOCX inline and XLSX cell pictures."
              },
              "h" => %{
                "type" => "integer",
                "description" =>
                  "insert_shape / insert_picture (Office form): height in 1/100 mm, relative to the deck/page or spreadsheet cell anchor. REQUIRED for slide pictures with `page`; optional for DOCX inline and XLSX cell pictures."
              },
              "page" => %{
                "type" => "string",
                "description" =>
                  "insert_shape / insert_picture (slide form): target slide name (from insert_slide or doc.find refs page[<name>]). Selecting the slide form: raw UNO properties (FillColor, CharHeight, CharColor, CharWeight, CharFontName, ...) may be passed as additional keys and apply verbatim."
              },
              "service" => %{
                "type" => "string",
                "description" =>
                  "insert_shape (slide form): UNO shape service, e.g. com.sun.star.drawing.RectangleShape / .EllipseShape / .TextShape / .LineShape. Default TextShape."
              },
              "name" => %{
                "type" => "string",
                "description" =>
                  "insert_slide / insert_shape / insert_picture (Office form): REQUIRED name for slides and slide objects; the new ref becomes page[<name>] / page[<page>]/shape[<name>], img[<name>] for DOCX inline pictures, or sheet[<sheet>]/shape[<name>] for XLSX pictures."
              },
              "index" => %{
                "type" => "integer",
                "description" => "insert_slide: 0-based position (default: append at end)."
              },
              "fillColor" => %{
                "type" => "string",
                "description" =>
                  "insert_shape: solid fill color as CSS #RRGGBB, e.g. #FFA500 for orange."
              },
              "BackgroundColor" => %{
                "type" => "string",
                "description" => "insert_shape: alias for fillColor as CSS #RRGGBB."
              },
              "fillBgColor" => %{
                "type" => "integer",
                "description" => "insert_shape: solid fill color as packed HWP BGR 0x00BBGGRR."
              },
              "fillType" => %{
                "type" => "string",
                "enum" => ~w(solid none),
                "description" =>
                  "insert_shape: fill type; defaults to solid when a fill color is given."
              },
              "column_type" => %{
                "type" => "integer",
                "description" => "set_columns: 0=normal (default), 1=distribute, 2=parallel."
              },
              "same_width" => %{
                "type" => "boolean",
                "description" => "set_columns: equal-width columns (default true)."
              },
              "spacing" => %{
                "type" => "integer",
                "description" => "set_columns: inter-column gap in HWPUNIT (default 0)."
              }
            },
            "required" => ["op"]
          },
          "verbose" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "For batch ops, include every per-op result. Default false returns counts plus failures only."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "save",
      "description" => "Persist the document to disk (export). Returns only ok/error.",
      "risk" => "write",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "path" => %{
            "type" => "string",
            "description" => "Optional save target; defaults to the document's current path."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => false}
    },
    %{
      "namespace" => @namespace,
      "name" => "render",
      "description" =>
        "Render page(s)/slide(s) to PNG FILES and return their paths — VIEW the " <>
          "returned file with your image tool (codex: view_image; claude: Read the " <>
          "path) to SEE the result; render-after-edit is the expected feedback loop. " <>
          "`page` = slide name (office) or 1-based page number (HWP); omit to " <>
          "render all (capped at 8).",
      "risk" => "read",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string"},
          "page" => %{
            "type" => "string",
            "description" => "Slide name (refs look like page[<name>]). Omit for all slides."
          },
          "width" => %{
            "type" => "integer",
            "description" => "Pixel width per image (default 880, max 1920)."
          }
        },
        "required" => ["document"]
      },
      "annotations" => %{"readOnlyHint" => true}
    }
  ]

  @doc "The MCP tool catalog for the document abstraction."
  @spec tools() :: [map()]
  def tools, do: @tools

  @doc "Canonical `namespace.name` for each tool."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tools, &(&1["namespace"] <> "." <> &1["name"]))

  @doc """
  Dispatch an MCP tool call.

  `ctx` is `%{session_path: root}` at minimum (nothing routes without it) or the
  per-agent form `%{session_path: root, agent_id: id, active_doc: doc_id}`
  (design invariant 3 — see the module doc for the open/ownership semantics).
  """
  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(ctx \\ %{}, tool_name, args)

  def call(ctx, "doc.context", _args) do
    {:ok, context_json(ctx)}
  end

  # The open-document catalog was the server registry's enumeration. Nothing
  # enumerates documents any more: the browser holds them, and a viewer answers
  # only about the one it holds. `doc.context` is the surviving question.
  def call(_ctx, "doc.list", _args) do
    {:ok, %{"documents" => []}}
  end

  def call(ctx, "doc.open", args) do
    with {:ok, path} <- require_string(args, "path"),
         # Don't open files outside the workspace (prompt-injection guard).
         {:ok, path} <- confine_path(ctx, path) do
      kind = args |> get(["kind"]) |> normalize_kind(path)

      # Invariant 1 ("one doc = one live model"): in an agent context, opening a
      # doc that is ALREADY open FAILS with `already_open` + who holds it — the
      # agent references the existing id rather than grabbing a second handle.
      case open_preflight(ctx, path, kind) do
        :ok ->
          do_open_tool(ctx, path, kind)

        {:error, structured} ->
          {:error, structured}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.create", args) do
    with :ok <- enforce_writable(ctx),
         {:ok, path} <- require_string(args, "path"),
         {:ok, path} <- confine_path(ctx, path) do
      kind = args |> get(["kind"]) |> normalize_kind(path)

      case get(args, ["from"]) do
        nil -> create_blank(ctx, path, kind, args)
        from when is_present(from) -> create_from(ctx, path, kind, from)
        _ -> {:error, error_json({:invalid_params, "from must be a non-empty string"})}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.read", args) do
    with {:ok, _ref} <- require_string(args, "ref") do
      nearby = args |> get(["nearby"]) |> Nearby.cast!() |> Nearby.dump()

      args =
        args
        |> Map.delete(:nearby)
        |> Map.put("nearby", nearby)

      route_doc(ctx, args,
        browser: fn lv ->
          browser_call(lv, args, :read, %{
            opts: take_opts(args, ["ref", "nearby", "include"])
          })
        end
      )
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.find", args) do
    all = get(args, ["all"]) || false
    regex = get(args, ["regex"]) || false
    type = get(args, ["type"])

    # `pattern` is required for a literal search, but optional in discovery mode
    # (`all`/`regex`/`type`): {all:true} or {type:"empty_cell"} with no pattern
    # enumerates by structure, so default to "" rather than hard-failing.
    case get(args, ["patterns"]) do
      patterns when is_list(patterns) ->
        with {:ok, patterns} <- normalize_find_patterns(patterns) do
          route_doc(ctx, args,
            browser: fn lv ->
              browser_call(lv, args, :find, %{
                patterns: patterns,
                case_sensitive: get(args, ["case_sensitive"]) || false,
                all: all,
                regex: regex,
                type: type,
                limit: find_limit(args)
              })
            end
          )
          |> compact_find_response(args)
        end

      _ ->
        with {:ok, pattern} <-
               find_pattern(args, all || regex || is_present(type)) do
          route_doc(ctx, args,
            browser: fn lv ->
              browser_call(lv, args, :find, %{
                pattern: pattern,
                case_sensitive: get(args, ["case_sensitive"]) || false,
                all: all,
                regex: regex,
                type: type,
                limit: find_limit(args)
              })
            end
          )
          |> compact_find_response(args)
        end
    end
  end

  # doc.get inspects a ref: its element type, current property VALUES, the
  # settable property NAMES (the native-property vocabulary), and child refs.
  # This folds the former standalone `doc.inspect` into the one read-properties
  # tool, so the agent has a single place to discover what it can set and what
  # the current values are.
  # `refs:[...]` (batch) takes precedence over `ref` (single). Open Office docs
  # inspect the browser IR; other docs inspect each ref best-effort on the server
  # editor and return a per-ref `results`.
  def call(ctx, "doc.get", args) do
    props = get(args, ["props"])

    case get(args, ["refs"]) do
      refs when is_list(refs) ->
        office_browser_get(ctx, args, %{refs: refs, props: props})

      _ ->
        with {:ok, ref} <- require_string(args, "ref") do
          office_browser_get(ctx, args, %{ref: ref, props: props})
        end
    end
  end

  # `sets:[{ref,props}, ...]` (batch) takes precedence over `ref`+`props` (single).
  def call(ctx, "doc.set", args) do
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document),
         :ok <- enforce_ownership(ctx, document) do
      ctx
      |> do_set(args)
      |> maybe_uncache_projection_after_edit(ctx, document)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # `ops:[...]` (batch) takes precedence over `op` (single) when present.
  def call(ctx, "doc.edit", args) do
    # Invariant 2 ("one agent per doc"): in an agent context, editing a doc owned
    # by a DIFFERENT agent is :forbidden. An UNOWNED doc (e.g. the human-opened
    # viewed HWP) is editable and is lazily claimed by this agent on first edit,
    # so the common single-agent flow keeps working while a 2nd agent is fenced
    # out. A bare pool-only context skips the check entirely.
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         :ok <- reject_retired_edit_metadata(args),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document),
         :ok <- enforce_ownership(ctx, document) do
      ctx
      |> do_edit(args)
      |> maybe_uncache_projection_after_edit(ctx, document)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.save", args) do
    with :ok <- enforce_writable(ctx),
         :ok <- enforce_complete_turn_identity(ctx),
         {:ok, document} <- require_string(args, "document"),
         {:ok, document, info} <- resolve_save_document(ctx, document),
         :ok <- enforce_ownership(ctx, document),
         {:ok, path} <- confine_path(ctx, get(args, ["path"]) || info.path) do
      args = Map.put(args, "document", document)

      # The browser WASM model is the authority: export ITS edited bytes and
      # write them to disk. `info` survives only to resolve `path` above.
      _ = info

      route_doc(ctx, args, browser: fn lv -> save_browser(lv, args, path) end)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(ctx, "doc.render", args) do
    with {:ok, document} <- require_string(args, "document"),
         {:ok, document} <- canonical_document(ctx, document) do
      case route(ctx, document) do
        {:browser, lv} ->
          # The browser WASM model is the authority for a viewed doc — so render
          # THAT: snapshot its current bytes (the same channel doc.save uses).
          render_viewed_snapshot(lv, args)

        {:error, :not_found} ->
          {:error, error_json(:not_found)}
      end
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  def call(_ctx, tool_name, _args), do: {:error, {:unknown_tool, tool_name}}

  # ── doc.render, browser (viewed) arm ────────────────────────────────────
  # Pull the viewer's CURRENT bytes and render them. A clean document used to
  # take a server-twin fast path instead; that twin never existed.
  defp render_viewed_snapshot(lv, args) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = saved} ->
        case ByteSpool.decode(saved) do
          {:ok, bytes} ->
            render_viewed_bytes(bytes, viewed_kind(saved), args)

          {:error, _reason} ->
            {:error, error_json({:render_failed, "viewer returned no/invalid bytes"})}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The viewer names the format it exported; nothing server-side knows better.
  defp viewed_kind(saved) do
    case saved["format"] || saved[:format] do
      "hwpx" -> :hwpx
      "docx" -> :docx
      "pptx" -> :pptx
      "xlsx" -> :xlsx
      _ -> :hwp
    end
  end

  # Server-side page rasterization came from the headless NIFs (Ehwp.render_page_png
  # / Doc.Office.render_page), removed 2026-07-26 with the engine deps. Rendering
  # is now the browser engine's job. Fail with a routable reason instead of
  # calling modules that no longer exist — a runtime UndefinedFunctionError here
  # would surface to the agent as an opaque crash.
  # See docs/plans/2026-07-26-doclang-engine-migration.md.
  defp render_viewed_bytes(_bytes, kind, _args) when kind in [:hwp, :hwpx] do
    {:error,
     error_json(
       {:render_failed,
        "server-side #{kind} rendering was removed with the native engine; render via the browser engine"}
     )}
  end

  defp render_viewed_bytes(_bytes, kind, _args) when kind in [:docx, :pptx, :xlsx] do
    {:error,
     error_json(
       {:render_failed,
        "server-side #{kind} rendering was removed with the native engine; render via the browser engine"}
     )}
  end

  # doc.save needs a save TARGET as well as a routable document, and an id is a
  # hash — it cannot yield one. The path therefore comes from the caller: the
  # ctx's viewed `document_path`, or the `document` argument when that argument
  # IS a path.
  defp resolve_save_document(ctx, document) do
    canonical =
      case canonical_document(ctx, document) do
        {:ok, id} -> id
        {:error, _reason} -> document
      end

    case active_browser_save_document(ctx, canonical) do
      {:ok, document_id, info} -> {:ok, document_id, info}
      :error -> viewed_path_save_document(ctx, document)
    end
  end

  defp viewed_path_save_document(ctx, document) do
    with {:ok, path} <- confine_path(ctx, document),
         kind when not is_nil(kind) <- kind_from_path(path),
         document_id = DocumentId.for_path(path, kind),
         true <- is_pid(session_viewer(ctx, document_id)) do
      {:ok, document_id, %{id: document_id, kind: kind, path: path, backing: :browser}}
    else
      {:error, _reason} = error -> error
      _no_viewer -> {:error, :not_found}
    end
  end

  defp active_browser_save_document(ctx, document) do
    active_doc = Map.get(ctx, :active_doc)
    path = Map.get(ctx, :document_path)

    with true <- is_present(active_doc),
         true <- session_viewer(ctx, active_doc) != nil,
         true <- document == active_doc or document_matches_path?(document, path),
         path when is_present(path) <- path,
         {:ok, path} <- confine_path(ctx, path),
         kind when not is_nil(kind) <- kind_from_path(path) do
      {:ok, active_doc, %{id: active_doc, kind: kind, path: path, backing: :browser}}
    else
      _ -> :error
    end
  end

  defp document_matches_path?(document, path) when is_binary(document) and is_binary(path) do
    normalized = String.trim_leading(document, "./")

    document == path or
      String.ends_with?(path, "/" <> normalized) or
      Path.basename(path) == normalized
  end

  defp document_matches_path?(_document, _path), do: false

  # --- doc.edit dispatch (after the ownership gate) ------------------------

  defp do_set(ctx, args) do
    case get(args, ["sets"]) do
      sets when is_list(sets) ->
        route_doc(ctx, args, browser: fn lv -> browser_set_batch(lv, args, sets) end)

      _other ->
        with {:ok, ref} <- require_string(args, "ref"),
             {:ok, props} <- require_map(args, "props") do
          route_doc(ctx, args, browser: fn lv -> browser_set(lv, args, ref, props) end)
        end
    end
  end

  defp do_edit(ctx, args) do
    case get(args, ["ops"]) do
      ops when is_list(ops) ->
        # Batch form: apply many edits in one call, best-effort with a per-op
        # result. Each op is normalised per-op for the browser payload (same as
        # the single path), so a malformed op is rejected individually.
        route_doc(ctx, args, browser: fn lv -> browser_write_batch(lv, args, ops) end)

      _ ->
        with {:ok, op} <- require_map(args, "op") do
          # Authority is the browser engine model: deliver the structural edit to
          # the owning LiveView -> the canvas hook applies it to that model.
          route_doc(ctx, args, browser: fn lv -> browser_write(lv, args, op) end)
        end
    end
  end

  # A successful native edit changes the engine model behind an already-served
  # FSKit inode. Keep that inode's exact bytes stable and stage the new canonical
  # projection for the same fresh-sibling terminal publication used by ACP VFS
  # edits. An OpenDocs cache delete alone cannot invalidate FSKit page state.
  defp maybe_uncache_projection_after_edit(result, ctx, document) do
    if edit_mutated?(result) do
      # DERIVED, not looked up: `OpenDocs.name_for_source/2` only ever knew what
      # `doc.open_doc` registered, so with that tool gone it answers `:error` for
      # every document and this staging would silently stop happening.
      with {:ok, root} <- vfs_root(ctx),
           {:ok, source_path} <- edited_document_path(ctx, document),
           name = DocMount.mount_name(Path.relative_to(source_path, root)),
           metadata = %{
             agent_id: Map.get(ctx, :agent_id),
             instance_id: Map.get(ctx, :instance_id),
             turn_id: Map.get(ctx, :turn_id),
             source_path: source_path
           },
           {:ok, accepted_bytes, generation} <-
             OpenDocs.begin_canonical_stage(root, name, metadata),
           {:ok, canonical_bytes} <-
             Ecrits.Doc.Projection.project_file(source_path, root: root) do
        OpenDocs.complete_canonical_stage(
          root,
          name,
          accepted_bytes,
          canonical_bytes,
          generation,
          metadata
        )
      end
    end

    result
  end

  defp edit_mutated?({status, %{"applied" => applied}})
       when status in [:ok, :error] and is_integer(applied),
       do: applied > 0

  defp edit_mutated?({:ok, %{"native" => native}}), do: native_edit_mutated?(native)
  defp edit_mutated?({:ok, %{"replaced" => 0}}), do: false
  defp edit_mutated?({:ok, _result}), do: true
  defp edit_mutated?(_result), do: false

  defp native_edit_mutated?(results) when is_list(results),
    do: Enum.any?(results, &native_edit_mutated?/1)

  defp native_edit_mutated?(%{} = result), do: get(result, ["ok"]) != false
  defp native_edit_mutated?(_result), do: true

  defp edited_document_path(ctx, document) do
    active_doc = Map.get(ctx, :active_doc)
    path = Map.get(ctx, :document_path)

    if active_doc == document and is_present(path) do
      confine_path(ctx, path)
    else
      :error
    end
  end

  # Reject the old protocol at the envelope and each selected operation before
  # routing. In particular, a batch must not partially mutate a document merely
  # because one of its operations still carries retired metadata.
  defp reject_retired_edit_metadata(args) do
    with :ok <- Op.reject_retired_metadata(args) do
      args
      |> edit_ops()
      |> Enum.reduce_while(:ok, fn op, :ok ->
        case Op.reject_retired_metadata(op) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp edit_ops(args) do
    case get(args, ["ops"]) do
      ops when is_list(ops) -> ops
      _ -> List.wrap(get(args, ["op"]))
    end
  end

  # --- doc.open helpers (per-agent open + ownership) -----------------------

  # Decide whether `path`/`kind` may be opened in THIS context.
  #   * Bare pool-only context → :ok (legacy reuse path; no isolation).
  #   * Agent context, doc NOT open → :ok (it will be opened + owned).
  #   * Agent context, doc ALREADY open → {:error, already_open} naming who holds
  #     it (this agent / another agent / a human viewer), so the agent references
  #     the existing id instead of grabbing a second handle (invariant 1).
  defp open_preflight(%{agent_id: agent_id} = ctx, path, kind) do
    doc_id = DocumentId.for_path(path, kind)

    if document_open?(ctx, doc_id) do
      {:error, already_open_json(ctx, doc_id, agent_id)}
    else
      :ok
    end
  end

  defp open_preflight(_ctx, _path, _kind), do: :ok

  # `doc.open` no longer LOADS anything — the engine is in the browser and the
  # server cannot start a model. What it still does is hand back the handle for
  # a path, and it refuses when nothing holds that document, because a handle
  # for an unviewed file routes nowhere and every later doc.* call on it would
  # fail with the less informative `document_not_found`.
  defp do_open_tool(ctx, path, kind) do
    doc_id = DocumentId.for_path(path, kind)

    case route(ctx, doc_id) do
      {:browser, _lv} ->
        _ = maybe_claim_owner(ctx, doc_id)
        {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind)}}

      {:error, :not_found} ->
        {:error, error_json({:no_viewer, path})}
    end
  end

  # A doc is "open" iff a live viewer holds its model.
  defp document_open?(ctx, doc_id) do
    case route(ctx, doc_id) do
      {:error, :not_found} -> false
      _ -> true
    end
  end

  # The `already_open` structured error: the existing document id + who holds it.
  # held_by is `self` (this agent already owns it), `{:agent, id}` (another
  # agent), or `:viewer` (a human-viewed/browser-backed doc with no agent owner).
  defp already_open_json(ctx, doc_id, agent_id) do
    %{
      "error" => "already_open",
      "document" => doc_id,
      "held_by" => held_by(ctx, doc_id, agent_id)
    }
  end

  defp held_by(ctx, doc_id, agent_id) do
    case owner(ctx, doc_id) do
      ^agent_id ->
        %{"kind" => "self", "agent_id" => agent_id}

      owner when is_binary(owner) ->
        %{"kind" => "agent", "agent_id" => owner}

      nil ->
        case route(ctx, doc_id) do
          {:browser, _lv} -> %{"kind" => "viewer"}
          _ -> %{"kind" => "unowned"}
        end
    end
  end

  defp maybe_claim_owner(%{agent_id: agent_id} = ctx, doc_id) when is_binary(agent_id),
    do: claim_owner(ctx, doc_id, agent_id)

  defp maybe_claim_owner(_ctx, _doc_id), do: :ok

  # Per-doc ownership (invariant 2) lives in the per-workspace
  # `Ecrits.Workspace.Session` (the real home of `owners` since Phase 3). It is
  # consulted ONLY when the ctx carries a `:session_path` — the production agent
  # path always does. A context without one (the bare MCP mount, or a direct
  # `Tools.call(%{}, …)` in a test) has no Session, so ownership is not enforced
  # there (it never was isolated): `owner` reports none and `claim` always
  # succeeds.
  defp owner(ctx, doc_id) do
    case Map.get(ctx, :session_path) do
      path when is_present(path) -> Session.owner(path, doc_id)
      _ -> nil
    end
  end

  defp claim_owner(ctx, doc_id, agent_id) do
    case Map.get(ctx, :session_path) do
      path when is_present(path) -> Session.claim_owner(path, doc_id, agent_id)
      _ -> :ok
    end
  end

  # --- doc.edit ownership enforcement (invariant 2) ------------------------

  # In an agent context, gate a write on ownership. `claim_owner` is the single
  # authoritative arbiter (it succeeds for the current owner OR an unowned doc,
  # and fails only when ANOTHER agent owns it), so this both enforces the fence
  # AND lazily claims an unowned doc for the editing agent. A bare pool-only
  # context (no agent_id) skips ownership entirely.
  defp enforce_ownership(%{agent_id: agent_id} = ctx, document) when is_binary(agent_id) do
    case claim_owner(ctx, document, agent_id) do
      :ok ->
        :ok

      {:error, {:owned, owner}} ->
        {:error,
         %{"error" => "forbidden", "document" => document, "owned_by" => %{"agent_id" => owner}}}
    end
  end

  defp enforce_ownership(_ctx, _document), do: :ok

  defp enforce_complete_turn_identity(%{agent_id: agent_id, session_path: session_path} = ctx)
       when is_present(agent_id) and is_present(session_path) do
    if Enum.all?([:instance_id, :turn_id], fn key ->
         value = Map.get(ctx, key)
         is_present(value)
       end) do
      :ok
    else
      {:error,
       {:invalid_params, "an agent document write requires the active instance_id and turn_id"}}
    end
  end

  defp enforce_complete_turn_identity(_ctx), do: :ok

  # --- doc.create helpers --------------------------------------------------

  # doc.create without `from`: a blank engine template whose save target is `path`.
  # PPTX with `deck` -> the designed PptxBuilder template; without `deck` -> a
  # LibreOffice factory-blank presentation, the seed for IR-direct from-scratch
  # authoring (insert_slide / insert_shape edit ops).
  defp create_blank(ctx, path, :pptx, args) do
    deck = get(args, ["deck"])

    if is_map(deck) do
      create_pptx(ctx, path, deck)
    else
      # The factory-blank deck came from the LibreOffice NIF, removed 2026-07-26.
      # Authoring a blank pptx now needs the browser engine.
      {:error,
       error_json(
         {:create_failed,
          "blank pptx creation needs the native engine, removed with :libreofficex; supply a `deck` or author via the browser engine"}
       )}
    end
  end

  # docx mirrors the pptx factory-blank path: the engine's own "new text
  # document" exported as docx, then opened for IR-direct Writer authoring
  # (insert_paragraph / insert_table / insert_picture / insert_footnote /
  # set_columns edit ops). The generic clause below requires backend.new/1,
  # which Office (create_blank_file/2) does not expose.
  defp create_blank(ctx, path, :docx, _args) do
    _ = {ctx, path}

    # Same as pptx above: the engine's "new text document" export is gone with
    # :libreofficex. See docs/plans/2026-07-26-doclang-engine-migration.md.
    {:error,
     error_json(
       {:create_failed,
        "blank docx creation needs the native engine, removed with :libreofficex; author via the browser engine"}
     )}
  end

  # Blank creation needed a SERVER backend to mint the document. `backend_for/1`
  # returns nil for every kind since `:ehwp`/`:libreofficex` were deleted
  # (2026-07-26), so this could only ever report unsupported — same as the docx
  # clause above. Authoring from scratch happens through the browser engine.
  defp create_blank(_ctx, _path, kind, _args) do
    {:error, error_json({:unsupported_kind, kind})}
  end

  defp create_pptx(ctx, path, deck) do
    with :ok <- Ecrits.Doc.PptxBuilder.write(path, deck) do
      broadcast_file_written(path)

      doc_id = DocumentId.for_path(path, :pptx)
      _ = maybe_claim_owner(ctx, doc_id)
      {:ok, %{"document" => doc_id, "kind" => "pptx", "path" => path}}
    else
      {:error, reason} -> {:error, error_json({:create_failed, reason})}
    end
  end

  defp create_from(ctx, path, kind, from) do
    with {:ok, source} <- resolve_template_path(ctx, from),
         :ok <- copy_template(source, path) do
      # The template was byte-copied to `path`, so a NEW file now exists on disk
      # — announce it so the workspace tree shows it without a manual refresh.
      broadcast_file_written(path)

      # The handle is DERIVED from (path, kind): the file exists now, so this is
      # the id it will route under as soon as a viewer holds it.
      doc_id = DocumentId.for_path(path, kind)
      _ = maybe_claim_owner(ctx, doc_id)
      {:ok, %{"document" => doc_id, "kind" => Atom.to_string(kind), "cloned_from" => source}}
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # `from` is a file path. It could also name an open document id while a
  # registry could map that id back to a path; none can.
  defp resolve_template_path(_ctx, from) do
    if File.regular?(from),
      do: {:ok, from},
      else: {:error, {:template_not_found, from}}
  end

  defp copy_template(source, path) do
    with :ok <- ensure_parent_dir(path),
         :ok <- File.cp(source, path) do
      :ok
    else
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  end

  defp ensure_parent_dir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  end

  # --- doc.read / doc.find server arms -------------------------------------

  defp compact_find_response({:ok, %{} = result}, args),
    do: {:ok, compact_find_result(result, args)}

  defp compact_find_response(other, _args), do: other

  defp compact_find_result(%{} = result, args) do
    case map_field(result, ["results", :results]) do
      results when is_list(results) ->
        result
        |> delete_map_keys(["results", :results])
        |> Map.put("results", Enum.map(results, &compact_find_entry(&1, args)))

      _ ->
        compact_find_entry(result, args)
    end
  end

  defp compact_find_entry(%{} = entry, args) do
    matches = map_field(entry, ["matches", :matches])

    if is_list(matches) do
      pattern = map_field(entry, ["pattern", :pattern]) || get(args, ["pattern"]) || ""

      entry
      |> delete_map_keys(["matches", :matches])
      |> Map.put("matches", Enum.map(matches, &compact_find_match(&1, pattern, args)))
    else
      entry
    end
  end

  defp compact_find_entry(entry, _args), do: entry

  defp compact_find_match(%{} = match, pattern, args) do
    raw_text =
      match
      |> map_field(["text", :text])
      |> to_string()

    match = maybe_put_before_marker_ref(match, raw_text, args)

    if map_field(match, ["text_truncated", :text_truncated]) == true do
      match
    else
      full_text = compact_find_normalize_text(raw_text)

      text = compact_find_text(full_text, pattern, args)

      match =
        match
        |> delete_map_keys(["text", :text])
        |> Map.put("text", text)

      if String.length(full_text) > String.length(text) do
        Map.put(match, "text_truncated", true)
      else
        match
      end
    end
  end

  defp compact_find_match(match, _pattern, _args), do: match

  defp maybe_put_before_marker_ref(match, text, args) do
    marker = get(args, ["marker"])

    with marker when is_present(marker) <- marker,
         {:ok, offset} <- literal_marker_offset(text, marker, args),
         {:ok, ref} <- canonical_before_marker_ref(map_field(match, ["ref", :ref]), offset) do
      match
      |> Map.put("marker", marker)
      |> Map.put("marker_offset", offset)
      |> Map.put("before_marker_ref", ref)
    else
      marker when is_present(marker) ->
        match
        |> Map.put("marker", marker)
        |> Map.put("marker_found", false)

      _ ->
        match
    end
  end

  defp literal_marker_offset(text, marker, args) do
    case literal_marker_byte_offset(text, marker, find_case_sensitive?(args)) do
      {:ok, byte_index} -> {:ok, byte_index_to_codepoint_index(text, byte_index)}
      :error -> :error
    end
  end

  defp literal_marker_byte_offset(text, marker, true) do
    case :binary.match(text, marker) do
      {byte_index, _length} -> {:ok, byte_index}
      :nomatch -> :error
    end
  end

  defp literal_marker_byte_offset(text, marker, false) do
    with {:ok, regex} <- Regex.compile(Regex.escape(marker), "iu"),
         [{byte_index, _length} | _] <- Regex.run(regex, text, return: :index) do
      {:ok, byte_index}
    else
      _ -> :error
    end
  end

  defp byte_index_to_codepoint_index(text, byte_index) do
    text
    |> binary_part(0, byte_index)
    |> String.codepoints()
    |> length()
  rescue
    ArgumentError -> 0
  end

  defp canonical_before_marker_ref("hwp:" <> _ = ref, offset) when is_integer(offset) do
    with {:ok, decoded} <- Ecrits.Doc.Rhwp.Ref.decode(ref) do
      canonical_hwp_before_marker_ref(decoded, offset)
    else
      _ -> :error
    end
  end

  defp canonical_before_marker_ref(ref, offset) when is_binary(ref) and is_integer(offset) do
    with {:ok, decoded} <- Jason.decode(ref),
         section when is_integer(section) and section >= 0 <-
           int_field(decoded, ["section", :section], nil),
         cell when is_map(cell) <- map_field(decoded, ["cell", :cell]) || %{},
         paragraph when is_integer(paragraph) and paragraph >= 0 <-
           int_field(
             cell,
             ["parentParaIndex", :parentParaIndex],
             int_field(decoded, ["paragraph", :paragraph], nil)
           ) do
      marker_ref = %{"section" => section, "paragraph" => paragraph, "offset" => offset}

      marker_ref =
        case canonical_cell_path(decoded, cell) do
          [_ | _] = cell_path -> Map.put(marker_ref, "cellPath", cell_path)
          _no_cell -> marker_ref
        end

      {:ok, Jason.encode!(marker_ref)}
    else
      _ -> :error
    end
  end

  defp canonical_before_marker_ref(_ref, _offset), do: :error

  defp canonical_hwp_before_marker_ref(
         %{kind: :char, sec: section, para: paragraph, off: base_offset},
         offset
       ) do
    {:ok,
     Jason.encode!(%{
       "section" => section,
       "paragraph" => paragraph,
       "offset" => base_offset + offset
     })}
  end

  defp canonical_hwp_before_marker_ref(
         %{
           kind: :cell_char,
           sec: section,
           para: paragraph,
           control: control,
           cell: cell,
           cell_para: cell_paragraph,
           off: base_offset
         },
         offset
       ) do
    {:ok,
     Jason.encode!(%{
       "section" => section,
       "paragraph" => paragraph,
       "offset" => base_offset + offset,
       "cellPath" => [
         %{
           "controlIndex" => control,
           "cellIndex" => cell,
           "cellParaIndex" => cell_paragraph
         }
       ]
     })}
  end

  defp canonical_hwp_before_marker_ref(_decoded, _offset), do: :error

  defp canonical_cell_path(ref, cell) do
    path =
      map_field(ref, ["cellPath", :cellPath, "cell_path", :cell_path]) ||
        map_field(cell, ["cellPath", :cellPath, "cell_path", :cell_path])

    case path do
      [_ | _] = steps ->
        case steps |> Enum.map(&canonical_cell_path_step/1) |> Enum.reject(&is_nil/1) do
          [] -> nil
          normalized -> normalized
        end

      _ ->
        case canonical_cell_path_step(cell) do
          nil -> nil
          step -> [step]
        end
    end
  end

  defp canonical_cell_path_step(step) when is_map(step) do
    control = int_field(step, ["controlIndex", :controlIndex, "control", :control], nil)
    cell = int_field(step, ["cellIndex", :cellIndex], nil)
    paragraph = int_field(step, ["cellParaIndex", :cellParaIndex], nil)

    if Enum.all?([control, cell, paragraph], &(is_integer(&1) and &1 >= 0)) do
      %{
        "controlIndex" => control,
        "cellIndex" => cell,
        "cellParaIndex" => paragraph
      }
    end
  end

  defp canonical_cell_path_step(_step), do: nil

  defp compact_find_text(text, pattern, args) do
    if String.length(text) <= @find_text_limit do
      text
    else
      index = compact_find_snippet_index(text, pattern, args)
      radius = div(@find_text_limit, 2)
      max_start = max(String.length(text) - @find_text_limit, 0)
      start = min(max(index - radius, 0), max_start)
      finish = min(start + @find_text_limit, String.length(text))
      prefix = if start > 0, do: "...", else: ""
      suffix = if finish < String.length(text), do: "...", else: ""

      prefix <> String.slice(text, start, finish - start) <> suffix
    end
  end

  defp compact_find_snippet_index(_text, pattern, _args) when pattern in [nil, ""], do: 0

  defp compact_find_snippet_index(text, pattern, args) do
    pattern = to_string(pattern)

    if find_regex?(args) do
      with {:ok, regex} <-
             Regex.compile(pattern, if(find_case_sensitive?(args), do: "", else: "i")),
           [{byte_index, _length} | _] <- Regex.run(regex, text, return: :index) do
        byte_index_to_grapheme_index(text, byte_index)
      else
        _ -> literal_find_snippet_index(text, pattern, args)
      end
    else
      literal_find_snippet_index(text, pattern, args)
    end
  end

  defp literal_find_snippet_index(text, pattern, args) do
    haystack = if find_case_sensitive?(args), do: text, else: String.downcase(text)
    needle = if find_case_sensitive?(args), do: pattern, else: String.downcase(pattern)

    case :binary.match(haystack, needle) do
      {byte_index, _length} -> byte_index_to_grapheme_index(text, byte_index)
      :nomatch -> 0
    end
  end

  defp byte_index_to_grapheme_index(text, byte_index) do
    text
    |> binary_part(0, byte_index)
    |> String.length()
  rescue
    ArgumentError -> 0
  end

  defp compact_find_normalize_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp delete_map_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc -> Map.delete(acc, key) end)
  end

  defp find_case_sensitive?(args), do: get(args, ["case_sensitive"]) == true
  defp find_regex?(args), do: get(args, ["regex"]) == true or get(args, ["all"]) == true

  defp find_limit(args) do
    case get(args, ["limit"]) do
      value when is_integer(value) and value > 0 -> min(value, 2000)
      _ -> nil
    end
  end

  defp map_field(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp int_field(map, keys, default) do
    case map_field(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_find_patterns(patterns) do
    patterns =
      Enum.map(patterns, fn
        pattern when is_binary(pattern) -> {:ok, pattern}
        %{} = entry -> find_pattern(entry, false)
        _other -> {:error, {:invalid_params, "patterns must be strings or pattern objects"}}
      end)

    case Enum.find(patterns, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(patterns, fn {:ok, pattern} -> pattern end)}
    end
  end

  # --- dispatch helpers ----------------------------------------------------

  # Run a tool against the browser WASM model that holds `args["document"]`.
  # There is one destination; `opts` carries the `:browser` closure. Until
  # 2026-07-29 this also dispatched to a server Editor and could be told to
  # force one (`authority: :committed_server`) — that arm could never answer.
  defp route_doc(ctx, args, opts) do
    with {:ok, document} <- require_string(args, "document") do
      case canonical_document(ctx, document) do
        {:ok, document} ->
          case route(ctx, document) do
            {:browser, lv} ->
              Keyword.fetch!(opts, :browser).(lv)

            {:error, :not_found} ->
              {:error, error_json({:document_not_found, document, known_documents(ctx)})}
          end

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  # The `document` arg may arrive as something other than the canonical id: the
  # picks block's stamped id, a workspace-relative path, or "active". Resolve
  # all of those here so EVERY doc tool accepts what an agent reasonably passes
  # (#32 — observed live: "local-* id not accepted. Trying given document
  # name." both failed before this resolver existed).
  defp canonical_document(ctx, document) do
    cond do
      document in ["active", "current"] ->
        case Map.get(ctx, :active_doc) do
          id when is_present(id) -> {:ok, id}
          _ -> {:error, {:document_not_found, document, known_documents(ctx)}}
        end

      known_document_id?(ctx, document) ->
        {:ok, document}

      true ->
        case match_document_by_path(ctx, document) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, {:document_not_found, document, known_documents(ctx)}}
        end
    end
  end

  defp known_document_id?(ctx, document) do
    active_office_document_id?(ctx, document) or session_viewer(ctx, document) != nil
  end

  defp active_office_document_id?(ctx, document) do
    case Map.get(ctx, :document_path) do
      path when is_binary(path) ->
        Map.get(ctx, :active_doc) == document and path_kind(path) in ["docx", "pptx", "xlsx"]

      _ ->
        false
    end
  end

  # A path-ish `document` arg resolves by DERIVING its id — ids are a pure
  # function of (path, kind) — and then asking whether a viewer holds it. The
  # old scan of the server registry could match a basename against several open
  # documents; deriving cannot be ambiguous, but it also cannot resolve a bare
  # basename, so the agent must name a path the workspace root can expand.
  defp match_document_by_path(ctx, document) do
    with {:ok, path} <- confine_path(ctx, document),
         kind when not is_nil(kind) <- kind_from_path(path),
         document_id = DocumentId.for_path(path, kind),
         true <- is_pid(session_viewer(ctx, document_id)) do
      {:ok, document_id}
    else
      _ -> :error
    end
  end

  # The documents this caller can actually address: the ones a viewer in its
  # workspace holds. The old answer enumerated the server registry, which could
  # hold none, so every miss advertised an empty catalog.
  defp known_documents(ctx) do
    case Map.get(ctx, :session_path) do
      path when is_present(path) ->
        path |> Session.viewed_document_ids() |> Enum.map(&%{"document" => &1})

      _ ->
        []
    end
  end

  # Design invariant 4, with one arm left: the per-workspace
  # `Ecrits.Workspace.Session` owns the `viewers` map, and a doc with a live
  # human viewer routes `{:browser, lv}` (its WASM model). Nothing else holds a
  # document, so anything else is a miss.
  defp route(ctx, document) do
    case session_viewer(ctx, document) do
      lv when is_pid(lv) -> {:browser, lv}
      nil -> {:error, :not_found}
    end
  end

  defp session_viewer(ctx, document) do
    case Map.get(ctx, :session_path) do
      path when is_present(path) -> Session.viewer(path, document)
      _ -> nil
    end
  end

  # For a browser-backed doc, deliver a structural edit op to the owning LiveView
  # and wait for the WASM apply result (design §6.2).
  # The op is normalised first (validated verb, string keys) so the browser hook
  # always receives a well-formed `{"op": "<verb>", ...}` regardless of how the
  # agent keyed the map.
  defp browser_write(lv, args, op) do
    with {:ok, normalized} <- normalize_browser_op(op) do
      do_browser_write(lv, args, normalized)
    else
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # Re-key the validated op back to JSON string keys (Op.normalize atomises it).
  # An inline `insert_picture` is run through the picture producer first, which
  # reads `src` and attaches the image bytes as `image_base64` (the browser can't
  # read the server filesystem). Gated to the inline form, so the office slide
  # form (`page` set) is left untouched.
  # The image producer (`Doc.Rhwp.Image.for_browser/1`) went with the engine deps
  # on 2026-07-26. Non-picture ops were always a passthrough, so they keep
  # working; an inline picture needs its bytes attached and has no producer, so
  # refuse explicitly rather than sending the browser an op it cannot satisfy.
  # See docs/plans/2026-07-26-doclang-engine-migration.md.
  defp normalize_browser_op(op) do
    with {:ok, atom_op} <- Ecrits.Doc.Op.normalize(op) do
      if Map.get(atom_op, :op) == :insert_picture and Map.get(atom_op, :src) do
        {:error,
         error_json(
           {:unsupported_op,
            "inline insert_picture needs the native image producer, removed with :ehwp"}
         )}
      else
        {:ok, Map.new(atom_op, fn {k, v} -> {to_string(k), v} end)}
      end
    end
  end

  defp do_browser_write(lv, args, op) do
    case browser_call(lv, args, :edit, %{op: op}) do
      {:ok, %{} = applied} ->
        # Pass the editor's per-op EVIDENCE through (replaced, inserted,
        # rows_after/cols_after, ...) — a bare {ok:true} is how an agent once
        # claimed "10 rows added" when 1 was: with rows_after in the reply the
        # model sees the structural effect and self-corrects.
        {:ok, Map.merge(browser_write_evidence(applied), %{"ok" => true})}

      {:error, _reason} = error ->
        error
    end
  end

  # Scalar result fields from the browser editor's reply, minus plumbing keys.
  @browser_reply_plumbing ~w(ok request_id ref document_id)
  defp browser_write_evidence(%{} = applied) do
    applied
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.filter(fn {k, v} ->
      k not in @browser_reply_plumbing and (is_number(v) or is_binary(v) or is_boolean(v))
    end)
  end

  # Batch doc.edit for a browser-backed doc: normalise EACH op (per-op, like the
  # single path) then hand the whole `ops` array to the WASM hook's
  # applyAgentEditBatch in ONE round-trip. A normalisation failure for one op is
  # recorded as that op's result (it is NOT sent to the browser) so the rest still
  # apply. The hook applies body index-shifting ops in reverse document order and
  # cell ops order-independently, then finishes (re-renders) once.
  defp browser_write_batch(lv, args, ops) do
    # Split the ops into the ones that normalise cleanly (sent to the browser) and
    # the ones that don't (recorded as local failures), preserving order metadata
    # so the merged result keeps every op accounted for.
    {ok_ops, bad_results} =
      ops
      |> Enum.map(fn op ->
        case normalize_browser_op(op) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, reason} -> {:error, %{"ref" => op_ref(op), "error" => error_json(reason)}}
        end
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    normalized_ops = Enum.map(ok_ops, fn {:ok, op} -> op end)
    validation_failures = Enum.map(bad_results, fn {:error, res} -> res end)

    if normalized_ops == [] do
      batch_reply(
        batch_result(
          validation_failures,
          0,
          length(validation_failures),
          get(args, ["verbose"]) == true
        )
      )
    else
      case browser_call(lv, args, :edit, %{ops: normalized_ops}) do
        {:ok, %{} = applied} ->
          batch_reply(
            merge_browser_batch(applied, validation_failures, get(args, ["verbose"]) == true)
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Merge the browser's batch result with any locally-rejected (un-normalisable)
  # ops so `failed`/`results` account for EVERY op the agent submitted.
  defp merge_browser_batch(applied, validation_failures, verbose) do
    results =
      (Map.get(applied, "results") || Map.get(applied, :results) || []) ++ validation_failures

    applied_n = Map.get(applied, "applied") || Map.get(applied, :applied) || 0

    failed_n =
      (Map.get(applied, "failed") || Map.get(applied, :failed) || 0) + length(validation_failures)

    batch_result(results, applied_n, failed_n, verbose)
  end

  # doc.set for a browser-backed doc: deliver the property set to the viewer's
  # authoritative WASM model. The ref (doc.find's
  # positional ref, incl. cell address) is parsed browser-side by the SAME parseRef
  # the edit verbs use, so there is no ref-format round-trip mismatch with the
  # server `hwp:` grammar — the reason a server-routed set rejected find's ref.
  defp browser_set(lv, args, ref, props) do
    case browser_call(lv, args, :set, %{ref: ref, props: props}) do
      {:ok, %{} = applied} ->
        {:ok, %{"ok" => true} |> maybe_put("invalidated", Map.get(applied, "invalidated"))}

      {:error, _reason} = error ->
        error
    end
  end

  # Batch doc.set for a browser-backed doc: hand the `sets` array to the hook's
  # applyAgentSetBatch in ONE round-trip (each set addresses a fixed cell/run, so
  # order is irrelevant). The hook applies all of them best-effort and finishes
  # (re-renders) once, returning {applied, failed, results}.
  defp browser_set_batch(lv, args, sets) do
    case browser_call(lv, args, :set, %{sets: sets}) do
      {:ok, %{} = applied} ->
        batch_reply(merge_browser_batch(applied, [], get(args, ["verbose"]) == true))

      {:error, _reason} = error ->
        error
    end
  end

  # doc.get inspects the browser WASM model. Only the OFFICE hook exposes a
  # `get` verb; the HWP one never did, and its answer used to come from the
  # headless server copy — so a viewed HWP now has no doc.get at all.
  defp office_browser_get(ctx, args, browser_payload) do
    with {:ok, document} <- require_string(args, "document") do
      case canonical_document(ctx, document) do
        {:ok, document} ->
          case route(ctx, document) do
            {:browser, lv} ->
              if office_document?(ctx, document) do
                browser_get(lv, args, browser_payload)
              else
                {:error,
                 error_json(
                   {:not_supported,
                    "doc.get reads the office browser IR; the HWP viewer exposes no get verb"}
                 )}
              end

            {:error, :not_found} ->
              {:error, error_json({:document_not_found, document, known_documents(ctx)})}
          end

        {:error, reason} ->
          {:error, error_json(reason)}
      end
    end
  end

  defp office_document?(ctx, document) do
    Map.get(ctx, :active_doc) == document and
      session_viewer(ctx, document) != nil and
      path_kind(Map.get(ctx, :document_path)) in ["docx", "pptx", "xlsx"]
  end

  defp browser_get(lv, args, payload) do
    case browser_call(lv, args, :get, payload) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  # doc.save for an open (browser) doc: round-trip the viewer for its current
  # edited bytes, then write them to `path`.
  defp save_browser(lv, args, path) do
    case browser_call(lv, args, :save, %{}) do
      {:ok, %{} = res} ->
        with {:ok, bytes} <- ByteSpool.decode(res),
             :ok <- File.write(path, bytes) do
          broadcast_file_written(path)
          {:ok, %{"ok" => true}}
        else
          {:error, :missing_bytes} ->
            {:error, error_json({:save_failed, "viewer returned no bytes"})}

          {:error, :invalid_base64} ->
            {:error, error_json({:save_failed, "viewer returned invalid base64"})}

          {:error, reason} ->
            {:error, error_json(reason)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Announce a successful agent file-write so any workspace LiveView whose root
  # contains `path` refreshes its file tree. Best-effort and fire-and-forget:
  # broadcast never raises in practice, but we guard so a PubSub hiccup can never
  # fail the write the agent just completed.
  defp broadcast_file_written(path) when is_present(path) do
    abs_path = Path.expand(path)

    _ =
      Phoenix.PubSub.broadcast(
        @workspace_files_pubsub,
        @workspace_files_topic,
        {:workspace_file_written, abs_path}
      )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp broadcast_file_written(_path), do: :ok

  # Synchronous request/reply against the viewing LiveView. The LiveView's
  # `{:doc_browser_request, ...}` handler pushes the op to the canvas hook,
  # the hook applies it to the engine model and replies, and the LiveView relays the
  # result back to us as `{:doc_browser_reply, ref, result}`. Runs in the agent's
  # MCP process (NOT the LiveView), so we use a tagged send + selective receive.
  defp browser_call(lv, _args, verb, payload) when is_pid(lv) do
    case BrowserBridge.call(lv, verb, payload) do
      {:ok, result} -> {:ok, stringify(result)}
      {:error, reason} -> {:error, error_json(reason)}
    end
  end

  # The ref carried on an op (for the per-op result label); nil when absent.
  defp op_ref(op) when is_map(op), do: get(op, ["ref"])
  defp op_ref(_op), do: nil

  # The shared best-effort batch result shape (browser + server use it):
  # `applied`/`failed` counts plus per-op results.
  defp batch_result(results, applied, failed, verbose) do
    failed_results = Enum.filter(results, &Map.has_key?(&1, "error"))

    %{"ok" => failed == 0, "applied" => applied, "failed" => failed}
    |> maybe_put("results", if(verbose, do: results))
    |> maybe_put("failed_results", if(failed_results == [], do: nil, else: failed_results))
  end

  defp batch_reply(%{"failed" => failed} = result) when failed > 0, do: {:error, result}
  defp batch_reply(result), do: {:ok, result}

  # Current document only. The active document is per-CALLER (design invariant 3 /
  # Phase 3): the agent's OWN active doc, read from the AgentLive
  # (`ctx.active_doc`) — there is no global active anymore. `WorkspaceLive` follows
  # the user's open doc onto the foreground agent live (`update_options`), so
  # `doc.context` returns the doc this agent is bound to.
  #
  # We resolve ONLY the explicitly-set active doc — no "first" or "sole doc"
  # guessing and no full `documents` catalog in the response. If the workspace
  # still knows a selected `document_path`, `current_document.document` uses that
  # path handle so the agent can explicitly open/read the viewed document through
  # MCP, not through prompt text.
  defp context_json(ctx) do
    %{"current_document" => current_document_json(ctx, current_document_entry(ctx))}
  end

  defp current_document_entry(ctx) do
    case Map.get(ctx, :active_doc) do
      active_id when is_present(active_id) -> active_browser_document_entry(ctx, active_id)
      _ -> nil
    end
  end

  defp active_browser_document_entry(ctx, active_id) do
    with path when is_present(path) <- Map.get(ctx, :document_path),
         kind when kind in ["docx", "pptx", "xlsx"] <- path_kind(path) do
      %{id: active_id, path: path, kind: String.to_atom(kind), backing: :browser}
    else
      _ -> nil
    end
  end

  # Already-structured error maps (e.g. `enforce_ownership` -> forbidden) pass
  # through unchanged so the uniform `else error_json/1` wrapping never re-wraps a
  # map the MCP server already surfaces as structured JSON content.
  defp error_json(%{} = structured), do: structured

  defp error_json({:not_supported, reason}),
    do: %{"not_supported" => true, "reason" => to_string(reason)}

  defp error_json(:not_found), do: %{"error" => "not_found"}

  defp error_json({:unsupported_kind, kind}),
    do: %{"error" => "unsupported_kind", "kind" => to_string(kind)}

  defp error_json({:template_not_found, from}),
    do: %{"error" => "template_not_found", "from" => from}

  defp error_json({:clone_failed, reason}),
    do: %{"error" => "clone_failed", "reason" => inspect(reason)}

  defp error_json({:create_failed, reason}),
    do: %{"error" => "create_failed", "reason" => inspect(reason)}

  defp error_json({:create_unsupported, backend}),
    do: %{"error" => "create_unsupported", "backend" => inspect(backend)}

  defp error_json({:invalid_params, message}),
    do: %{"error" => "invalid_params", "message" => to_string(message)}

  defp error_json({:invalid_op, message}),
    do: %{"error" => "invalid_op", "message" => to_string(message)}

  defp error_json(:read_only),
    do: %{
      "error" => "read_only",
      "message" => "read-only session — switch access to Ask/Full workspace to edit/save"
    }

  defp error_json({:outside_workspace, root}),
    do: %{
      "error" => "outside_workspace",
      "message" => "path must stay within the workspace root: #{root}",
      "workspace_root" => root
    }

  defp error_json({:no_viewer, path}),
    do: %{
      "error" => "no_viewer",
      "path" => path,
      "message" =>
        "the document engine runs in the BROWSER, so a document exists only while " <>
          "a workspace tab holds it. Open #{Path.basename(path)} in the workspace and retry."
    }

  defp error_json({:document_not_found, document, open_documents}) do
    %{
      "error" => "document_not_found",
      "document" => document,
      "message" =>
        "unknown document id/path. Use one of open_documents' `document` ids, " <>
          "or a workspace-relative path to a document a tab currently holds.",
      "open_documents" => open_documents
    }
  end

  defp error_json(reason) when is_atom(reason), do: %{"error" => to_string(reason)}
  defp error_json(reason), do: %{"error" => inspect(reason)}

  defp entry_json(%{} = entry) do
    %{
      "document" => entry.id,
      "name" => document_name(entry.path),
      "kind" => to_string(entry.kind),
      "path" => entry.path,
      "backing" => to_string(entry.backing)
    }
  end

  defp current_document_json(_ctx, %{} = active) do
    active
    |> entry_json()
    |> Map.put("active", true)
  end

  defp current_document_json(ctx, nil) do
    case Map.get(ctx, :document_path) do
      path when is_present(path) ->
        %{
          "document" => path,
          "name" => document_name(path),
          "kind" => path_kind(path),
          "path" => path,
          "backing" => nil,
          "active" => true
        }

      _ ->
        nil
    end
  end

  defp document_name(path) when is_present(path), do: Path.basename(path)
  defp document_name(_path), do: nil

  defp path_kind(path) when is_binary(path) do
    case Path.extname(path) do
      "." <> ext when ext != "" -> String.downcase(ext)
      _ -> nil
    end
  end

  # Access-control guards (security review #1): the doc.* tools run in-process and
  # bypass the agent CLI sandbox, so they must honour the workspace access setting
  # themselves. `:read_only` is set from the agent's sandbox == "read-only"
  # (workspace_live.ex access controls); `:session_path` is the workspace root.

  # Refuse mutating tools in a read-only session.
  defp enforce_writable(ctx) do
    if Map.get(ctx, :read_only, false), do: {:error, :read_only}, else: :ok
  end

  # Confine a caller-supplied path to the workspace root so a prompt-injected path
  # can't open/create/save outside the workspace. A bare pool-only context (no
  # `:session_path`) is the legacy unisolated path and is left unconstrained.
  #
  # The workspace root is the agent's CWD (acp_stream working_dir == workspace_root
  # == session_path), so caller paths are workspace-RELATIVE: expand them AGAINST
  # the root (`Path.expand/2`). A relative path resolves under the root; an absolute
  # path is normalised (the base is ignored) and must already be within the root.
  # Either way `..`-escapes are normalised away before the prefix check, so a
  # lexical `<root>/../x` that escapes the root is rejected.
  defp confine_path(ctx, path) do
    case Map.get(ctx, :session_path) do
      root when is_present(root) ->
        root_expanded = Path.expand(root)
        expanded = Path.expand(path, root_expanded)
        canonical_root = DocMount.canonical_root(root_expanded)
        canonical_expanded = canonical_path_for_compare(expanded)

        if canonical_expanded == canonical_root or
             String.starts_with?(canonical_expanded, canonical_root <> "/") do
          {:ok, expanded}
        else
          {:error, {:outside_workspace, canonical_root}}
        end

      _ ->
        {:ok, path}
    end
  end

  # The workspace root for the doc VFS open-set (`Ecrits.Fuse.OpenDocs` /
  # `DocMount` key). `ctx.session_path` is the agent's workspace root.
  defp vfs_root(ctx) do
    case Map.get(ctx, :session_path) do
      root when is_present(root) -> {:ok, DocMount.canonical_root(root)}
      _ -> {:error, {:invalid_params, "no workspace root in this context"}}
    end
  end

  defp canonical_path_for_compare(path) when is_binary(path) do
    canonical_file_path(path)
  end

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end

  defp get(args, keys), do: get_in_args(args, keys)

  defp get_in_args(args, [key]) do
    Map.get(args, key, Map.get(args, to_string(key)))
  end

  defp take_opts(args, keys) do
    keys
    |> Enum.flat_map(fn key ->
      case get(args, [key]) do
        nil -> []
        value -> [{String.to_atom(key), value}]
      end
    end)
  end

  defp require_string(args, key) do
    case get(args, [key]) do
      value when is_present(value) -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (non-empty string) is required"}}
    end
  end

  # doc.find: in discovery mode (`all`/`regex`) an empty/missing pattern is valid
  # (matches everything, including empty cells); a literal search still requires
  # a non-empty pattern.
  defp find_pattern(args, true), do: {:ok, get_string_or_empty(args, "pattern")}
  defp find_pattern(args, false), do: require_string(args, "pattern")

  defp get_string_or_empty(args, key) do
    case get(args, [key]) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp require_map(args, key) do
    case get(args, [key]) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:invalid_params, "#{key} (object) is required"}}
    end
  end

  defp normalize_kind(nil, path), do: kind_from_path(path) || :hwp
  defp normalize_kind("", path), do: kind_from_path(path) || :hwp
  defp normalize_kind(kind, _path), do: normalize_kind(kind)

  defp normalize_kind("hwpx"), do: :hwpx
  defp normalize_kind("hwp"), do: :hwp
  defp normalize_kind("docx"), do: :docx
  defp normalize_kind("pptx"), do: :pptx
  defp normalize_kind("xlsx"), do: :xlsx
  defp normalize_kind(:hwpx), do: :hwpx
  defp normalize_kind(:docx), do: :docx
  defp normalize_kind(:pptx), do: :pptx
  defp normalize_kind(:xlsx), do: :xlsx
  defp normalize_kind(_other), do: :hwp

  defp kind_from_path(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      ".hwp" -> :hwp
      ".hwpx" -> :hwpx
      ".docx" -> :docx
      ".pptx" -> :pptx
      ".xlsx" -> :xlsx
      _ -> nil
    end
  end

  defp kind_from_path(_path), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
