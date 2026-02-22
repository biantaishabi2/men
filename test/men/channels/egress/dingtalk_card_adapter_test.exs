defmodule Men.Channels.Egress.DingtalkCardAdapterTest do
  use ExUnit.Case, async: true

  alias Men.Channels.Egress.DingtalkCardAdapter
  alias Men.Channels.Egress.Messages.{EventMessage, FinalMessage}
  alias Men.Gateway.StreamSessionStore

  defmodule MockTransport do
    @behaviour Men.Channels.Egress.DingtalkCardAdapter.HttpTransport

    @impl true
    def request(method, url, headers, body, _opts) do
      if pid = Application.get_env(:men, :dingtalk_card_test_pid) do
        send(pid, {:card_http, method, url, headers, body})
      end

      cond do
        method == :get and String.contains?(url, "gettoken") ->
          {:ok, %{status: 200, body: %{"access_token" => "card-token"}}}

        method == :put and String.contains?(url, "/card/streaming") ->
          {:ok, %{status: 200, body: %{}}}

        method == :post and String.contains?(url, "/card/instances/createAndDeliver") ->
          {:ok, %{status: 200, body: %{"cardInstanceId" => "card-inst-1"}}}

        true ->
          {:ok, %{status: 200, body: %{}}}
      end
    end
  end

  defmodule MockFallbackAdapter do
    import Kernel, except: [send: 2]
    @behaviour Men.Channels.Egress.Adapter

    @impl true
    def send(target, message) do
      if pid = Application.get_env(:men, :dingtalk_card_test_pid) do
        Kernel.send(pid, {:fallback_send, target, message})
      end

      :ok
    end
  end

  setup do
    StreamSessionStore.__reset_for_test__()
    Application.put_env(:men, :dingtalk_card_test_pid, self())

    Application.put_env(:men, DingtalkCardAdapter,
      enabled: true,
      app_key: "app-key",
      app_secret: "app-secret",
      robot_code: "ding-robot-1",
      card_template_id: "tpl-1",
      last_message: "处理中...",
      search_desc: "搜索描述",
      search_icon: "https://example.com/icon.png",
      card_create_url: "https://api.dingtalk.com/v1.0/card/instances/createAndDeliver",
      card_append_url: "https://api.dingtalk.com/v1.0/card/streaming",
      card_finalize_url: "https://api.dingtalk.com/v1.0/card/streaming",
      token_url: "https://oapi.dingtalk.com/gettoken",
      transport: MockTransport,
      fallback_adapter: MockFallbackAdapter
    )

    on_exit(fn ->
      StreamSessionStore.__reset_for_test__()
      Application.delete_env(:men, :dingtalk_card_test_pid)
      Application.delete_env(:men, DingtalkCardAdapter)
    end)

    :ok
  end

  test "enabled?/0 受配置控制" do
    assert DingtalkCardAdapter.enabled?()
  end

  test "delta 缺少 run_id 时回退文本通道" do
    message = %EventMessage{
      event_type: :delta,
      payload: %{text: "part-1"},
      metadata: %{request_id: "req-x", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", message)
    assert_receive {:fallback_send, "dingtalk:u1", %EventMessage{}}
  end

  test "delta 会创建卡片并追加内容，final 会 finalize 并清理映射" do
    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "part-2"},
      metadata: %{request_id: "req-card-1", run_id: "run-card-1", session_key: "dingtalk:u1"}
    }

    final = %FinalMessage{
      session_key: "dingtalk:u1",
      content: "final-text",
      metadata: %{request_id: "req-card-1", run_id: "run-card-1"}
    }

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", delta)
    [{create_url, create_body}, {append_url, append_body}] = collect_post_requests(2)
    assert String.contains?(create_url, "/card/instances/createAndDeliver")
    assert String.contains?(append_url, "/card/streaming")

    create_json = Jason.decode!(create_body)
    assert create_json["cardData"]["stream"]["status"] == "streaming"
    assert create_json["cardData"]["status"]["phase"] == "streaming"
    assert create_json["cardData"]["meta"]["runId"] == "run-card-1"
    assert create_json["callbackType"] == "STREAM"
    assert create_json["imRobotOpenDeliverModel"]["spaceType"] == "IM_ROBOT"
    assert create_json["imRobotOpenSpaceModel"]["lastMessageI18n"]["ZH_CN"] == "处理中..."
    assert create_json["imRobotOpenSpaceModel"]["searchSupport"]["searchDesc"] == "搜索描述"

    append_json = Jason.decode!(append_body)
    assert append_json["outTrackId"] == "card-inst-1"
    assert append_json["key"] == "content"
    assert append_json["content"] == "part-2"
    assert append_json["isFinalize"] == false

    assert {:ok, data} = StreamSessionStore.get("run-card-1")
    assert data.card_instance_id == "card-inst-1"

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", final)
    [{finalize_url, finalize_body}] = collect_post_requests(1)
    assert String.contains?(finalize_url, "/card/streaming")
    finalize_json = Jason.decode!(finalize_body)
    assert finalize_json["key"] == "content"
    assert finalize_json["content"] == "final-text"
    assert finalize_json["isFinalize"] == true
    assert :error = StreamSessionStore.get("run-card-1")
  end

  test "tool delta 会透传到卡片状态块" do
    seed_delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "seed"},
      metadata: %{
        request_id: "req-card-tool-1",
        run_id: "run-card-tool-1",
        session_key: "dingtalk:u1"
      }
    }

    tool_delta = %EventMessage{
      event_type: :delta,
      payload: %{text: ""},
      metadata: %{
        request_id: "req-card-tool-1",
        run_id: "run-card-tool-1",
        session_key: "dingtalk:u1",
        tool_name: "list_directory",
        tool_status: "start"
      }
    }

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", seed_delta)
    _ = collect_post_requests(2)

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", tool_delta)
    [{append_url, append_body}] = collect_post_requests(1)
    assert String.contains?(append_url, "/card/streaming")

    append_json = Jason.decode!(append_body)
    assert append_json["content"] == "seed"
    assert append_json["isFinalize"] == false
  end

  test "create 返回 result 字段时也能提取卡片引用" do
    alt_transport = fn method, url, headers, body, _opts ->
      if pid = Application.get_env(:men, :dingtalk_card_test_pid) do
        send(pid, {:card_http, method, url, headers, body})
      end

      cond do
        method == :get and String.contains?(url, "gettoken") ->
          {:ok, %{status: 200, body: %{"access_token" => "card-token"}}}

        method == :put and String.contains?(url, "/card/streaming") ->
          {:ok, %{status: 200, body: %{}}}

        method == :post and String.contains?(url, "/card/instances/createAndDeliver") ->
          {:ok, %{status: 200, body: %{"result" => "out-track-1"}}}

        true ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    transport_mod =
      Module.concat(
        __MODULE__,
        :"DynamicTransport#{System.unique_integer([:positive, :monotonic])}"
      )

    {:module, ^transport_mod, _, _} =
      Module.create(
        transport_mod,
        quote do
          @behaviour Men.Channels.Egress.DingtalkCardAdapter.HttpTransport
          def request(method, url, headers, body, opts) do
            fun = Application.fetch_env!(:men, :dingtalk_card_dynamic_transport_fun)
            fun.(method, url, headers, body, opts)
          end
        end,
        Macro.Env.location(__ENV__)
      )

    Application.put_env(:men, :dingtalk_card_dynamic_transport_fun, alt_transport)
    current_cfg = Application.get_env(:men, DingtalkCardAdapter, [])

    Application.put_env(
      :men,
      DingtalkCardAdapter,
      Keyword.put(current_cfg, :transport, transport_mod)
    )

    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "x"},
      metadata: %{request_id: "req-result-1", run_id: "run-result-1", session_key: "dingtalk:u1"}
    }

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", delta)
    assert {:ok, data} = StreamSessionStore.get("run-result-1")
    assert data.card_instance_id == "out-track-1"
  after
    Application.delete_env(:men, :dingtalk_card_dynamic_transport_fun)
  end

  test "createAndDeliver 返回 deliverResults 失败时会直接降级文本" do
    fail_transport = fn method, url, headers, body, _opts ->
      if pid = Application.get_env(:men, :dingtalk_card_test_pid) do
        send(pid, {:card_http, method, url, headers, body})
      end

      cond do
        method == :get and String.contains?(url, "gettoken") ->
          {:ok, %{status: 200, body: %{"access_token" => "card-token"}}}

        method == :post and String.contains?(url, "/card/instances/createAndDeliver") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "result" => %{
                 "outTrackId" => "ot-1",
                 "deliverResults" => [%{"success" => false, "errorMsg" => "spaceId is illegal"}]
               }
             }
           }}

        true ->
          {:ok, %{status: 200, body: %{}}}
      end
    end

    transport_mod =
      Module.concat(__MODULE__, :"FailTransport#{System.unique_integer([:positive, :monotonic])}")

    {:module, ^transport_mod, _, _} =
      Module.create(
        transport_mod,
        quote do
          @behaviour Men.Channels.Egress.DingtalkCardAdapter.HttpTransport
          def request(method, url, headers, body, opts) do
            fun = Application.fetch_env!(:men, :dingtalk_card_dynamic_transport_fun)
            fun.(method, url, headers, body, opts)
          end
        end,
        Macro.Env.location(__ENV__)
      )

    Application.put_env(:men, :dingtalk_card_dynamic_transport_fun, fail_transport)
    current_cfg = Application.get_env(:men, DingtalkCardAdapter, [])

    Application.put_env(
      :men,
      DingtalkCardAdapter,
      Keyword.put(current_cfg, :transport, transport_mod)
    )

    delta = %EventMessage{
      event_type: :delta,
      payload: %{text: "x"},
      metadata: %{
        request_id: "req-deliver-fail",
        run_id: "run-deliver-fail",
        session_key: "dingtalk:u1"
      }
    }

    assert :ok = DingtalkCardAdapter.send("dingtalk:u1", delta)
    assert :error = StreamSessionStore.get("run-deliver-fail")
    assert_receive {:fallback_send, "dingtalk:u1", %EventMessage{}}
  after
    Application.delete_env(:men, :dingtalk_card_dynamic_transport_fun)
  end

  defp collect_post_requests(expected, acc \\ []) do
    if length(acc) >= expected do
      Enum.reverse(acc)
    else
      receive do
        {:card_http, :post, url, _headers, body} ->
          collect_post_requests(expected, [{url, body} | acc])

        {:card_http, :put, url, _headers, body} ->
          collect_post_requests(expected, [{url, body} | acc])

        {:card_http, :get, _url, _headers, _body} ->
          collect_post_requests(expected, acc)
      after
        1_000 ->
          flunk("timeout waiting for #{expected} post requests, got=#{length(acc)}")
      end
    end
  end
end
