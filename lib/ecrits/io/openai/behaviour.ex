defmodule Ecrits.IO.OpenAI.Behaviour do
  @moduledoc """
  Behaviour for the OpenAI Responses-API driver. Implemented by
  `Ecrits.IO.OpenAI` in production and mocked via Mox in tests.
  """

  @type params :: map()
  @type opts :: keyword()
  @type stream_result :: %{stream: Enumerable.t(), task_pid: pid()}

  @callback stream_chat(params(), opts()) :: {:ok, stream_result()} | {:error, term()}
  @callback one_shot(params(), opts()) :: {:ok, map()} | {:error, term()}
end
