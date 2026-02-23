defmodule Men.Ops.Policy.Source.Config do
  @moduledoc """
  config 默认策略源（fail-closed 兜底）。
  """

  @behaviour Men.Ops.Policy.Source

  @type identity :: Men.Ops.Policy.Source.identity()

  @impl true
  def fetch(identity) do
    with {:ok, normalized} <- normalize_identity(identity),
         {:ok, value} <- do_fetch(normalized) do
      {:ok,
       %{
         tenant: normalized.tenant,
         env: normalized.env,
         scope: normalized.scope,
         policy_key: normalized.policy_key,
         value: value,
         policy_version: 0,
         updated_by: "config_default",
         updated_at: DateTime.utc_now()
       }}
    end
  end

  @impl true
  def get_version, do: {:ok, 0}

  @impl true
  def list_since_version(_version), do: {:ok, []}

  @impl true
  def upsert(_identity, _value, _opts), do: {:error, :readonly_source}

  defp do_fetch(identity) do
    policies = Application.get_env(:men, :ops_policy, []) |> Keyword.get(:default_policies, %{})

    key = {identity.tenant, identity.env, identity.scope, identity.policy_key}

    case Map.get(policies, key) do
      value when is_map(value) ->
        {:ok, value}

      _ ->
        {:error, :not_found}
    end
  end

  defp normalize_identity(%{tenant: tenant, env: env, scope: scope, policy_key: key}) do
    if Enum.all?([tenant, env, scope, key], &(is_binary(&1) and &1 != "")) do
      {:ok, %{tenant: tenant, env: env, scope: scope, policy_key: key}}
    else
      {:error, :invalid_identity}
    end
  end

  defp normalize_identity(identity) when is_list(identity),
    do: normalize_identity(Map.new(identity))

  defp normalize_identity(_), do: {:error, :invalid_identity}
end
