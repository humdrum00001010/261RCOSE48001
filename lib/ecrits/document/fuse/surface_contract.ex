defmodule Ecrits.Fuse.SurfaceContract do
  @moduledoc """
  The editing contract for the doc VFS mount, served as a FILE inside it.

  This is the agent's manual: block vocabulary, OTSL table tokens, the identity
  rule, the commit/rename protocol, EINVAL recovery, and the one native picture
  fallback. It used to ride back on `doc.open_doc`'s result payload; the mount's
  listing is now derived (workspace scan ∩ live viewers), so nothing has to be
  told anything and there is no tool call left to attach it to.

  It stays DATA rather than moving into `Ecrits.Prompt`, for the two reasons
  `tools.ex` and `prompt_test.exs` each recorded: the payload vocabulary is
  discovered by the client rather than injected into the ACP prompt, and
  `prompt_test.exs` pins the MCP copy under 300 bytes precisely to stop this
  contract landing there.

  ## Why `CONTRACT.json`, and why it cannot collide

  A bare `ls` is the discovery path the whole move exists to create, and `ls`
  hides dotfiles — so no leading dot. Uppercase sorts ahead of the lowercase and
  Hangul document names beside it, so it is the first line of the listing rather
  than the last. `.json` says what to do with it.

  Collision is impossible by construction, not by convention: every other entry
  this mount can produce comes from `Ecrits.Doc.Projection.projected_name/1` and
  therefore ends in `.doclang.xml`. A workspace file literally named
  `CONTRACT.json` is not a projectable kind and can never be listed, and one
  named `CONTRACT.json.hwp` would appear as `CONTRACT.json.hwp.doclang.xml`.

  The bytes are static, so `getattr` answers a real size with no projection and
  no browser round trip — unlike the documents, whose size-0 listing is the known
  defect recorded on `Ecrits.Fuse.DocFs.readdir/0`.
  """

  @filename "CONTRACT.json"

  @doc "The mount entry name this contract is served under."
  @spec filename() :: String.t()
  def filename, do: @filename

  @spec contract_name?(String.t()) :: boolean()
  def contract_name?(name), do: name == @filename

  @doc "The exact bytes `read` serves and `getattr` sizes."
  @spec json() :: binary()
  def json, do: Jason.encode!(contract(), pretty: true)

  @spec size() :: non_neg_integer()
  def size, do: byte_size(json())

  @doc "The contract as data, for tests and for callers that want the map."
  @spec contract() :: map()
  def contract do
    %{
      "version" => 4,
      "kind" => "doclang_xml_projection",
      "addressing" => "block_tree_position",
      "discovery" => discovery_contract(),
      "format" => %{
        "encoding" => "one_doclang_xml_document",
        "root_element" => "doclang",
        "schema_version" => Doclang.version(),
        "identity" => %{
          "mode" => "tree_position",
          "refs_in_buffer" => false,
          "rule" =>
            "the_engine_ref_is_recovered_from_the_live_document_at_the_aligned_block_position_never_write_one"
        },
        "completeness" =>
          "a_buffer_commits_only_once_the_closing_doclang_tag_is_present_partial_writes_are_staged",
        "whitespace" => %{
          "inside_a_block" => "character_data_is_content_and_is_preserved_verbatim",
          "between_blocks" => "indentation_is_insignificant_and_may_be_added_or_removed"
        },
        "structure" => ["doclang", "blocks", "inlines"],
        "commit" => commit_contract()
      },
      "preserve" => [
        "element_name",
        "unknown_elements_and_attributes",
        "custom_props",
        "document_order"
      ],
      "blocks" => %{
        "text" => %{
          "element" => "<text>…</text>",
          "edit" => "replace_the_character_data_in_place"
        },
        "heading" => %{
          "element" => "<heading level=\"1\">…</heading>",
          "edit" => "replace_the_character_data_in_place"
        },
        "table" => %{
          "element" => "<table>otsl_token_stream</table>",
          "tokens" => %{
            "ched" => "header_cell_anchor",
            "fcel" => "filled_cell_anchor",
            "ecel" => "empty_cell_anchor",
            "lcel" => "position_covered_by_a_column_span",
            "ucel" => "position_covered_by_a_row_span",
            "xcel" => "position_covered_by_both",
            "nl" => "row_terminator"
          },
          "cell_content" => "the_blocks_that_follow_an_anchor_token_until_the_next_token",
          "edit" => "replace_the_character_data_of_the_blocks_inside_a_cell_anchor",
          "insert" => %{
            "mode" => "insert_a_whole_table_element",
            "required" => ["one_anchor_token_per_cell", "one_nl_per_row"],
            "preserve_existing_blocks" => true
          }
        },
        "list" => %{
          "element" => "<list class=\"ordered|unordered\"><ldiv/>…</list>",
          "items" => "an_ldiv_delimits_an_item_its_blocks_follow_as_siblings"
        },
        "picture" => %{
          "element" => "<picture><src uri=\"…\"/></picture>",
          "insert" => true,
          "delete" => true,
          "src_on_insert" => %{
            "required" => "base64_data_uri",
            "example" => "data:image/png;base64,iVBORw0KGgo…",
            "refused" => %{
              "filesystem_path" => "the engine runs in the browser and has no filesystem",
              "http_url" => "would resolve differently per iframe origin and CSP",
              "bin_name" =>
                "a bin<NNNN>.<ext> in this projection is a BinData LABEL inside the document, not a readable address"
            }
          },
          "src_on_read" =>
            "existing pictures project their engine BinData label; it identifies the image, it cannot be fetched"
        },
        "custom" => %{
          "element" => "<custom><hwp_prop name=\"…\" value=\"…\"/></custom>",
          "meaning" => "preserved_engine_properties_mode_preserve",
          "edit" => "changing_a_value_becomes_a_native_property_write",
          "reserved" => ["ns"]
        }
      },
      "operations" => %{
        "set_text" => %{
          "target_blocks" => ["text", "heading", "formula", "table_cell_blocks"],
          "field" => "character_data",
          "mode" => "in_place",
          "select" => "element_name_and_current_text",
          "reuse_blank_blocks" => true
        },
        "set_property" => %{
          "target" => "block_attribute_or_custom_prop",
          "mode" => "in_place",
          "action" => "changed_value_becomes_a_native_property_write"
        },
        "insert_table" => %{
          "container" => "the_doclang_root_or_a_container_block",
          "at" => "the_position_between_existing_sibling_blocks",
          "action" => "insert_one_new_table_element",
          "commit_constraint" =>
            "successful_table_inserting_rename_is_final_projection_write_for_turn",
          "precommit_requirement" => "unmapped_source_facts_empty",
          "replace_container" => false
        }
      },
      "unsupported" => %{
        "inline_formatting_only_change" => "rejected_einval_unsupported_edit",
        "reorder_or_delete_a_non_picture_block" => "rejected_einval_structural_change"
      },
      "native_fallbacks" => %{
        "insert_picture" => %{
          "tool" => "doc.edit",
          "reason" => "unrepresentable",
          "supported_placement" => "picture_at_exact_existing_marker",
          "derive_from" => "current_engine_ref_after_primary_commit",
          "resolve_ref" => %{
            "tool" => "doc.find",
            "when" => "after_primary_commit",
            "arguments" => %{
              # The document id is no longer discoverable — the tool that used to
              # hand it out is gone — so both surviving tools take the literal
              # "current" and the server resolves it to the bound document.
              "document" => "current",
              "type" => "paragraph",
              "pattern" => %{"from" => "copy_exact_committed_target_paragraph_text"},
              "marker" => %{
                "from" => "existing_literal_immediately_after_picture",
                "must_already_exist" => true,
                "create_placeholder" => false
              },
              "case_sensitive" => true,
              "limit" => 1,
              "occurrence" => %{
                "optional" => true,
                "use" => "1_based_document_order_index_when_the_exact_paragraph_text_repeats"
              }
            },
            "select" => "unique_exact_text_match_containing_existing_marker",
            "use" => "match.before_marker_ref_verbatim",
            "manual_ref_derivation" => false
          },
          "op" => %{
            "op" => "insert_picture",
            "src" => "absolute_file_path",
            "ref" => "json_string",
            "ref_value" => %{
              "section" => "non_negative_integer",
              "paragraph" => "non_negative_integer",
              "offset" => "non_negative_character_index",
              "cellPath" => "optional_nonempty_canonical_cell_path"
            }
          },
          "derive_ref_from_doc_find_match" => true,
          "fallback" => %{
            "attempted" => "vfs",
            "reason" => "unrepresentable",
            "detail" => "describe_the_exact_existing_marker_picture_placement",
            "document" => "current",
            "mounted_at" => "the_absolute_path_of_the_projection_file_you_committed"
          }
        }
      }
    }
  end

  # What `available` used to answer, restated as the fact the agent can now check
  # itself. `available` was `is_binary(mounted_at)` on a tool result; reading THIS
  # file already proves the mount is up, so the field could only ever say true.
  # The real question left is which documents are servable, and that is one `ls`.
  defp discovery_contract do
    %{
      "listing" => "every_sibling_entry_ending_in_.doclang.xml_is_one_editable_document",
      "source_of_truth" =>
        "the_listing_is_derived_from_the_workspace_scan_intersected_with_the_documents_a_live_editor_tab_holds",
      "empty_listing" => %{
        "meaning" => "no_editor_tab_holds_a_document_so_none_can_be_served",
        "recover" =>
          "ask_the_user_to_open_the_document_in_the_editor_there_is_no_tool_that_opens_one"
      },
      "no_tool_required" => true
    }
  end

  # `target_path`/`temp_path` are TEMPLATES, not paths: this file is mount-level,
  # so it cannot name one document. Both are siblings of this file.
  defp commit_contract do
    %{
      "mode" => "same_directory_temp_then_rename",
      "target_path" => "<document>.doclang.xml",
      "temp_path" => "<document>.doclang.xml.tmp",
      "paths_are_relative_to" => "the_directory_this_contract_file_is_in",
      "temp_scope" => "mounted_projection_directory_only",
      "external_temp" => false,
      "rename" => "same_filesystem_atomic",
      "unsupported_structural_change" => %{"committed" => false, "errno" => "EINVAL"},
      "on_einval" => %{
        "meaning" => "candidate_rejected_no_durable_commit",
        "likely_causes" => [
          "added_removed_or_reordered_a_block_the_diff_cannot_align",
          "changed_only_inline_markup_which_has_no_write_back_route",
          "unsupported_block_or_structure_change",
          "stale_full_file_base"
        ],
        "recover" =>
          "reread the canonical projection, diff pristine to candidate, restore every block the candidate added, removed or reordered and any inline-only markup change, then retry one corrected candidate; never restage identical rejected bytes"
      },
      "on_enoent" => %{
        # There is no "register the projection" call to retry any more; the name
        # is absent exactly when no live viewer holds that document.
        "likely_cause" => "no_live_editor_tab_holds_that_document_so_the_mount_cannot_serve_it",
        "recover" => "relist_this_directory_and_use_a_name_it_actually_shows"
      },
      "on_projection_temp_exists" => %{
        "likely_cause" => "temp_reservation_left_by_an_interrupted_writer",
        "recover" =>
          "write_a_differently_named_sibling_temp_in_this_directory_and_rename_that_over_the_target"
      }
    }
  end
end
