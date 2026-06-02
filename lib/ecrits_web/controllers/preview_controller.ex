defmodule EcritsWeb.PreviewController do
  use EcritsWeb, :controller

  def index(conn, _params) do
    Gettext.put_locale(EcritsWeb.Gettext, "ko")
    render(conn, :index, layout: false)
  end
end
