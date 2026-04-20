defmodule RotatingSecretsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias RotatingSecrets.Secret
  # credo:disable-for-next-line Credo.Check.Readability.AliasAs
  alias RotatingSecrets.Source.Memory, as: MemorySource

  setup do
    start_supervised!(RotatingSecrets.Supervisor)
    :ok
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp unique_name, do: :"facade_test_#{System.unique_integer([:positive])}"  # unique test atom, not user-controlled

  defp register_memory_secret(name, value \\ "test-secret") do
    {:ok, pid} =
      RotatingSecrets.register(name,
        source: MemorySource,
        source_opts: [name: name, initial_value: value]
      )

    pid
  end

  # ---------------------------------------------------------------------------
  # register/2
  # ---------------------------------------------------------------------------

  describe "register/2" do
    test "starts a secret process and returns {:ok, pid}" do
      name = unique_name()
      assert {:ok, pid} = RotatingSecrets.register(name,
        source: MemorySource,
        source_opts: [name: name, initial_value: "val"]
      )
      assert Process.alive?(pid)
    end

    test "returns {:error, _} when source init fails" do
      name = unique_name()
      assert {:error, _} = RotatingSecrets.register(name,
        source: MemorySource,
        source_opts: [name: name]
      )
    end
  end

  # ---------------------------------------------------------------------------
  # deregister/1
  # ---------------------------------------------------------------------------

  describe "deregister/1" do
    test "terminates a registered secret and returns :ok" do
      name = unique_name()
      pid = register_memory_secret(name)
      ref = Process.monitor(pid)

      assert :ok = RotatingSecrets.deregister(name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = RotatingSecrets.deregister(:nonexistent_facade_secret)
    end
  end

  # ---------------------------------------------------------------------------
  # current/1
  # ---------------------------------------------------------------------------

  describe "current/1" do
    test "returns {:ok, %Secret{}} for a registered secret" do
      name = unique_name()
      register_memory_secret(name, "my-password")

      assert {:ok, %Secret{} = secret} = RotatingSecrets.current(name)
      assert Secret.expose(secret) == "my-password"
    end

    test "exits when called with an unregistered name" do
      assert catch_exit(RotatingSecrets.current(:nonexistent_current_test))
    end
  end

  # ---------------------------------------------------------------------------
  # current!/1
  # ---------------------------------------------------------------------------

  describe "current!/1" do
    test "returns the secret directly on success" do
      name = unique_name()
      register_memory_secret(name, "bang-secret")

      secret = RotatingSecrets.current!(name)
      assert %Secret{} = secret
      assert Secret.expose(secret) == "bang-secret"
    end

    test "exits when called with an unregistered name" do
      assert catch_exit(RotatingSecrets.current!(:nonexistent_bang_test))
    end

    test "raises when secret is in expired state" do
      name = unique_name()
      pid = register_memory_secret(name, "val")

      :sys.replace_state(pid, fn state -> %{state | lifecycle: :expired} end)

      assert_raise RuntimeError, ~r/unavailable/, fn ->
        RotatingSecrets.current!(name)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # with_secret/2
  # ---------------------------------------------------------------------------

  describe "with_secret/2" do
    test "passes the secret to the function and returns {:ok, result}" do
      name = unique_name()
      register_memory_secret(name, "with-secret-val")

      assert {:ok, "WITH-SECRET-VAL"} =
               RotatingSecrets.with_secret(name, fn secret ->
                 secret |> Secret.expose() |> String.upcase()
               end)
    end

    test "exits when the secret is not registered" do
      assert catch_exit(RotatingSecrets.with_secret(:nonexistent_with_test, fn _s -> :ok end))
    end

    test "returns {:error, _} when secret is in expired state" do
      name = unique_name()
      pid = register_memory_secret(name, "val")

      :sys.replace_state(pid, fn state -> %{state | lifecycle: :expired} end)

      assert {:error, :expired} =
               RotatingSecrets.with_secret(name, fn s -> Secret.expose(s) end)
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe/1 and unsubscribe/2
  # ---------------------------------------------------------------------------

  describe "subscribe/1" do
    test "returns {:ok, sub_ref} where sub_ref is a reference" do
      name = unique_name()
      register_memory_secret(name)

      assert {:ok, sub_ref} = RotatingSecrets.subscribe(name)
      assert is_reference(sub_ref)
    end
  end

  describe "unsubscribe/2" do
    test "returns :ok after unsubscribing" do
      name = unique_name()
      register_memory_secret(name)

      {:ok, sub_ref} = RotatingSecrets.subscribe(name)
      assert :ok = RotatingSecrets.unsubscribe(name, sub_ref)
    end

    test "returns :ok even with unknown sub_ref" do
      name = unique_name()
      register_memory_secret(name)

      assert :ok = RotatingSecrets.unsubscribe(name, make_ref())
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe + rotate end-to-end
  # ---------------------------------------------------------------------------

  describe "subscribe + rotation" do
    test "subscriber receives notification after Memory.update" do
      name = unique_name()
      register_memory_secret(name, "v1")

      {:ok, sub_ref} = RotatingSecrets.subscribe(name)

      MemorySource.update(name, "v2")

      assert_receive {:rotating_secret_rotated, ^sub_ref, ^name, _version}, 500

      {:ok, secret} = RotatingSecrets.current(name)
      assert Secret.expose(secret) == "v2"
    end
  end

  # ---------------------------------------------------------------------------
  # cluster_status/1
  # ---------------------------------------------------------------------------

  describe "cluster_status/1" do
    test "returns empty map when no other nodes are connected" do
      name = unique_name()
      register_memory_secret(name)

      assert %{} = RotatingSecrets.cluster_status(name)
    end
  end
end
