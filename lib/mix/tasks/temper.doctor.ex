defmodule Mix.Tasks.Temper.Doctor do
  @shortdoc "Checks the Temper setup for silent failure modes"

  @moduledoc """
  Preflight check for a working Temper setup.

      $ mix temper.doctor

  Runs the checks that catch the mistakes which fail silently:

    * is `Temper.Formatter` registered for the test env — proven by
      the evaluated `config :ex_unit` value or by recorded history?
    * is `config :temper, history_path` visible outside the test env,
      so `mix temper.report` reads where the formatter writes?
    * do umbrella child apps declare `:temper`, or will app-dir test
      runs record nothing?
    * did test runs actually append records to the history?
    * do the recorded records carry a usable commit SHA?

  Exits with a non-zero status when a check finds a problem, so the
  doctor can gate setup verification in CI. Warnings do not fail.

  ## Options

    * `--history GLOB` — inspect this path or glob instead of the
      configured or default one. A literal `{partition}` widens to `*`

  """

  use Mix.Task

  alias Temper.Doctor

  @switches [history: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)

    checks = Doctor.evaluate(Doctor.gather(".", Keyword.take(opts, [:history])))

    Mix.shell().info(Doctor.render(checks))

    if Doctor.problems?(checks) do
      exit({:shutdown, 1})
    end
  end
end
