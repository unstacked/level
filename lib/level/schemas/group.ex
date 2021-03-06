defmodule Level.Schemas.Group do
  @moduledoc """
  The Group schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Level.Handles
  alias Level.Schemas.GroupUser
  alias Level.Schemas.Post
  alias Level.Schemas.PostGroup
  alias Level.Schemas.Space
  alias Level.Schemas.SpaceUser

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :state, :string, read_after_writes: true
    field :name, :string
    field :description, :string
    field :is_private, :boolean, default: false
    field :is_default, :boolean, default: false

    belongs_to :space, Space
    belongs_to :creator, SpaceUser
    has_many :group_users, GroupUser

    many_to_many :posts, Post, join_through: PostGroup

    timestamps()
  end

  @doc false
  def create_changeset(%__MODULE__{} = group, attrs) do
    group
    |> cast(attrs, [:creator_id, :space_id, :name, :description, :is_default, :is_private])
    |> validate_default()
    |> validate()
  end

  @doc false
  def update_changeset(%__MODULE__{} = group, attrs) do
    group
    |> cast(attrs, [:name, :description, :is_default])
    |> validate_default()
    |> validate()
  end

  defp validate_default(changeset) do
    validate_change(changeset, :is_default, fn _, is_default ->
      if is_default && get_field(changeset, :is_private) do
        [is_default: "cannot be enabled for private channels"]
      else
        []
      end
    end)
  end

  defp validate(changeset) do
    changeset
    |> validate_required([:name])
    |> Handles.validate_format(:name)
    |> unique_constraint(:name, name: :groups_unique_names_when_undeleted)
  end
end
