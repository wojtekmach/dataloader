defmodule Dataloader.EctoTest do
  use ExUnit.Case, async: true

  alias Dataloader.{User, Post}
  import Ecto.Query
  alias Dataloader.TestRepo, as: Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    test_pid = self()

    source =
      Dataloader.Ecto.new(
        Repo,
        query: &query(&1, &2, test_pid)
      )

    loader =
      Dataloader.new()
      |> Dataloader.add_source(Test, source)

    {:ok, loader: loader}
  end

  defp query(Post, _, test_pid) do
    send(test_pid, :querying)

    Post
    |> where([p], is_nil(p.deleted_at))
    |> order_by(asc: :id)
  end

  defp query(queryable, _args, test_pid) do
    send(test_pid, :querying)
    queryable
  end

  test "basic loading works", %{loader: loader} do
    users = [
      %{username: "Ben Wilson"}
    ]

    Repo.insert_all(User, users)

    users = Repo.all(User)
    user_ids = users |> Enum.map(& &1.id)

    loader =
      loader
      |> Dataloader.load_many(Test, User, user_ids)
      |> Dataloader.run()

    loaded_users =
      loader
      |> Dataloader.get_many(Test, User, user_ids)

    assert_receive(:querying)

    assert length(loaded_users) == 1
    assert users == loaded_users

    # loading again doesn't query again due to caching
    loader
    |> Dataloader.load_many(Test, User, user_ids)
    |> Dataloader.run()

    refute_receive(:querying)
  end

  test "fancier loading works", %{loader: loader} do
    user = %User{username: "Ben"} |> Repo.insert!()

    rows = [
      %{user_id: user.id, title: "foo"},
      %{user_id: user.id, title: "bar", deleted_at: DateTime.utc_now()}
    ]

    {_, [%{id: post_id} | _]} = Repo.insert_all(Post, rows, returning: [:id])

    loader =
      loader
      |> Dataloader.load_many(Test, Post, [[id: post_id], [title: "bar"]])
      |> Dataloader.run()

    assert_receive(:querying)

    assert %Post{} = Dataloader.get(loader, Test, Post, id: post_id)
    # this shouldn't be loaded because the `query` fun should filter it out,
    # because it's deleted
    refute Dataloader.get(loader, Test, Post, title: "bar")
  end

  test "association loading works", %{loader: loader} do
    user = %User{username: "Ben Wilson"} |> Repo.insert!()

    posts =
      [
        %Post{user_id: user.id},
        %Post{user_id: user.id}
      ]
      |> Enum.map(&Repo.insert!/1)

    loader =
      loader
      |> Dataloader.load(Test, :posts, user)
      |> Dataloader.run()

    loaded_posts =
      loader
      |> Dataloader.get(Test, :posts, user)

    assert posts == loaded_posts
    assert_receive(:querying)

    # loading again doesn't query again due to caching
    loader
    |> Dataloader.load(Test, :posts, user)
    |> Dataloader.run()

    refute_receive(:querying)
  end

  test "loading something from cache doesn't change the loader", %{loader: loader} do
    user = %User{username: "Ben Wilson"} |> Repo.insert!()

    _ =
      [
        %Post{user_id: user.id},
        %Post{user_id: user.id}
      ]
      |> Enum.map(&Repo.insert!/1)

    round1_loader =
      loader
      |> Dataloader.load(Test, :posts, user)
      |> Dataloader.run()

    assert ^round1_loader =
             round1_loader
             |> Dataloader.load(Test, :posts, user)
             |> Dataloader.run()

    assert loader != round1_loader
  end

  test "cache can be warmed", %{loader: loader} do
    user = %User{username: "Ben Wilson"} |> Repo.insert!()

    posts =
      [
        %Post{user_id: user.id},
        %Post{user_id: user.id}
      ]
      |> Enum.map(&Repo.insert!/1)

    loader = Dataloader.put(loader, Test, :posts, user, posts)

    loader
    |> Dataloader.load(Test, :posts, user)
    |> Dataloader.run()

    refute_receive(:querying)
  end

  test "ecto not association loaded struct doesn't warm cache", %{loader: loader} do
    user = %User{username: "Ben Wilson"} |> Repo.insert!()

    posts =
      [
        %Post{user_id: user.id},
        %Post{user_id: user.id}
      ]
      |> Enum.map(&Repo.insert!/1)

    loader = Dataloader.put(loader, Test, :posts, user, user.posts)

    loader =
      loader
      |> Dataloader.load(Test, :posts, user)
      |> Dataloader.run()

    loaded_posts =
      loader
      |> Dataloader.get(Test, :posts, user)

    assert posts == loaded_posts
    assert_receive(:querying)
  end
end
