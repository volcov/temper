defmodule Temper.RunContext do
  @moduledoc """
  The run context shared by every test outcome recorded during one
  ExUnit suite run.

  A `RunContext` captures *where and how* a suite ran: the git SHA (so
  divergent outcomes on the same code can be detected), whether the
  working tree was dirty, the CI provider if any, the ExUnit seed, the
  test partition, and the Elixir/OTP versions.

  This module is part of Temper's functional core: `new/1` builds the
  struct from a plain map and performs no side effects. Gathering that
  map from the real environment (git, env vars, the clock) is the job
  of the boundary module `Temper.Env`.
  """

  @enforce_keys [:run_id, :at, :elixir, :otp]
  defstruct [:run_id, :at, :sha, :branch, :ci, :seed, :partition, :elixir, :otp, dirty: false]

  @typedoc "CI information: provider name and its run identifier, if known."
  @type ci :: %{provider: String.t(), run_id: String.t() | nil}

  @type t :: %__MODULE__{
          run_id: String.t(),
          at: String.t(),
          sha: String.t() | nil,
          dirty: boolean(),
          branch: String.t() | nil,
          ci: ci() | nil,
          seed: non_neg_integer() | nil,
          partition: String.t() | nil,
          elixir: String.t(),
          otp: String.t()
        }

  @doc """
  Builds a `RunContext` from a plain map of gathered environment data.

  Required keys: `:run_id`, `:at` (UTC ISO 8601 timestamp), `:elixir`
  and `:otp`. Raises `KeyError` when any of them is missing.

  Optional keys and their defaults:

    * `:sha` — current git commit, `nil` outside a repository
    * `:dirty` — whether the working tree had uncommitted changes,
      defaults to `false`
    * `:branch` — current git branch, `nil` when unknown
    * `:ci` — `%{provider: ..., run_id: ...}` map, `nil` outside CI
    * `:seed` — the ExUnit seed for this run, `nil` when unknown
    * `:partition` — `MIX_TEST_PARTITION` value, `nil` when unset

  ## Examples

      iex> context =
      ...>   Temper.RunContext.new(%{
      ...>     run_id: "9f1c2b3a4d5e6f708192a3b4c5d6e7f8",
      ...>     at: "2026-08-21T14:03:22Z",
      ...>     elixir: "1.20.2",
      ...>     otp: "27"
      ...>   })
      iex> context.dirty
      false
      iex> context.sha
      nil

  """
  @spec new(map()) :: t()
  def new(env) when is_map(env) do
    %__MODULE__{
      run_id: Map.fetch!(env, :run_id),
      at: Map.fetch!(env, :at),
      sha: Map.get(env, :sha),
      dirty: Map.get(env, :dirty, false),
      branch: Map.get(env, :branch),
      ci: Map.get(env, :ci),
      seed: Map.get(env, :seed),
      partition: Map.get(env, :partition),
      elixir: Map.fetch!(env, :elixir),
      otp: Map.fetch!(env, :otp)
    }
  end
end
