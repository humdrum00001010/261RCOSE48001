defmodule Ecrits.MailerTest do
  use ExUnit.Case, async: true

  import Swoosh.Email
  alias Ecrits.Mailer

  describe "from/0" do
    test "returns the configured :mail_from tuple" do
      original = Application.get_env(:ecrits, :mail_from)

      try do
        Application.put_env(:ecrits, :mail_from, {"Ecrits", "ereignis@korea.ac.kr"})
        assert {"Ecrits", "ereignis@korea.ac.kr"} = Mailer.from()
      after
        if original do
          Application.put_env(:ecrits, :mail_from, original)
        else
          Application.delete_env(:ecrits, :mail_from)
        end
      end
    end

    test "falls back to a safe default when env is unset" do
      original = Application.get_env(:ecrits, :mail_from)
      Application.delete_env(:ecrits, :mail_from)

      try do
        assert {"Ecrits", "no-reply@example.com"} = Mailer.from()
      after
        if original, do: Application.put_env(:ecrits, :mail_from, original)
      end
    end
  end

  describe "Swoosh.Adapters.Test (default in test env)" do
    import Swoosh.TestAssertions

    test "deliver/1 captures the email and uses Mailer.from()" do
      Application.put_env(:ecrits, :mail_from, {"Ecrits", "ereignis@korea.ac.kr"})

      email =
        new()
        |> to({"User", "user@example.com"})
        |> from(Mailer.from())
        |> subject("Hello")
        |> text_body("Body")

      assert {:ok, _meta} = Mailer.deliver(email)
      assert_email_sent(subject: "Hello")
    end
  end

  describe "live SMTP smoke (tagged, opt-in)" do
    @describetag :live_smtp

    test "sends a real message to MAIL_FROM_ADDRESS" do
      addr = System.fetch_env!("MAIL_FROM_ADDRESS")

      email =
        new()
        |> to({"Self", addr})
        |> from(Mailer.from())
        |> subject("ecrits :live_smtp smoke")
        |> text_body("If you see this, Worksmobile SMTP works under OTP 28.")

      assert {:ok, _meta} = Mailer.deliver(email)
    end
  end
end
