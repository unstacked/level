defmodule Level.Posts.CreatePost do
  @moduledoc false

  alias Ecto.Multi
  alias Level.Events
  alias Level.Files
  alias Level.Groups
  alias Level.Mentions
  alias Level.Notifications
  alias Level.Posts
  alias Level.Repo
  alias Level.Schemas.Group
  alias Level.Schemas.Post
  alias Level.Schemas.PostLocator
  alias Level.Schemas.PostLog
  alias Level.Schemas.SpaceBot
  alias Level.Schemas.SpaceUser
  alias Level.TaggedGroups
  alias Level.WebPush
  alias LevelWeb.Router.Helpers

  # TODO: make this more specific
  @type result :: {:ok, map()} | {:error, any(), any(), map()}

  @doc """
  Creates a new post.
  """
  @spec perform(SpaceUser.t(), Group.t(), map()) :: result()
  def perform(%SpaceUser{} = author, %Group{} = group, params) do
    Multi.new()
    |> insert_post(author, params)
    |> save_locator(params)
    |> set_primary_group(group)
    |> detect_tagged_groups(author)
    |> record_mentions(author)
    |> attach_files(author, params)
    |> log(author)
    |> Repo.transaction()
    |> after_user_post(author)
  end

  @spec perform(SpaceUser.t(), map()) :: result()
  def perform(%SpaceUser{} = author, params) do
    Multi.new()
    |> insert_post(author, params)
    |> save_locator(params)
    |> detect_tagged_groups(author)
    |> record_mentions(author)
    |> attach_files(author, params)
    |> log(author)
    |> Repo.transaction()
    |> after_user_post(author)
  end

  @spec perform(SpaceBot.t(), map()) :: result()
  def perform(%SpaceBot{} = author, params) do
    Multi.new()
    |> insert_post(author, params)
    |> save_locator(params)
    |> detect_tagged_groups(author)
    |> record_mentions(author)
    |> attach_files(author, params)
    |> log(author)
    |> Repo.transaction()
    |> after_bot_post(author)
  end

  # Internal

  defp insert_post(multi, %SpaceUser{} = author, params) do
    params_with_relations =
      params
      |> Map.put(:space_id, author.space_id)
      |> Map.put(:space_user_id, author.id)

    Multi.insert(multi, :post, Post.user_changeset(%Post{}, params_with_relations))
  end

  defp insert_post(multi, %SpaceBot{} = author, params) do
    params_with_relations =
      params
      |> Map.put(:space_id, author.space_id)
      |> Map.put(:space_bot_id, author.id)

    Multi.insert(multi, :post, Post.bot_changeset(%Post{}, params_with_relations))
  end

  defp save_locator(multi, %{locator: params}) do
    # TODO: validate that the author is allowed to use the scope
    Multi.run(multi, :locator, fn %{post: post} ->
      params = Map.merge(params, %{space_id: post.space_id, post_id: post.id})

      %PostLocator{}
      |> PostLocator.create_changeset(params)
      |> Repo.insert()
    end)
  end

  defp save_locator(multi, _), do: multi

  defp set_primary_group(multi, group) do
    Multi.run(multi, :primary_group, fn %{post: post} ->
      _ = Posts.publish_to_group(post, group)

      {:ok, group}
    end)
  end

  defp detect_tagged_groups(multi, author) do
    Multi.run(multi, :tagged_groups, fn %{post: post} = result ->
      groups =
        author
        |> TaggedGroups.get_tagged_groups(post.body)
        |> Enum.reject(fn group ->
          result[:primary_group] && result[:primary_group].id == group.id
        end)
        |> Enum.map(fn group ->
          _ = Posts.publish_to_group(post, group)

          group
        end)

      {:ok, groups}
    end)
  end

  defp record_mentions(multi, author) do
    Multi.run(multi, :mentions, fn %{post: post} ->
      Mentions.record(author, post)
    end)
  end

  defp attach_files(multi, author, %{file_ids: file_ids}) do
    Multi.run(multi, :files, fn %{post: post} ->
      files = Files.get_files(author, file_ids)
      Posts.attach_files(post, files)
    end)
  end

  defp attach_files(multi, _, _) do
    Multi.run(multi, :files, fn _ -> {:ok, []} end)
  end

  defp log(multi, author) do
    Multi.run(multi, :log, fn %{post: post} ->
      PostLog.post_created(post, author)
    end)
  end

  defp after_user_post({:ok, result}, author) do
    _ = Posts.subscribe(author, [result.post])
    _ = subscribe_mentioned_users(result.post, result)
    _ = subscribe_mentioned_groups(result.post, result)

    result
    |> gather_groups()
    |> Enum.each(fn group ->
      _ = subscribe_watchers(result.post, group)
    end)

    _ = send_push_notifications(result, author)
    _ = send_events(result.post)

    {:ok, result}
  end

  defp after_user_post(err, _), do: err

  defp gather_groups(%{primary_group: primary_group, tagged_groups: tagged_groups}) do
    [primary_group | tagged_groups] |> Enum.uniq_by(fn group -> group.id end)
  end

  defp gather_groups(%{tagged_groups: tagged_groups}) do
    tagged_groups |> Enum.uniq_by(fn group -> group.id end)
  end

  defp subscribe_mentioned_users(post, %{mentions: %{space_users: mentioned_users}}) do
    Enum.each(mentioned_users, fn mentioned_user ->
      _ = Posts.mark_as_unread(mentioned_user, [post])
      _ = Events.user_mentioned(mentioned_user.id, post)
      _ = Notifications.record_post_created(mentioned_user, post)
    end)
  end

  defp subscribe_mentioned_groups(post, %{mentions: %{groups: mentioned_groups}}) do
    Enum.each(mentioned_groups, fn mentioned_group ->
      {:ok, group_users} = Groups.list_all_memberships(mentioned_group)
      group_users = Repo.preload(group_users, :space_user)

      Enum.each(group_users, fn group_user ->
        _ = Posts.mark_as_unread(group_user.space_user, [post])
      end)
    end)
  end

  defp subscribe_watchers(post, group) do
    {:ok, watching_group_users} = Groups.list_all_watchers(group)

    space_users =
      watching_group_users
      |> Repo.preload(:space_user)
      |> Enum.map(fn group_user -> group_user.space_user end)

    Enum.each(space_users, fn space_user ->
      _ = Posts.mark_as_unread(space_user, [post])
    end)
  end

  defp after_bot_post({:ok, result}, author) do
    _ = subscribe_mentioned_users(result.post, result)
    _ = subscribe_mentioned_groups(result.post, result)

    result
    |> gather_groups()
    |> Enum.each(fn group ->
      _ = subscribe_watchers(result.post, group)
    end)

    _ = send_push_notifications(result, author)
    _ = send_events(result.post)

    {:ok, result}
  end

  defp after_bot_post(err, _), do: err

  defp send_push_notifications(
         %{post: %Post{is_urgent: true} = post, mentions: %{space_users: mentioned_users}},
         author
       ) do
    payload = build_push_payload(post, author)

    mentioned_users
    |> Enum.each(fn %SpaceUser{user_id: user_id} ->
      WebPush.send_web_push(user_id, payload)
    end)
  end

  defp send_push_notifications(_, _), do: true

  defp build_push_payload(post, author) do
    post = Repo.preload(post, :space)
    body = "@#{author.handle} posted an urgent message"
    url = Helpers.main_path(LevelWeb.Endpoint, :index, [post.space.slug, "posts", post.id])

    %WebPush.Payload{
      title: post.space.name,
      body: body,
      tag: nil,
      require_interaction: true,
      url: url
    }
  end

  defp send_events(post) do
    {:ok, space_user_ids} = Posts.get_accessor_ids(post)
    _ = Events.post_created(space_user_ids, post)
  end
end
