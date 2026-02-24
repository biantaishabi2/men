defmodule Men.Ops.Policy.Source.DB do
  @moduledoc """
  Ops Policy 的 DB 真源实现。
  """

  @behaviour Men.Ops.Policy.Source

  import Ecto.Query

  alias Men.Repo

  defmodule Record do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "ops_policies" do
      field :tenant, :string
      field :env, :string
      field :scope, :string
      field :policy_key, :string
      field :value, :map
      field :policy_version, :integer
      field :updated_by, :string
      field :updated_at, :utc_datetime_usec
      field :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  @type identity :: Men.Ops.Policy.Source.identity()
  @type policy_record :: Men.Ops.Policy.Source.policy_record()

  @impl true
  def fetch(identity) do
    with {:ok, normalized} <- normalize_identity(identity) do
      query =
        from(p in Record,
          where:
            p.tenant == ^normalized.tenant and p.env == ^normalized.env and
              p.scope == ^normalized.scope and p.policy_key == ^normalized.policy_key and
              is_nil(p.deleted_at)
        )

      case Repo.one(query) do
        nil -> {:error, :not_found}
        record -> {:ok, to_record(record)}
      end
    end
  rescue
    error -> {:error, {:db_error, error}}
  end

  @impl true
  def get_version do
    query =
      from(p in Record,
        where: is_nil(p.deleted_at),
        select: max(p.policy_version)
      )

    {:ok, Repo.one(query) || 0}
  rescue
    error -> {:error, {:db_error, error}}
  end

  @impl true
  def list_since_version(version) when is_integer(version) and version >= 0 do
    query =
      from(p in Record,
        where: is_nil(p.deleted_at) and p.policy_version > ^version,
        order_by: [asc: p.policy_version]
      )

    {:ok, Repo.all(query) |> Enum.map(&to_record/1)}
  rescue
    error -> {:error, {:db_error, error}}
  end

  def list_since_version(_), do: {:error, :invalid_version}

  @impl true
  @spec upsert(identity() | keyword() | map(), map(), keyword()) ::
          {:ok, policy_record()} | {:error, term()}
  def upsert(identity, value, opts \\ [])

  def upsert(identity, value, opts) when is_map(value) do
    with {:ok, normalized} <- normalize_identity(identity),
         updated_by when is_binary(updated_by) and updated_by != "" <-
           Keyword.get(opts, :updated_by, "system") do
      sql = """
      INSERT INTO ops_policies
      (tenant, env, scope, policy_key, value, policy_version, updated_by, inserted_at, updated_at, deleted_at)
      VALUES ($1, $2, $3, $4, $5, nextval('ops_policy_version_seq'), $6, timezone('utc', now()), timezone('utc', now()), NULL)
      ON CONFLICT (tenant, env, scope, policy_key) WHERE deleted_at IS NULL
      DO UPDATE
      SET value = EXCLUDED.value,
          policy_version = nextval('ops_policy_version_seq'),
          updated_by = EXCLUDED.updated_by,
          updated_at = timezone('utc', now()),
          deleted_at = NULL
      RETURNING tenant, env, scope, policy_key, value, policy_version, updated_by, updated_at
      """

      case Ecto.Adapters.SQL.query(Repo, sql, [
             normalized.tenant,
             normalized.env,
             normalized.scope,
             normalized.policy_key,
             value,
             updated_by
           ]) do
        {:ok, %{rows: [row]}} ->
          {:ok, row_to_record(row)}

        {:ok, _} ->
          {:error, :empty_result}

        {:error, reason} ->
          {:error, {:db_error, reason}}
      end
    else
      _ -> {:error, :invalid_updated_by}
    end
  end

  def upsert(_identity, _value, _opts), do: {:error, :invalid_value}

  @impl true
  @spec delete(identity() | keyword() | map(), keyword()) ::
          {:ok, policy_record()} | {:error, term()}
  def delete(identity, opts \\ []) do
    with {:ok, normalized} <- normalize_identity(identity),
         updated_by when is_binary(updated_by) and updated_by != "" <-
           Keyword.get(opts, :updated_by, "system") do
      sql = """
      UPDATE ops_policies
      SET deleted_at = timezone('utc', now()),
          policy_version = nextval('ops_policy_version_seq'),
          updated_by = $5,
          updated_at = timezone('utc', now())
      WHERE tenant = $1
        AND env = $2
        AND scope = $3
        AND policy_key = $4
        AND deleted_at IS NULL
      RETURNING tenant, env, scope, policy_key, value, policy_version, updated_by, updated_at
      """

      case Ecto.Adapters.SQL.query(Repo, sql, [
             normalized.tenant,
             normalized.env,
             normalized.scope,
             normalized.policy_key,
             updated_by
           ]) do
        {:ok, %{rows: [row]}} ->
          {:ok, row_to_record(row)}

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:ok, _} ->
          {:error, :empty_result}

        {:error, reason} ->
          {:error, {:db_error, reason}}
      end
    else
      _ -> {:error, :invalid_updated_by}
    end
  end

  defp normalize_identity(%{tenant: tenant, env: env, scope: scope, policy_key: key}) do
    do_normalize_identity(tenant, env, scope, key)
  end

  defp normalize_identity(identity) when is_list(identity) do
    normalize_identity(Map.new(identity))
  end

  defp normalize_identity(_), do: {:error, :invalid_identity}

  defp do_normalize_identity(tenant, env, scope, key)
       when is_binary(tenant) and tenant != "" and is_binary(env) and env != "" and
              is_binary(scope) and scope != "" and is_binary(key) and key != "" do
    {:ok, %{tenant: tenant, env: env, scope: scope, policy_key: key}}
  end

  defp do_normalize_identity(_, _, _, _), do: {:error, :invalid_identity}

  defp to_record(%Record{} = record) do
    %{
      tenant: record.tenant,
      env: record.env,
      scope: record.scope,
      policy_key: record.policy_key,
      value: record.value || %{},
      policy_version: record.policy_version,
      updated_by: record.updated_by,
      updated_at: record.updated_at
    }
  end

  defp row_to_record([
         tenant,
         env,
         scope,
         policy_key,
         value,
         policy_version,
         updated_by,
         updated_at
       ]) do
    %{
      tenant: tenant,
      env: env,
      scope: scope,
      policy_key: policy_key,
      value: value || %{},
      policy_version: policy_version,
      updated_by: updated_by,
      updated_at: updated_at
    }
  end
end
