defmodule Men.RuntimeBridge.GongCLITest do
  use ExUnit.Case, async: false

  alias Men.RuntimeBridge.GongCLI

  setup do
    original = Application.get_env(:men, :runtime_bridge, [])
    script = build_fake_cli_script()

    Application.put_env(:men, :runtime_bridge,
      command: script,
      command_args: [],
      prompt_arg: "--prompt",
      request_id_arg: "--request-id",
      session_key_arg: "--session-key",
      run_id_arg: "--run-id",
      timeout_ms: 300,
      max_concurrency: 10,
      backpressure_strategy: :reject
    )

    reset_counter()

    on_exit(fn ->
      Application.put_env(:men, :runtime_bridge, original)
      reset_counter()
    end)

    :ok
  end

  test "正常请求返回统一成功结构并贯通追踪字段" do
    result =
      GongCLI.start_turn("ok", %{
        request_id: "req-1",
        session_key: "sess-1",
        run_id: "run-1"
      })

    assert {:ok, payload} = result
    assert payload.meta.run_id == "run-1"
    assert payload.meta.request_id == "req-1"
    assert payload.meta.session_key == "sess-1"
    assert payload.meta.exit_code == 0
    assert is_binary(payload.text)
    assert String.contains?(payload.text, "ok:run-1")
  end

  test "CLI 非零退出映射为 :failed + CLI_EXIT_<code>" do
    result =
      GongCLI.start_turn("fail", %{
        request_id: "req-fail",
        session_key: "sess-fail",
        run_id: "run-fail"
      })

    assert {:error, error} = result
    assert error.type == :failed
    assert error.code == "CLI_EXIT_127"
    assert error.run_id == "run-fail"
    assert error.request_id == "req-fail"
    assert error.session_key == "sess-fail"
    assert is_map(error.details)
    assert error.details.exit_code == 127
  end

  test "超时映射为 :timeout + CLI_TIMEOUT，并可追踪 run_id" do
    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:timeout_ms, 80)
    )

    result =
      GongCLI.start_turn("timeout", %{
        request_id: "req-timeout",
        session_key: "sess-timeout",
        run_id: "run-timeout"
      })

    assert {:error, error} = result
    assert error.type == :timeout
    assert error.code == "CLI_TIMEOUT"
    assert error.run_id == "run-timeout"
    assert error.request_id == "req-timeout"
    assert error.session_key == "sess-timeout"
    assert is_map(error.details)
    assert error.details.timeout_ms == 80
  end

  test "超时后子进程可被清理（无残留标识进程）" do
    run_id = "cleanup-#{System.unique_integer([:positive, :monotonic])}"

    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:timeout_ms, 80)
    )

    result =
      GongCLI.start_turn("child_timeout", %{
        request_id: "req-cleanup",
        session_key: "sess-cleanup",
        run_id: run_id
      })

    assert {:error, error} = result
    assert error.type == :timeout

    case System.find_executable("pgrep") do
      nil ->
        assert true

      _ ->
        Process.sleep(120)
        {_output, code} = System.cmd("pgrep", ["-f", "child-#{run_id}"])
        assert code != 0
    end
  end

  test "并发突增超过上限时快速返回 :overloaded" do
    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:max_concurrency, 2)
      |> Keyword.put(:timeout_ms, 2_000)
    )

    results =
      1..8
      |> Task.async_stream(
        fn idx ->
          GongCLI.start_turn("slow", %{
            request_id: "req-overload-#{idx}",
            session_key: "sess-overload",
            run_id: "run-overload-#{idx}"
          })
        end,
        max_concurrency: 8,
        timeout: 2_000
      )
      |> Enum.map(fn {:ok, item} -> item end)

    overloaded =
      Enum.count(results, fn
        {:error, %{type: :overloaded, code: "CLI_OVERLOADED"}} -> true
        _ -> false
      end)

    success =
      Enum.count(results, fn
        {:ok, _payload} -> true
        _ -> false
      end)

    assert overloaded > 0
    assert success > 0
  end

  test "外层 Task.shutdown/2 兜底路径可返回统一超时结构" do
    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:timeout_ms, 20)
      |> Keyword.put(:outer_wait_buffer_ms, 0)
      |> Keyword.put(:outer_shutdown_timeout_ms, 500)
    )

    result =
      GongCLI.start_turn("child_timeout", %{
        request_id: "req-outer-guard",
        session_key: "sess-outer-guard",
        run_id: "run-outer-guard"
      })

    assert {:error, error} = result
    assert error.type == :timeout
    assert error.code == "CLI_TIMEOUT"
    assert is_binary(error.details.cleanup_result)
    assert String.contains?(error.details.cleanup_result, "outer_guard")
  end

  test "空 prompt 仍按统一协议返回结果" do
    result =
      GongCLI.start_turn("", %{
        request_id: "req-empty-prompt",
        session_key: "sess-empty-prompt",
        run_id: "run-empty-prompt"
      })

    assert {:ok, payload} = result
    assert is_binary(payload.text)
    assert payload.meta.run_id == "run-empty-prompt"
  end

  test "非法 context 抛出 ArgumentError" do
    assert_raise ArgumentError, fn ->
      GongCLI.start_turn("ok", :invalid_context)
    end
  end

  test "命令不存在时返回统一失败结构" do
    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:command, "men_missing_cli_#{System.unique_integer([:positive, :monotonic])}")
    )

    result =
      GongCLI.start_turn("ok", %{
        request_id: "req-missing-command",
        session_key: "sess-missing-command",
        run_id: "run-missing-command"
      })

    assert {:error, error} = result
    assert error.type == :failed
    assert error.code == "CLI_EXIT_127"
    assert String.contains?(error.message, "non-zero status 127")
    assert error.details.exit_code == 127
  end

  test "不可执行命令路径返回统一失败结构" do
    script_path =
      Path.join(System.tmp_dir!(), "men_fake_non_exec_#{System.unique_integer([:positive, :monotonic])}.sh")

    File.write!(script_path, "#!/usr/bin/env bash\necho should_not_run\n")
    File.chmod!(script_path, 0o644)

    Application.put_env(:men, :runtime_bridge,
      Application.get_env(:men, :runtime_bridge, [])
      |> Keyword.put(:command, script_path)
    )

    result =
      GongCLI.start_turn("ok", %{
        request_id: "req-non-exec",
        session_key: "sess-non-exec",
        run_id: "run-non-exec"
      })

    assert {:error, error} = result
    assert error.type == :failed
    assert error.code == "CLI_EXIT_127"
    assert String.contains?(error.message, "non-zero status 127")
    assert error.details.exit_code == 127
  end

  defp reset_counter do
    case :ets.info(:men_runtime_bridge_counter) do
      :undefined -> :ok
      _ -> :ets.delete(:men_runtime_bridge_counter)
    end
  end

  defp build_fake_cli_script do
    script_path = Path.join(System.tmp_dir!(), "men_fake_gong_cli_#{System.unique_integer([:positive])}.sh")

    content = """
    #!/usr/bin/env bash
    set -eu

    RUN_ID=""
    INPUT=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --prompt)
          INPUT="$2"
          shift 2
          ;;
        --run-id)
          RUN_ID="$2"
          shift 2
          ;;
        --request-id|--session-key)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done

    case "$INPUT" in
      ok)
        echo "ok:${RUN_ID}"
        exit 0
        ;;
      fail)
        echo "failed:${RUN_ID}" >&2
        exit 127
        ;;
      timeout)
        sleep 2
        echo "late:${RUN_ID}"
        exit 0
        ;;
      child_timeout)
        bash -c "exec -a child-${RUN_ID} sleep 5" &
        wait $!
        ;;
      slow)
        sleep 0.4
        echo "slow:${RUN_ID}"
        exit 0
        ;;
      *)
        echo "echo:${INPUT}:${RUN_ID}"
        exit 0
        ;;
    esac
    """

    File.write!(script_path, content)
    File.chmod!(script_path, 0o755)
    script_path
  end
end
