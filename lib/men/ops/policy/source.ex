defmodule Men.Ops.Policy.Source do
  @moduledoc """
  策略源抽象：支持按键读取、版本查询与增量拉取。
  """

  @type identity :: %{
          required(:tenant) => String.t(),
          required(:env) => String.t(),
          required(:scope) => String.t(),
          required(:policy_key) => String.t()
        }

  @type policy_record :: %{
          required(:tenant) => String.t(),
          required(:env) => String.t(),
          required(:scope) => String.t(),
          required(:policy_key) => String.t(),
          required(:value) => map(),
          required(:policy_version) => non_neg_integer(),
          required(:updated_at) => DateTime.t(),
          required(:updated_by) => String.t()
        }

  @callback fetch(identity()) :: {:ok, policy_record()} | {:error, term()}
  @callback get_version() :: {:ok, non_neg_integer()} | {:error, term()}
  @callback list_since_version(non_neg_integer()) :: {:ok, [policy_record()]} | {:error, term()}
  @callback upsert(identity(), map(), keyword()) :: {:ok, policy_record()} | {:error, term()}
end
