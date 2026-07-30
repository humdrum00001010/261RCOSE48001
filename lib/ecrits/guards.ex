defmodule Ecrits.Guards do
  @moduledoc """
  Guards for conditions this codebase repeats often enough that the idiom is
  harder to read than a name.
  """

  @doc """
  A binary that is not empty.

  `is_binary(x) and x != ""` appeared 267 times across 40 modules. Every one of
  them means "present", and spelling it out invites the half-check — `is_binary`
  alone, which accepts `""` — that the pattern exists to avoid.
  """
  defguard is_present(value) when is_binary(value) and value != ""
end
