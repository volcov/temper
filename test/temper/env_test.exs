defmodule Temper.EnvTest do
  # These tests mutate process-global environment variables.
  use ExUnit.Case, async: false

  alias Temper.Env
  alias Temper.RunContext

  @env_vars ~w(
    GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_SHA GITHUB_REF_NAME GITHUB_HEAD_REF
    GITLAB_CI CI_PIPELINE_ID CI_COMMIT_SHA CI_COMMIT_REF_NAME
    CI_MERGE_REQUEST_SOURCE_BRANCH_NAME
    CIRCLECI CIRCLE_WORKFLOW_ID CIRCLE_SHA1 CIRCLE_BRANCH
    MIX_TEST_PARTITION
  )

  setup do
    saved = Map.new(@env_vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  describe "gather/1 always" do
    test "returns a fresh 16-byte hex run_id per call" do
      %{run_id: first} = Env.gather()
      %{run_id: second} = Env.gather()

      assert first =~ ~r/^[0-9a-f]{32}$/
      assert second =~ ~r/^[0-9a-f]{32}$/
      refute first == second
    end

    test "returns a UTC ISO 8601 timestamp" do
      %{at: at} = Env.gather()

      assert {:ok, %DateTime{utc_offset: 0}, 0} = DateTime.from_iso8601(at)
      assert String.ends_with?(at, "Z")
    end

    test "returns the running Elixir and OTP versions" do
      assert %{elixir: elixir, otp: otp} = Env.gather()
      assert elixir == System.version()
      assert otp == System.otp_release()
    end

    test "produces a map accepted by RunContext.new/1" do
      context = Env.gather() |> RunContext.new()

      assert %RunContext{} = context
      assert context.seed == nil
    end
  end

  describe "gather/1 outside CI" do
    test "in a git repository gathers sha, dirty flag and branch from git" do
      %{sha: sha, dirty: dirty, branch: branch, ci: ci} = Env.gather()

      assert sha =~ ~r/^[0-9a-f]{40}$/
      assert is_boolean(dirty)
      assert is_binary(branch)
      assert ci == nil
    end

    test "outside a git repository degrades to nil values" do
      # ExUnit's :tmp_dir lives inside this repository, so build a
      # directory under the system temp path where git finds no repo.
      outside_dir =
        Path.join(System.tmp_dir!(), "temper_env_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      %{sha: sha, dirty: dirty, branch: branch, ci: ci} = Env.gather(cd: outside_dir)

      assert sha == nil
      assert dirty == false
      assert branch == nil
      assert ci == nil
    end

    test "reads MIX_TEST_PARTITION when set" do
      System.put_env("MIX_TEST_PARTITION", "3")

      assert %{partition: "3"} = Env.gather()
    end

    test "leaves partition nil when MIX_TEST_PARTITION is unset" do
      assert %{partition: nil} = Env.gather()
    end
  end

  describe "gather/1 on GitHub Actions" do
    setup do
      System.put_env("GITHUB_ACTIONS", "true")
      System.put_env("GITHUB_RUN_ID", "1234567")
      System.put_env("GITHUB_SHA", String.duplicate("ab", 20))
      System.put_env("GITHUB_REF_NAME", "main")
      :ok
    end

    test "detects the provider and its run id" do
      assert %{ci: %{provider: "github", run_id: "1234567"}} = Env.gather()
    end

    test "prefers the CI-provided sha and branch over shelling out" do
      %{sha: sha, dirty: dirty, branch: branch} = Env.gather()

      assert sha == String.duplicate("ab", 20)
      assert dirty == false
      assert branch == "main"
    end

    test "on pull_request events uses the source branch, not the merge ref" do
      System.put_env("GITHUB_REF_NAME", "4/merge")
      System.put_env("GITHUB_HEAD_REF", "feature/my-change")

      assert %{branch: "feature/my-change"} = Env.gather()
    end

    test "ignores an empty GITHUB_HEAD_REF on push events" do
      System.put_env("GITHUB_HEAD_REF", "")

      assert %{branch: "main"} = Env.gather()
    end

    test "falls back to local git when the sha variable is empty" do
      System.put_env("GITHUB_SHA", "")

      %{sha: sha, ci: ci} = Env.gather()

      assert sha =~ ~r/^[0-9a-f]{40}$/
      assert %{provider: "github"} = ci
    end
  end

  describe "gather/1 on GitLab CI" do
    test "detects the provider and uses its git variables" do
      System.put_env("GITLAB_CI", "true")
      System.put_env("CI_PIPELINE_ID", "42")
      System.put_env("CI_COMMIT_SHA", String.duplicate("cd", 20))
      System.put_env("CI_COMMIT_REF_NAME", "my-feature")

      %{ci: ci, sha: sha, branch: branch} = Env.gather()

      assert ci == %{provider: "gitlab", run_id: "42"}
      assert sha == String.duplicate("cd", 20)
      assert branch == "my-feature"
    end

    test "on merge request pipelines prefers the source branch" do
      System.put_env("GITLAB_CI", "true")
      System.put_env("CI_COMMIT_SHA", String.duplicate("cd", 20))
      System.put_env("CI_COMMIT_REF_NAME", "refs/merge-requests/7/head")
      System.put_env("CI_MERGE_REQUEST_SOURCE_BRANCH_NAME", "fix/typo")

      assert %{branch: "fix/typo"} = Env.gather()
    end
  end

  describe "gather/1 on CircleCI" do
    test "detects the provider and uses its git variables" do
      System.put_env("CIRCLECI", "true")
      System.put_env("CIRCLE_WORKFLOW_ID", "wf-1")
      System.put_env("CIRCLE_SHA1", String.duplicate("ef", 20))
      System.put_env("CIRCLE_BRANCH", "fix/bug")

      %{ci: ci, sha: sha, branch: branch} = Env.gather()

      assert ci == %{provider: "circleci", run_id: "wf-1"}
      assert sha == String.duplicate("ef", 20)
      assert branch == "fix/bug"
    end
  end
end
