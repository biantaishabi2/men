defmodule Men.Gateway.Runtime.ProtocolTest do
  use ExUnit.Case, async: true

  alias Men.Gateway.Runtime.Protocol

  defmodule MockStore do
    def write(node) do
      if pid = Application.get_env(:men, :runtime_protocol_test_pid) do
        send(pid, {:store_write, node})
      end

      :ok
    end
  end

  setup do
    original_flag = Application.get_env(:men, :runtime_protocol_v2)
    Application.put_env(:men, :runtime_protocol_v2, true)
    Application.put_env(:men, :runtime_protocol_test_pid, self())

    on_exit(fn ->
      if is_nil(original_flag) do
        Application.delete_env(:men, :runtime_protocol_v2)
      else
        Application.put_env(:men, :runtime_protocol_v2, original_flag)
      end

      Application.delete_env(:men, :runtime_protocol_test_pid)
    end)

    :ok
  end

  test "research 最小字段稳定性" do
    input = %{"id" => "n1", "mode" => "research"}

    assert {:ok, validated} = Protocol.validate_node(input)
    assert validated.status == "pending"
    assert validated.version == 1
    assert validated.meta == %{}

    assert {:ok, encoded} = Protocol.encode(input)
    assert encoded["status"] == "pending"
    assert encoded["version"] == 1
    assert encoded["meta"] == %{}

    assert {:ok, decoded} = Protocol.decode(input)
    assert decoded.status == "pending"
    assert decoded.version == 1
    assert decoded.meta == %{}
  end

  test "plan 合法专有字段" do
    input = %{
      "id" => "n2",
      "mode" => "plan",
      "requires_all" => ["a"],
      "options" => %{"x" => 1},
      "confidence" => 0.8
    }

    assert {:ok, validated} = Protocol.validate_node(input)
    assert validated.status == "draft"
    assert validated.requires_all == ["a"]
    assert validated.options == %{"x" => 1}
    assert validated.confidence == 0.8
  end

  test "plan 非法字段拒绝" do
    input = %{"id" => "n3", "mode" => "plan", "extra_key" => "boom"}

    assert {:error, [err]} = Protocol.validate_node(input)
    assert err.code == :unknown_field
    assert err.path == ["extra_key"]
  end

  test "execute 缺失 status 返回 required 且无副作用" do
    input = %{"id" => "n4", "mode" => "execute"}

    assert {:error, [err]} = Protocol.validate_node(input)
    assert err.code == :required
    assert err.path == [:status]

    maybe_write_store(input)
    refute_receive {:store_write, _}
  end

  test "显式 status=nil 拒绝" do
    input = %{"id" => "n5", "mode" => "research", "status" => nil}

    assert {:error, [err]} = Protocol.validate_node(input)
    assert err.code == :invalid_value
    assert err.path == [:status]

    maybe_write_store(input)
    refute_receive {:store_write, _}
  end

  test "legacy 字段映射" do
    input = %{
      "id" => "n6",
      "node_type" => "plan",
      "state" => "draft",
      "created_at" => "2026-02-22T00:00:00Z"
    }

    assert {:ok, decoded} = Protocol.decode(input)
    assert decoded.mode == "plan"
    assert decoded.status == "draft"
    assert decoded.inserted_at == "2026-02-22T00:00:00Z"
  end

  test "edge 协议字段与未知字段校验" do
    valid = %{"from" => "n1", "to" => "n2", "type" => "depends_on", "meta" => nil}

    assert {:ok, edge} = Protocol.validate_edge(valid)
    assert edge.meta == %{}

    invalid = Map.put(valid, "extra", true)
    assert {:error, [err]} = Protocol.validate_edge(invalid)
    assert err.code == :unknown_field
    assert err.path == ["extra"]
  end

  test "validate/encode 受 feature flag 控制" do
    Application.put_env(:men, :runtime_protocol_v2, false)

    passthrough = %{"id" => "n7", "mode" => "execute"}
    assert {:ok, ^passthrough} = Protocol.validate_node(passthrough)
    assert {:ok, ^passthrough} = Protocol.encode(passthrough)

    assert {:error, [err]} = Protocol.decode(passthrough)
    assert err.code == :required
    assert err.path == [:status]
  end

  defp maybe_write_store(node_payload) do
    case Protocol.validate_node(node_payload) do
      {:ok, node} -> MockStore.write(node)
      {:error, _} -> :ok
    end
  end
end
