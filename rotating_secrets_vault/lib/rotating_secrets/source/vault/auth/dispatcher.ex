defmodule RotatingSecrets.Source.Vault.Auth.Dispatcher do
  @moduledoc false

  alias RotatingSecrets.Source.Vault.Auth.JwtSvid
  alias RotatingSecrets.Source.Vault.Auth.Oidc
  alias RotatingSecrets.Source.Vault.Auth.ZitadelPrivateKeyJwt

  @spec init(term(), Req.Request.t()) :: {:ok, term()} | {:error, term()}
  def init(nil, _req), do: {:ok, nil}
  def init({:jwt_svid, opts}, req), do: wrap(JwtSvid.init(opts, req), :jwt_svid)
  def init({:oidc, opts}, req), do: wrap(Oidc.init(opts, req), :oidc)
  def init({:zitadel_private_key_jwt, opts}, req), do: wrap(ZitadelPrivateKeyJwt.init(opts, req), :zitadel_private_key_jwt)

  @spec ensure_fresh(term(), Req.Request.t()) :: {:ok, Req.Request.t(), term()} | {:error, term()}
  def ensure_fresh(nil, req), do: {:ok, req, nil}
  def ensure_fresh({:jwt_svid, s}, req), do: rewrap(JwtSvid.ensure_fresh(s, req), :jwt_svid)
  def ensure_fresh({:oidc, s}, req), do: rewrap(Oidc.ensure_fresh(s, req), :oidc)
  def ensure_fresh({:zitadel_private_key_jwt, s}, req), do: rewrap(ZitadelPrivateKeyJwt.ensure_fresh(s, req), :zitadel_private_key_jwt)

  defp wrap({:ok, state}, tag), do: {:ok, {tag, state}}
  defp wrap({:error, _} = err, _), do: err

  defp rewrap({:ok, req, state}, tag), do: {:ok, req, {tag, state}}
  defp rewrap({:error, _} = err, _), do: err
end
