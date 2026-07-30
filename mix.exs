defmodule Ecrits.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecrits,
      version: "0.1.2",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Ecrits.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.edit_failures": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:tidewave, "~> 0.6", only: [:dev]},
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.8"},
      {:ecto, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.23.0"},
      {:phoenix_html, "~> 4.1"},
      {:mdex, "~> 0.13"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      # Binary ingress over Phoenix Channels with credit-based flow control;
      # extracted from this app (github.com/humdrum00001010/phoenix_octet).
      {:phoenix_octet, github: "humdrum00001010/phoenix_octet"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:file_system, "~> 1.0"},
      {:bandit, "~> 1.5"},
      # Pin the ecrits integration branch: upstream PR #12's structured decisions
      # plus upstream PR #13's Codex file-change snapshots and the Claude
      # streamed-text deduplication fix. `override: true` is required because
      # orchex still constrains ex_mcp 0.10.x.
      {:ex_mcp,
       git: "https://github.com/humdrum00001010/ex_mcp",
       ref: "7bb2e323228aa1e774664ad80968d8b702803f11",
       override: true},
      # REMOVED 2026-07-26 — :ehwp and :libreofficex. They carried both the server
      # NIF authority (`Ehwp.*` / `Libreofficex.LokBackend.*`) AND the client wasm
      # bundles (each dep's priv/wasm). Replaced by DocLang as the live IR plus
      # upstream engine UIs (LibreOffice Qt6+JSPI, rhwp-studio embed RPC).
      # See docs/plans/2026-07-26-doclang-engine-migration.md.
      {:orchex, git: "git@code.cloudxyz.org:IlYoung/Orchex.git", branch: "main"},
      # Markdown + TeX/TikZ composite renderer backing the .md document preview
      # (`EcritsWeb.Markdown.to_preview_html/1`). `Observex.render_body/1` emits
      # <tex-island> markup; the browser runtime installed by `mix assets.observex`
      # (served at /observex/) renders the islands with MathJax/TikZJax client-side.
      {:observex, git: "git@code.cloudxyz.org:IlYoung/observex.git", branch: "main"},
      # Elixir-over-FUSE library backing the document VFS (Ecrits.Fuse.*). Pure
      # source over https. On macOS it mounts through the FSKit extension and
      # builds nothing native; on other Unix its `:exfuse_rust` mix compiler
      # cargo-builds the FUSE `priv/exfuse_port`. See AGENTS.md "exfuse dep" +
      # docs/plans/2026-06-23-exfuse-doc-vfs-migration.md.
      {:exfuse, git: "https://github.com/humdrum00001010/exfuse", branch: "main"},
      # ecrits extra deps.
      {:dotenvy, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:burrito,
       github: "burrito-elixir/burrito",
       ref: "8fa7eda03deabb74956f5f16027f540cb2df5385",
       runtime: false}
    ]
  end

  defp releases do
    [
      ecrits: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          debug: false,
          targets: [
            macos_silicon: [os: :darwin, cpu: :aarch64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "assets.observex"
      ],
      # The HWP wasm rode the deleted `:ehwp` dep's priv/wasm and fed the legacy
      # `Canvas.HwpPages` hook. Both are gone (rhwp-studio ships its own
      # `rhwp_bg.wasm` inside its bundle), so this only purges the retired
      # app-static/vendor scratch output now.
      "assets.rhwp_wasm": [
        ~s(cmd sh -c "set -eu; rm -rf priv/static/assets/rhwp assets/vendor/rhwp")
      ],
      # NOTE: `assets.office_wasm` is deliberately NOT an alias any more. It is a
      # real task (`Mix.Tasks.Assets.OfficeWasm`) — office engine delivery for
      # Layer 4, un-retired now that the wasm no longer rides the deleted
      # `:libreofficex` dep's priv/wasm:
      #
      #     OFFICE_WASM_DIST=<core-wasm-build>/instdir/program mix assets.office_wasm
      #
      # An alias of the same name would SHADOW the task, so it was removed rather
      # than emptied; the retired-scratch purge it used to do moved into the task.
      # Unset/absent source is a no-op (no $HOME default — it would leak a
      # developer path and be non-reproducible). The bundle is ~315 MB, so the env
      # var alone (read by config/runtime.exs) serves it in place with NO copy;
      # run the task only for a self-contained priv/static.
      # HWP engine delivery (Layer 4). rhwp-studio is a Vite/npm app living in the
      # rhwp_core checkout; this repo carries no Node toolchain, so the bundle is
      # BUILT there and only the built `dist/` is copied in:
      #
      #     cd <rhwp_core>/rhwp-studio && npm run build -- --base=/rhwp-studio/
      #     RHWP_STUDIO_DIST=<rhwp_core>/rhwp-studio/dist mix assets.rhwp_studio
      #
      # No default path is baked in on purpose (a $HOME/... default would leak a
      # user path and be non-reproducible); an unset/absent source is a no-op so
      # `mix assets.build` still works on a machine without the checkout.
      # `samples/` is dropped (7.5 MB of demo documents the host never opens) and
      # the swap is tmp-then-mv, so a live tab never fetches a half-copied wasm.
      # Implemented as `Mix.Tasks.Assets.RhwpStudio` rather than an inline shell
      # one-liner: the copy needs quoting, an exclude and an atomic rename, all of
      # which read badly through `OptionParser.split/1`.
      "assets.build": [
        "compile",
        "assets.rhwp_wasm",
        "assets.office_wasm",
        "assets.rhwp_studio",
        "tailwind ecrits",
        "esbuild ecrits"
      ],
      "assets.deploy": [
        "assets.rhwp_wasm",
        "assets.office_wasm",
        "assets.rhwp_studio",
        "tailwind ecrits --minify",
        "esbuild ecrits --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test test"],
      "test.pure": ["test --no-start"],
      "test.edit_failures": [
        "cmd --cd deps/phoenix_octet env MIX_DEPS_PATH=.. MIX_BUILD_PATH=../../_build/octet_failure_test mix test",
        "test --only edit_failure"
      ],
      # Auto-advance our own branch-pinned repos (`exfuse`, `phoenix_octet`) to
      # their HEAD on every `mix deps.get`. A plain deps.get honors the SHA in
      # `mix.lock`, so it would silently keep an old commit after we push; a
      # `deps.update` first re-resolves the branch. The trailing `deps.get` is
      # the real task (Mix runs the underlying task, not this alias, so there
      # is no recursion).
      "deps.get": ["deps.update exfuse phoenix_octet", "deps.get"]
    ]
  end
end
