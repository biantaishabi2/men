defmodule Mix.Tasks.Men.CutoverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    original = Application.get_env(:men, :zcpg_cutover, [])

    on_exit(fn ->
      Application.put_env(:men, :zcpg_cutover, original)
    end)

    :ok
  end

  test "flag 命令可更新配置" do
    Mix.Task.reenable("men.cutover")

    capture_io(fn ->
      Mix.Tasks.Men.Cutover.run(["--enable"])
    end)

    assert Keyword.get(Application.get_env(:men, :zcpg_cutover, []), :enabled) == true
  end

  test "非法参数返回失败" do
    Mix.Task.reenable("men.cutover")

    assert_raise Mix.Error, fn ->
      capture_io(fn ->
        Mix.Tasks.Men.Cutover.run(["status"])
      end)
    end
  end
end
