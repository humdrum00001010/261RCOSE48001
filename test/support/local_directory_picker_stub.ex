defmodule EcritsWeb.LocalDirectoryPickerStub do
  @behaviour EcritsWeb.Local.DirectoryPicker

  @valid_path "/tmp/ecrits-local-ui"

  def valid_path, do: @valid_path

  @impl true
  def choose_folder do
    Application.get_env(:ecrits, :local_directory_picker_stub, {:ok, @valid_path})
  end
end
