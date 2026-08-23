defmodule Temper.Env do
  @moduledoc """
  Boundary module that gathers run context data from the real world:
  git, CI environment variables, the system clock and the runtime.

  `gather/1` returns a plain map suitable for `Temper.RunContext.new/1`.
  All side effects live here so the core stays pure; every lookup
  degrades gracefully (no git, no repository, no CI) to `nil` values
  rather than raising.
  """

  @typedoc "Options for `gather/1`."
  @type option :: {:cd, Path.t()}

  # The :branch list is checked in order and the first non-empty variable
  # wins: pull-request/merge-request runs put a synthetic ref (e.g.
  # "4/merge") in the usual branch variable and expose the real source
  # branch in a PR-only variable.
  @providers [
    %{
      flag: "GITHUB_ACTIONS",
      name: "github",
      run_id: "GITHUB_RUN_ID",
      sha: "GITHUB_SHA",
      branch: ["GITHUB_HEAD_REF", "GITHUB_REF_NAME"]
    },
    %{
      flag: "GITLAB_CI",
      name: "gitlab",
      run_id: "CI_PIPELINE_ID",
      sha: "CI_COMMIT_SHA",
      branch: ["CI_MERGE_REQUEST_SOURCE_BRANCH_NAME", "CI_COMMIT_REF_NAME"]
    },
    %{
      flag: "CIRCLECI",
      name: "circleci",
      run_id: "CIRCLE_WORKFLOW_ID",
      sha: "CIRCLE_SHA1",
      branch: ["CIRCLE_BRANCH"]
    }
  ]

  @doc """
  Gathers environment data into a plain map for `Temper.RunContext.new/1`.

  The map always contains `:run_id` (fresh 16-byte random hex), `:at`
  (UTC ISO 8601, second precision), `:elixir`, `:otp`, `:partition`
  (from `MIX_TEST_PARTITION`), `:ci`, `:sha`, `:dirty` and `:branch`.

  Git data is resolved with the first source that answers:

  1. **Manual override** — a non-empty `TEMPER_SHA` switches git
     context to manual mode: `:sha` from `TEMPER_SHA`, `:dirty` from
     `TEMPER_DIRTY` (`"true"`/`"1"`/`"yes"`, default `false`),
     `:branch` from `TEMPER_BRANCH` (default `nil`). For environments
     where git is out of reach — a test container without the `.git`
     directory, a sandboxed build — pass the values in from outside.
     Without `TEMPER_SHA`, the other two `TEMPER_*` variables are
     ignored.
  2. **CI provider variables** (e.g. `GITHUB_SHA`) — CI checkouts are
     clean by construction, so no shelling out.
  3. **Local git** — `git rev-parse`/`git status` in `opts[:cd]`
     (default: the current directory); `nil` values outside a
     repository or without git installed.

  The ExUnit `:seed` is intentionally absent — only the formatter knows
  it, and merges it into this map itself.
  """
  @spec gather([option()]) :: map()
  def gather(opts \\ []) do
    cd = Keyword.get(opts, :cd, File.cwd!())
    provider = detect_provider()

    %{
      run_id: generate_run_id(),
      at: utc_now_iso8601(),
      elixir: System.version(),
      otp: System.otp_release(),
      partition: System.get_env("MIX_TEST_PARTITION"),
      ci: ci_info(provider)
    }
    |> Map.merge(git_info(provider, cd))
  end

  defp generate_run_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp utc_now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp detect_provider do
    Enum.find(@providers, fn provider -> System.get_env(provider.flag) == "true" end)
  end

  defp ci_info(nil), do: nil
  defp ci_info(provider), do: %{provider: provider.name, run_id: System.get_env(provider.run_id)}

  defp git_info(provider, cd) do
    manual_git_info() || ci_git_info(provider) || local_git_info(cd)
  end

  defp manual_git_info do
    case first_env(["TEMPER_SHA"]) do
      nil ->
        nil

      sha ->
        %{
          sha: sha,
          dirty: first_env(["TEMPER_DIRTY"]) in ~w(true 1 yes),
          branch: first_env(["TEMPER_BRANCH"])
        }
    end
  end

  defp ci_git_info(nil), do: nil

  defp ci_git_info(provider) do
    case first_env([provider.sha]) do
      nil -> nil
      sha -> %{sha: sha, dirty: false, branch: first_env(provider.branch)}
    end
  end

  # Environment values are trimmed so an injected "abc\n" groups with
  # the "abc" local git resolves — and whitespace-only counts as unset.
  defp first_env(vars) do
    Enum.find_value(vars, fn var ->
      case String.trim(System.get_env(var) || "") do
        "" -> nil
        value -> value
      end
    end)
  end

  defp local_git_info(cd) do
    case git(["rev-parse", "HEAD"], cd) do
      {:ok, sha} -> %{sha: sha, dirty: dirty?(cd), branch: local_branch(cd)}
      :error -> %{sha: nil, dirty: false, branch: nil}
    end
  end

  defp dirty?(cd) do
    case git(["status", "--porcelain"], cd) do
      {:ok, output} -> output != ""
      :error -> false
    end
  end

  defp local_branch(cd) do
    case git(["rev-parse", "--abbrev-ref", "HEAD"], cd) do
      # "HEAD" means a detached checkout, so there is no branch name.
      {:ok, "HEAD"} -> nil
      {:ok, branch} -> branch
      :error -> nil
    end
  end

  defp git(args, cd) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _nonzero} -> :error
    end
  rescue
    # git not installed, or cd does not exist.
    ErlangError -> :error
  end
end
