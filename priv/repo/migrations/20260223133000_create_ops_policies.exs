defmodule Men.Repo.Migrations.CreateOpsPolicies do
  use Ecto.Migration

  def up do
    execute("CREATE SEQUENCE IF NOT EXISTS ops_policy_version_seq AS BIGINT START 1;")

    create table(:ops_policies) do
      add :tenant, :string, null: false
      add :env, :string, null: false
      add :scope, :string, null: false
      add :policy_key, :string, null: false
      add :value, :map, null: false
      add :policy_version, :bigint, null: false
      add :updated_by, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute(
      "ALTER TABLE ops_policies ALTER COLUMN policy_version SET DEFAULT nextval('ops_policy_version_seq');"
    )

    create(
      unique_index(
        :ops_policies,
        [:tenant, :env, :scope, :policy_key],
        where: "deleted_at IS NULL",
        name: :ops_policies_active_key_uniq
      )
    )

    create(index(:ops_policies, [:policy_version], name: :ops_policies_version_idx))

    create(
      index(:ops_policies, [:tenant, :env, :scope], name: :ops_policies_tenant_env_scope_idx)
    )
  end

  def down do
    drop(index(:ops_policies, [:tenant, :env, :scope], name: :ops_policies_tenant_env_scope_idx))
    drop(index(:ops_policies, [:policy_version], name: :ops_policies_version_idx))

    drop(
      unique_index(
        :ops_policies,
        [:tenant, :env, :scope, :policy_key],
        where: "deleted_at IS NULL",
        name: :ops_policies_active_key_uniq
      )
    )

    drop(table(:ops_policies))
    execute("DROP SEQUENCE IF EXISTS ops_policy_version_seq;")
  end
end
