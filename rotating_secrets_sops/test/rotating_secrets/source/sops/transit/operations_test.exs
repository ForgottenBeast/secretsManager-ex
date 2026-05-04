defmodule RotatingSecrets.Source.Sops.Transit.OperationsTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias RotatingSecrets.Source.Sops.Transit.Operations

  defp random_key, do: :crypto.strong_rand_bytes(32)

  # ---------------------------------------------------------------------------
  # encrypt/2
  # ---------------------------------------------------------------------------

  describe "encrypt/2" do
    test "returns {:ok, ciphertext} for valid key and plaintext" do
      key = random_key()
      assert {:ok, ct} = Operations.encrypt(key, "hello")
      assert is_binary(ct)
    end

    test "ciphertext is at least 28 bytes (12 iv + 0 ct + 16 tag)" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "")
      assert byte_size(ct) >= 28
    end

    test "returns {:error, :invalid_key_length} for 31-byte key" do
      key = :crypto.strong_rand_bytes(31)
      assert {:error, :invalid_key_length} = Operations.encrypt(key, "data")
    end

    test "returns {:error, :invalid_key_length} for 33-byte key" do
      key = :crypto.strong_rand_bytes(33)
      assert {:error, :invalid_key_length} = Operations.encrypt(key, "data")
    end

    test "returns {:error, :invalid_key_length} for empty key" do
      assert {:error, :invalid_key_length} = Operations.encrypt("", "data")
    end

    test "different calls on same plaintext produce different ciphertext (IV randomness)" do
      key = random_key()
      {:ok, ct1} = Operations.encrypt(key, "same plaintext")
      {:ok, ct2} = Operations.encrypt(key, "same plaintext")
      refute ct1 == ct2
    end

    test "envelope starts with 12-byte IV (distinct from rest of ciphertext)" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "test")
      assert byte_size(ct) == 12 + byte_size("test") + 16
    end
  end

  # ---------------------------------------------------------------------------
  # decrypt/2
  # ---------------------------------------------------------------------------

  describe "decrypt/2" do
    test "roundtrip: decrypt(encrypt(plaintext)) == plaintext" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "secret value")
      assert {:ok, "secret value"} = Operations.decrypt(key, ct)
    end

    test "returns {:error, :decryption_failed} on tampered tag" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "data")
      # Flip last byte (tag)
      ct_size = byte_size(ct)
      <<prefix::binary-size(ct_size - 1), last_byte>> = ct
      tampered = prefix <> <<Bitwise.bxor(last_byte, 0xFF)>>
      assert {:error, :decryption_failed} = Operations.decrypt(key, tampered)
    end

    test "returns {:error, :decryption_failed} on tampered ciphertext body" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "longer plaintext to have a body")
      # Flip a byte in the middle (ciphertext body, after IV before tag)
      <<iv::binary-size(12), body::binary-size(1), rest::binary>> = ct
      tampered = iv <> <<Bitwise.bxor(:binary.first(body), 0xFF)>> <> rest
      assert {:error, :decryption_failed} = Operations.decrypt(key, tampered)
    end

    test "returns {:error, :invalid_ciphertext} for too-short ciphertext" do
      key = random_key()
      assert {:error, :invalid_ciphertext} = Operations.decrypt(key, <<1, 2, 3>>)
    end

    test "returns {:error, :invalid_ciphertext} for empty ciphertext" do
      key = random_key()
      assert {:error, :invalid_ciphertext} = Operations.decrypt(key, "")
    end

    test "returns {:error, :invalid_ciphertext} for ciphertext of exactly 27 bytes" do
      key = random_key()

      assert {:error, :invalid_ciphertext} =
               Operations.decrypt(key, :crypto.strong_rand_bytes(27))
    end

    test "returns {:error, :decryption_failed} when decrypting with wrong key" do
      key1 = random_key()
      key2 = random_key()
      {:ok, ct} = Operations.encrypt(key1, "secret")
      assert {:error, :decryption_failed} = Operations.decrypt(key2, ct)
    end

    test "returns {:error, :invalid_key_length} for 31-byte key" do
      {:ok, ct} = Operations.encrypt(random_key(), "data")
      bad_key = :crypto.strong_rand_bytes(31)
      assert {:error, :invalid_key_length} = Operations.decrypt(bad_key, ct)
    end

    test "returns {:error, :invalid_key_length} for 33-byte key" do
      {:ok, ct} = Operations.encrypt(random_key(), "data")
      bad_key = :crypto.strong_rand_bytes(33)
      assert {:error, :invalid_key_length} = Operations.decrypt(bad_key, ct)
    end

    test "empty plaintext roundtrips correctly" do
      key = random_key()
      {:ok, ct} = Operations.encrypt(key, "")
      assert {:ok, ""} = Operations.decrypt(key, ct)
    end

    test "binary plaintext (non-UTF8) roundtrips correctly" do
      key = random_key()
      plaintext = <<0, 1, 2, 255, 254, 253>>
      {:ok, ct} = Operations.encrypt(key, plaintext)
      assert {:ok, ^plaintext} = Operations.decrypt(key, ct)
    end
  end

  # ---------------------------------------------------------------------------
  # Property-based tests
  # ---------------------------------------------------------------------------

  describe "roundtrip property" do
    property "encrypt then decrypt recovers plaintext for any binary" do
      check all(
              plaintext <- binary(),
              key <- binary(length: 32)
            ) do
        {:ok, ct} = Operations.encrypt(key, plaintext)
        assert {:ok, ^plaintext} = Operations.decrypt(key, ct)
      end
    end
  end

  describe "IV uniqueness property" do
    property "two encryptions of same plaintext produce different ciphertext" do
      check all(
              plaintext <- binary(),
              key <- binary(length: 32)
            ) do
        {:ok, ct1} = Operations.encrypt(key, plaintext)
        {:ok, ct2} = Operations.encrypt(key, plaintext)
        # IVs are random 12-byte prefixes; collision probability is negligible
        assert ct1 != ct2
      end
    end
  end

  describe "wrong key length property" do
    property "any key length != 32 fails both encrypt and decrypt" do
      check all(
              size <- integer(0..64),
              size != 32,
              data <- binary()
            ) do
        bad_key = :crypto.strong_rand_bytes(size)
        assert {:error, :invalid_key_length} = Operations.encrypt(bad_key, data)
        assert {:error, :invalid_key_length} = Operations.decrypt(bad_key, data)
      end
    end
  end
end
