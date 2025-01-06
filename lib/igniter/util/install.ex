defmodule Igniter.Util.Install do
  @moduledoc """
  Tools for installing packages and running their associated
  installers, if present.

  [!NOTE]
  The functions in this module are not composable, and are primarily meant to
  be used internally and to support building custom tooling on top of Igniter,
  such as [Fireside](https://github.com/ibarakaiev/fireside).
  """

  @doc """
  Installs the provided list of dependencies. `deps` can be either:
  - a string like `"ash,ash_postgres"`
  - a list of strings like `["ash", "ash_postgres", ...]`
  - a list of tuples like `[{:ash, "~> 3.0"}, {:ash_postgres, "~> 2.0"}]`
  """
  def install(deps, argv, igniter \\ Igniter.new(), opts \\ [])

  def install(deps, argv, igniter, opts) when is_binary(deps) do
    deps = String.split(deps, ",")

    install(deps, argv, igniter, opts)
  end

  def install([head | _] = deps, argv, igniter, opts) when is_binary(head) do
    deps =
      Enum.map(deps, fn dep ->
        case Igniter.Project.Deps.determine_dep_type_and_version(dep) do
          {install, requirement} ->
            {install, requirement}

          :error ->
            raise "Could not determine source for requested package #{dep}"
        end
      end)

    install(deps, argv, igniter, opts)
  end

  def install([head | _] = deps, argv, igniter, opts) when is_tuple(head) do
    if Enum.any?(deps, &(elem(&1, 0) == :igniter)) do
      raise ArgumentError,
            "cannot install the igniter package with `mix igniter.install`. Please use `mix igniter.setup` instead."
    end

    global_options =
      Keyword.update!(
        Igniter.Mix.Task.Info.global_options(),
        :switches,
        &Keyword.put(&1, :example, :boolean)
      )

    only =
      argv
      |> OptionParser.parse!(switches: [only: :keep])
      |> elem(0)
      |> Keyword.get_values(:only)
      |> Enum.join(",")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)
      |> case do
        [] -> nil
        value -> value
      end

    if only && Mix.env() not in only do
      raise """
      The `--only` option can only be used when running `mix igniter.install` in an environment
      that matches one of the environments in `--only`. For example:

          MIX_ENV=#{Enum.at(only, 0)} mix igniter.install --only #{Enum.join(only, ",")}
      """
    end

    {igniter, installing, {options, _}} =
      Igniter.Util.Info.compose_install_and_validate!(
        igniter,
        argv,
        %Igniter.Mix.Task.Info{
          schema: global_options[:switches],
          aliases: [],
          installs: deps
        },
        "igniter.install",
        yes: "--yes" in argv,
        yes_to_deps: "--yes-to-deps" in argv,
        only: only,
        append?: Keyword.get(opts, :append?, false)
      )

    installing_names = Enum.join(installing, ", ")

    igniter =
      Igniter.apply_and_fetch_dependencies(
        igniter,
        Keyword.put(options, :operation, "compiling #{installing_names}")
      )

    available_tasks =
      Enum.zip(installing, Enum.map(installing, &Mix.Task.get("#{&1}.install")))
      |> Enum.filter(fn {_desired_task, source_task} -> source_task end)

    case available_tasks do
      [] ->
        :ok

      [{name, _}] = tasks ->
        run_installers(
          igniter,
          tasks,
          "The following installer was found and executed: `#{name}.install`",
          argv,
          options
        )

      tasks ->
        run_installers(
          igniter,
          tasks,
          "The following installers were found and executed: #{Enum.map_join(tasks, ", ", &"`#{elem(&1, 0)}.install`")}",
          argv,
          options
        )
    end

    IO.puts("\nSuccessfully installed:\n\n#{Enum.map_join(installing, "\n", &"* #{&1}")}")
  end

  defp run_installers(igniter, igniter_task_sources, title, argv, options) do
    igniter_task_sources
    |> Enum.reduce(igniter, fn {name, task}, igniter ->
      igniter = Igniter.compose_task(igniter, task, argv)
      Mix.shell().info("`#{name}.install` #{IO.ANSI.green()}✔#{IO.ANSI.reset()}")
      igniter
    end)
    |> Igniter.do_or_dry_run(Keyword.put(options, :title, title))

    :ok
  end

  def get_deps!(igniter, opts) do
    case System.cmd("mix", ["deps.get"], stderr_to_stdout: true) do
      {_output, 0} ->
        Igniter.Util.Loading.with_spinner(
          opts[:operation] || "building deps",
          fn ->
            igniter =
              case List.wrap(opts[:update_deps]) do
                [] ->
                  igniter

                [:all] ->
                  System.cmd("mix", ["deps.update", "--all" | opts[:update_deps_args] || []],
                    stderr_to_stdout: true
                  )

                  %{igniter | rewrite: Rewrite.drop(igniter.rewrite, ["mix.lock"])}

                to_update ->
                  System.cmd(
                    "mix",
                    ["deps.update" | to_update] ++ (opts[:update_deps_args] || []),
                    stderr_to_stdout: true
                  )

                  %{igniter | rewrite: Rewrite.drop(igniter.rewrite, ["mix.lock"])}
              end

            Mix.Project.pop()

            old_undefined = Code.get_compiler_option(:no_warn_undefined)
            old_relative_paths = Code.get_compiler_option(:relative_paths)
            old_ignore_module_conflict = Code.get_compiler_option(:ignore_module_conflict)

            try do
              Code.compiler_options(
                relative_paths: false,
                no_warn_undefined: :all,
                ignore_module_conflict: true
              )

              igniter =
                if Keyword.get(opts, :compile_deps?, true) do
                  System.cmd("mix", ["deps.get"], stderr_to_stdout: true)
                  System.cmd("mix", ["deps.compile"], stderr_to_stdout: true)

                  %{igniter | rewrite: Rewrite.drop(igniter.rewrite, ["mix.lock"])}
                else
                  igniter
                end

              _ = Code.compile_file("mix.exs")

              if Keyword.get(opts, :compile_deps?, true) do
                Mix.Task.reenable("deps.loadpaths")
                Mix.Task.run("deps.loadpaths", ["--no-deps-check"])
              end

              igniter
            after
              Code.compiler_options(
                relative_paths: old_relative_paths,
                no_warn_undefined: old_undefined,
                ignore_module_conflict: old_ignore_module_conflict
              )
            end
          end
        )

      {output, exit_code} ->
        case handle_error(output, exit_code, igniter, opts) do
          {:ok, igniter} ->
            get_deps!(igniter, Keyword.put(opts, :name, "applying dependency conflict changes"))

          :error ->
            Mix.shell().info("""
            mix deps.get returned exited with code: `#{exit_code}`
            """)

            raise output
        end
    end
  end

  defp handle_error(output, _exit_code, igniter, opts) do
    if String.contains?(output, "Dependencies have diverged") do
      handle_diverged_dependencies(output, igniter, opts)
    else
      :error
    end
  end

  defp handle_diverged_dependencies(rest, igniter, opts) do
    with [_, dep] <-
           String.split(rest, "the :only option for dependency ", parts: 2, trim: true),
         [dep, rest] <- String.split(dep, ["\n", " "], parts: 2, trim: true),
         [_, source1] <- String.split(rest, "> In ", parts: 2, trim: true),
         [source1, rest] <- String.split(source1, ":", parts: 2, trim: true),
         [declaration1, rest] <-
           String.split(rest, "does not match the :only option calculated for",
             parts: 2,
             trim: true
           ),
         [_, source2] <- String.split(rest, "> In ", parts: 2, trim: true),
         [source2, rest] <- String.split(source2, ":", parts: 2, trim: true),
         [declaration2, _] <-
           String.split(rest, "\n\n", parts: 2, trim: true) do
      dep = String.to_atom(dep)
      source1 = parse_source(source1)
      source2 = parse_source(source2)
      # This is hacky :(
      {declaration1, _} = Code.eval_string(String.replace(declaration1, ", ...", ""))
      {declaration2, _} = Code.eval_string(String.replace(declaration2, ", ...", ""))

      with {^dep, req, opts1} <- declaration1,
           {^dep, _, opts2} <- declaration2 do
        opts1 = Keyword.put_new(opts1, :only, [:dev, :test, :prod])
        opts2 = Keyword.put_new(opts2, :only, [:dev, :test, :prod])
        only = List.wrap(opts1[:only]) ++ List.wrap(opts2[:only])

        igniter =
          case Igniter.Project.Deps.get_dependency_declaration(igniter, dep) do
            nil ->
              Igniter.Project.Deps.add_dep(igniter, {dep, req, Keyword.put(opts1, :only, only)},
                yes?: true
              )

            string ->
              {existing_statement, _} = Code.eval_string(string)

              case existing_statement do
                {dep, requirement} when is_binary(requirement) ->
                  if only == [:dev, :test, :prod] do
                    Igniter.Project.Deps.add_dep(igniter, {dep, requirement}, yes?: true)
                  else
                    Igniter.Project.Deps.add_dep(igniter, {dep, requirement, [only: only]},
                      yes?: true
                    )
                  end

                {dep, opts} when is_list(opts) ->
                  if only == [:dev, :test, :prod] do
                    Igniter.Project.Deps.add_dep(igniter, {dep, Keyword.delete(opts, :only)},
                      yes?: true
                    )
                  else
                    Igniter.Project.Deps.add_dep(igniter, {dep, Keyword.put(opts, :only, only)},
                      yes?: true
                    )
                  end

                {dep, requirement, opts} ->
                  if only == [:dev, :test, :prod] do
                    Igniter.Project.Deps.add_dep(
                      igniter,
                      {dep, requirement, Keyword.put(opts, :only, only)},
                      yes?: true
                    )
                  else
                    case Keyword.delete(opts, :only) do
                      [] ->
                        Igniter.Project.Deps.add_dep(
                          igniter,
                          {dep, requirement},
                          yes?: true
                        )

                      new_opts ->
                        Igniter.Project.Deps.add_dep(
                          igniter,
                          {dep, requirement, new_opts},
                          yes?: true
                        )
                    end
                  end

                _ ->
                  :error
              end
          end

        case igniter do
          :error ->
            :error

          igniter ->
            message = """
            Conflict in `only` option for dependency #{inspect(dep)}. 
            Between #{source1} and #{source2}.

            We must update the `only` option as shown to continue.
            """

            {:ok,
             Igniter.apply_and_fetch_dependencies(
               igniter,
               Keyword.merge(opts,
                 compile_deps?: false,
                 operation: "recompiling conflicts",
                 message: message,
                 error_on_abort?: true
               )
             )}
        end
      else
        _ ->
          :error
      end
    else
      _ ->
        :error
    end
  rescue
    _e ->
      :error
  end

  defp parse_source("mix.exs"), do: "your application"

  defp parse_source("deps/" <> dep) do
    case String.split(dep, "/", parts: 2, trim: true) |> Enum.at(0) do
      nil ->
        "deps/#{dep}"

      dep ->
        "the :#{dep} dependency"
    end
  end

  defp parse_source(dep), do: "\"#{dep}\""
end
