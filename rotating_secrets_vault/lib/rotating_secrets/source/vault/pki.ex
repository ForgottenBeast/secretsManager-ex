defmodule RotatingSecrets.Source.Vault.PKI do
  @moduledoc """
  Vault PKI secrets engine source for `RotatingSecrets`.

  Issues X.509 certificates via `PUT /v1/{mount}/issue/{role}`. The issued
  certificate, private key, and CA chain are returned as JSON-encoded material.
  The certificate's `notAfter` field drives TTL-based refresh scheduling.

  ## Options

    * `:address` — Vault server address, e.g. `"http://127.0.0.1:8200"`. Required.
    * `:mount` — PKI secrets engine mount path, e.g. `"pki"`. Required.
    * `:role` — PKI role name, e.g. `"web-server"`. Required.
    * `:token` — Vault token for authentication. Required.
    * `:common_name` — Certificate common name, e.g. `"example.com"`. Required.
    * `:alt_names` — list of subject alternative names. Optional, default `[]`.
    * `:ttl` — requested certificate TTL, e.g. `"72h"`. Optional.
    * `:ip_sans` — list of IP SANs. Optional.
    * `:uri_sans` — list of URI SANs. Optional.
    * `:namespace` — Vault Enterprise namespace (non-empty binary). Optional.
    * `:revoke_on_terminate` — revoke certificate on Registry shutdown. Default `false`.
    * `:req_options` — keyword list merged into `Req.new/1`. For test injection only.
  """

  @behaviour RotatingSecrets.Source

  alias RotatingSecrets.Source.Vault.HTTP

  @impl RotatingSecrets.Source
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    with {:ok, address} <- fetch_required_string(opts, :address),
         {:ok, mount} <- fetch_required_string(opts, :mount),
         {:ok, role} <- fetch_required_string(opts, :role),
         {:ok, token} <- fetch_required_string(opts, :token),
         {:ok, common_name} <- fetch_required_string(opts, :common_name),
         :ok <- validate_namespace(Keyword.get(opts, :namespace)) do
      state = %{
        address: address,
        mount: mount,
        role: role,
        token: token,
        common_name: common_name,
        alt_names: Keyword.get(opts, :alt_names, []),
        ttl: Keyword.get(opts, :ttl),
        ip_sans: Keyword.get(opts, :ip_sans, []),
        uri_sans: Keyword.get(opts, :uri_sans, []),
        namespace: Keyword.get(opts, :namespace),
        revoke_on_terminate: Keyword.get(opts, :revoke_on_terminate, false),
        req_options: Keyword.get(opts, :req_options, []),
        serial_number: nil
      }

      {:ok, Map.put(state, :base_req, HTTP.base_request(Map.to_list(state)))}
    end
  end

  @impl RotatingSecrets.Source
  @spec load(map()) :: {:ok, binary(), map(), map()} | {:error, atom(), map()}
  def load(state) do
    body = build_issue_body(state)

    case HTTP.put(state.base_req, "/v1/#{state.mount}/issue/#{state.role}", body) do
      {:ok, response_body} ->
        data = response_body["data"]
        cert_pem = data["certificate"]
        key_pem = data["private_key"]
        ca_pem = data["issuing_ca"]
        ca_chain = data["ca_chain"] || []
        serial_number = data["serial_number"]

        [{_, der, _}] = :public_key.pem_decode(cert_pem)
        cert = :public_key.pkix_decode_cert(der, :otp)
        not_after = get_not_after(cert) |> parse_asn1_time()
        ttl_seconds = DateTime.diff(not_after, DateTime.utc_now())

        material =
          Jason.encode!(%{
            "certificate" => cert_pem,
            "private_key" => key_pem,
            "issuing_ca" => ca_pem,
            "ca_chain" => ca_chain
          })

        meta = %{
          version: nil,
          ttl_seconds: ttl_seconds,
          issued_at: DateTime.utc_now(),
          serial_number: serial_number,
          expiry: not_after,
          sans: extract_sans(cert),
          certificate_fingerprint: Base.encode16(:crypto.hash(:sha256, der), case: :lower)
        }

        new_state = %{state | serial_number: serial_number}
        {:ok, material, meta, new_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl RotatingSecrets.Source
  def terminate(state) do
    if state.revoke_on_terminate && state.serial_number do
      try do
        req = Req.merge(state.base_req, receive_timeout: 2000)
        HTTP.put(req, "/v1/#{state.mount}/revoke", %{"serial_number" => state.serial_number})
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  @impl RotatingSecrets.Source
  def subscribe_changes(_state), do: :not_supported

  @impl RotatingSecrets.Source
  def handle_change_notification(_msg, _state), do: :ignored

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_issue_body(state) do
    body = %{"common_name" => state.common_name}

    body
    |> maybe_put("alt_names", join_list(state.alt_names))
    |> maybe_put("ttl", state.ttl)
    |> maybe_put("ip_sans", join_list(state.ip_sans))
    |> maybe_put("uri_sans", join_list(state.uri_sans))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp join_list([]), do: nil
  defp join_list(list), do: Enum.join(list, ",")

  # OTPCertificate record layout (index 0 = tag, 1 = tbsCertificate, ...)
  # OTPTBSCertificate: index 0 = :OTPTBSCertificate, ..., 5 = validity
  # Validity: {:Validity, notBefore, notAfter}
  defp get_not_after(cert) do
    tbs = elem(cert, 1)
    validity = elem(tbs, 5)
    # validity = {:Validity, notBefore, notAfter}
    elem(validity, 2)
  end

  defp parse_asn1_time({:utcTime, charlist}) do
    # Format: YYMMDDHHMMSSZ
    # Years 00-49 = 2000-2049, 50-99 = 1950-1999
    str = List.to_string(charlist)
    yy = String.slice(str, 0, 2) |> String.to_integer()
    year = if yy >= 50, do: 1900 + yy, else: 2000 + yy
    mm = String.slice(str, 2, 2) |> String.to_integer()
    dd = String.slice(str, 4, 2) |> String.to_integer()
    hh = String.slice(str, 6, 2) |> String.to_integer()
    min = String.slice(str, 8, 2) |> String.to_integer()
    ss = String.slice(str, 10, 2) |> String.to_integer()
    {:ok, dt} = DateTime.new(Date.new!(year, mm, dd), Time.new!(hh, min, ss), "Etc/UTC")
    dt
  end

  defp parse_asn1_time({:generalTime, charlist}) do
    # Format: YYYYMMDDHHMMSSZ
    str = List.to_string(charlist)
    year = String.slice(str, 0, 4) |> String.to_integer()
    mm = String.slice(str, 4, 2) |> String.to_integer()
    dd = String.slice(str, 6, 2) |> String.to_integer()
    hh = String.slice(str, 8, 2) |> String.to_integer()
    min = String.slice(str, 10, 2) |> String.to_integer()
    ss = String.slice(str, 12, 2) |> String.to_integer()
    {:ok, dt} = DateTime.new(Date.new!(year, mm, dd), Time.new!(hh, min, ss), "Etc/UTC")
    dt
  end

  defp extract_sans(cert) do
    try do
      extensions = cert |> elem(1) |> elem(7)
      extract_san_extension(extensions)
    rescue
      _ -> []
    end
  end

  defp extract_san_extension(extensions) when is_list(extensions) do
    # OID for Subject Alternative Name is {2, 5, 29, 17}
    san_oid = {2, 5, 29, 17}

    case Enum.find(extensions, fn ext -> elem(ext, 0) == :Extension && elem(ext, 1) == san_oid end) do
      nil ->
        []

      ext ->
        # ext = {:Extension, oid, critical, value}
        # value is a list of GeneralName tuples
        value = elem(ext, 3)
        parse_general_names(value)
    end
  end

  defp extract_san_extension(_), do: []

  defp parse_general_names(names) when is_list(names) do
    Enum.flat_map(names, fn
      {:dNSName, name} -> [List.to_string(name)]
      {:iPAddress, ip_bytes} -> [format_ip(ip_bytes)]
      {:uniformResourceIdentifier, uri} -> [List.to_string(uri)]
      _ -> []
    end)
  end

  defp parse_general_names(_), do: []

  defp format_ip(bytes) when is_binary(bytes) and byte_size(bytes) == 4 do
    bytes |> :binary.bin_to_list() |> Enum.join(".")
  end

  defp format_ip(bytes) when is_binary(bytes) and byte_size(bytes) == 16 do
    bytes
    |> :binary.bin_to_list()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", fn [a, b] -> Integer.to_string(a * 256 + b, 16) end)
  end

  defp format_ip(_), do: ""

  defp fetch_required_string(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_namespace(nil), do: :ok
  defp validate_namespace(ns) when is_binary(ns) and byte_size(ns) > 0, do: :ok
  defp validate_namespace(_), do: {:error, {:invalid_option, :namespace}}
end
