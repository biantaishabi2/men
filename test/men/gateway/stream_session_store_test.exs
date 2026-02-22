defmodule Men.Gateway.StreamSessionStoreTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.StreamSessionStore

  setup do
    StreamSessionStore.__reset_for_test__()

    on_exit(fn ->
      StreamSessionStore.__reset_for_test__()
    end)

    :ok
  end

  test "put/get/delete 基本读写" do
    run_id = "run-card-1"

    assert :ok =
             StreamSessionStore.put(run_id, %{
               card_instance_id: "card-123",
               target: "dingtalk:u1",
               channel: "dingtalk"
             })

    assert {:ok, data} = StreamSessionStore.get(run_id)
    assert data.card_instance_id == "card-123"
    assert data.target == "dingtalk:u1"
    assert data.channel == "dingtalk"
    assert is_integer(data.updated_at_ms)

    assert :ok = StreamSessionStore.delete(run_id)
    assert :error = StreamSessionStore.get(run_id)
  end

  test "cleanup_older_than 清理过期条目" do
    assert :ok =
             StreamSessionStore.put("run-old", %{
               card_instance_id: "card-old",
               target: "dingtalk:u2",
               channel: "dingtalk",
               updated_at_ms: System.monotonic_time(:millisecond) - 10_000
             })

    assert :ok =
             StreamSessionStore.put("run-new", %{
               card_instance_id: "card-new",
               target: "dingtalk:u3",
               channel: "dingtalk",
               updated_at_ms: System.monotonic_time(:millisecond)
             })

    assert 1 == StreamSessionStore.cleanup_older_than(1_000)
    assert :error = StreamSessionStore.get("run-old")
    assert {:ok, _} = StreamSessionStore.get("run-new")
  end
end
