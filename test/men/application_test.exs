defmodule Men.ApplicationTest do
  use ExUnit.Case, async: true

  alias Men.Application, as: MenApplication

  test "gateway_scheduler_enabled 为 false 时仅保留 webhook 主链路" do
    assert [
             {Men.Gateway.SessionCoordinator, []},
             {Men.Gateway.DispatchServer, []}
           ] == MenApplication.gateway_children(true, false)

    assert [{Men.Gateway.DispatchServer, []}] == MenApplication.gateway_children(false, false)
  end

  test "gateway_scheduler_enabled 为 true 时挂载调度组件" do
    assert [
             {Men.Gateway.SessionCoordinator, []},
             {Men.Gateway.DispatchServer, []},
             {Men.Gateway.TaskDispatcher, []},
             {Men.Gateway.TaskScheduler, []}
           ] == MenApplication.gateway_children(true, true)

    assert [
             {Men.Gateway.DispatchServer, []},
             {Men.Gateway.TaskDispatcher, []},
             {Men.Gateway.TaskScheduler, []}
           ] == MenApplication.gateway_children(false, true)
  end
end
