defmodule Ecrits.Fuse.SurfaceContractTest do
  @moduledoc """
  The payload assertions that used to sit on `doc.open_doc`'s `"surface"` key.

  The tool is gone; the contract is now a file in the mount, so the vocabulary it
  guarantees is pinned here instead. `Ecrits.Fuse.DocFsTest` covers serving it.
  """
  use ExUnit.Case, async: true

  alias Ecrits.Fuse.SurfaceContract

  test "the contract is one JSON document with the DocLang projection vocabulary" do
    assert {:ok, contract} = Jason.decode(SurfaceContract.json())

    assert %{
             "version" => 4,
             "kind" => "doclang_xml_projection",
             "addressing" => "block_tree_position",
             "format" => %{
               "encoding" => "one_doclang_xml_document",
               "root_element" => "doclang",
               "schema_version" => "0.6",
               "identity" => %{
                 "mode" => "tree_position",
                 "refs_in_buffer" => false,
                 "rule" =>
                   "the_engine_ref_is_recovered_from_the_live_document_at_the_aligned_block_position_never_write_one"
               },
               "completeness" =>
                 "a_buffer_commits_only_once_the_closing_doclang_tag_is_present_partial_writes_are_staged",
               "structure" => ["doclang", "blocks", "inlines"]
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
               "table" => %{
                 "tokens" => %{"ched" => "header_cell_anchor", "nl" => "row_terminator"},
                 "cell_content" => "the_blocks_that_follow_an_anchor_token_until_the_next_token",
                 "insert" => %{
                   "mode" => "insert_a_whole_table_element",
                   "required" => ["one_anchor_token_per_cell", "one_nl_per_row"],
                   "preserve_existing_blocks" => true
                 }
               },
               # Pictures ARE insertable — but only with the bytes inline as a
               # base64 data URI, because the browser engine has no filesystem.
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
                 "meaning" => "preserved_engine_properties_mode_preserve",
                 "reserved" => ["ns"]
               }
             },
             "unsupported" => %{
               "inline_formatting_only_change" => "rejected_einval_unsupported_edit",
               "reorder_or_delete_a_non_picture_block" => "rejected_einval_structural_change"
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
             }
           } = contract
  end

  test "the commit protocol is a template, since the file is mount-level" do
    assert {:ok, contract} = Jason.decode(SurfaceContract.json())

    assert %{
             "mode" => "same_directory_temp_then_rename",
             "target_path" => "<document>.doclang.xml",
             "temp_path" => "<document>.doclang.xml.tmp",
             "paths_are_relative_to" => "the_directory_this_contract_file_is_in",
             "temp_scope" => "mounted_projection_directory_only",
             "external_temp" => false,
             "rename" => "same_filesystem_atomic",
             "unsupported_structural_change" => %{"committed" => false, "errno" => "EINVAL"}
           } = get_in(contract, ["format", "commit"])

    assert %{
             "meaning" => "candidate_rejected_no_durable_commit",
             "likely_causes" => likely_causes,
             "recover" => recover
           } = get_in(contract, ["format", "commit", "on_einval"])

    assert "added_removed_or_reordered_a_block_the_diff_cannot_align" in likely_causes
    assert "changed_only_inline_markup_which_has_no_write_back_route" in likely_causes
    assert "stale_full_file_base" in likely_causes
    assert recover =~ "restore every block the candidate added, removed or reordered"
    assert recover =~ "retry one corrected candidate"
  end

  test "no recovery advice names a tool that no longer exists" do
    json = SurfaceContract.json()

    refute json =~ "open_doc"
    refute json =~ "close_doc"

    assert {:ok, contract} = Jason.decode(json)

    # ENOENT means no live viewer holds that document. There is nothing left to
    # call that would make the name appear, so the only advice is to relist.
    assert get_in(contract, ["format", "commit", "on_enoent", "recover"]) =~ "relist"

    assert get_in(contract, ["discovery", "empty_listing", "meaning"]) =~ "no_editor_tab"
    assert get_in(contract, ["discovery", "no_tool_required"]) == true

    assert get_in(contract, ["discovery", "listing"]) =~ ".doclang.xml"
  end

  test "the one native fallback still routes through doc.find and doc.edit" do
    assert {:ok, contract} = Jason.decode(SurfaceContract.json())
    picture = get_in(contract, ["native_fallbacks", "insert_picture"])

    assert %{
             "tool" => "doc.edit",
             "reason" => "unrepresentable",
             "supported_placement" => "picture_at_exact_existing_marker",
             "derive_from" => "current_engine_ref_after_primary_commit",
             "derive_ref_from_doc_find_match" => true,
             "resolve_ref" => %{
               "tool" => "doc.find",
               "when" => "after_primary_commit",
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
             }
           } = picture

    # A document id was discoverable exactly one way — the deleted tool's result
    # — so both surviving tools take the keyword and the server resolves it.
    assert get_in(picture, ["resolve_ref", "arguments", "document"]) == "current"
    assert get_in(picture, ["fallback", "document"]) == "current"

    assert get_in(picture, ["fallback", "mounted_at"]) ==
             "the_absolute_path_of_the_projection_file_you_committed"
  end
end
