defmodule ContractWeb.PageController do
  use ContractWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
