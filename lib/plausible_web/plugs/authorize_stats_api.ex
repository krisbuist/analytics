defmodule PlausibleWeb.AuthorizeStatsApiPlug do
  import Plug.Conn
  use Plausible.Repo
  alias Plausible.Auth
  alias Plausible.Sites
  alias PlausibleWeb.Api.Helpers, as: H

  def init(options) do
    options
  end

  def call(conn, _opts) do
    with {:ok, token} <- get_bearer_token(conn),
         {:ok, api_key} <- Auth.find_api_key(token),
         :ok <- check_api_key_rate_limit(api_key),
         {:ok, site} <- verify_access(api_key, conn.params["site_id"]) do
      Plausible.OpenTelemetry.add_site_attributes(site)
      assign(conn, :site, site)
    else
      {:error, :missing_api_key} ->
        H.unauthorized(
          conn,
          "Missing API key. Please use a valid Plausible API key as a Bearer Token."
        )

      {:error, :missing_site_id} ->
        H.bad_request(
          conn,
          "Missing site ID. Please provide the required site_id parameter with your request."
        )

      {:error, :rate_limit, limit} ->
        H.too_many_requests(
          conn,
          "Too many API requests. Your API key is limited to #{limit} requests per hour. Please contact us to request more capacity."
        )

      {:error, :invalid_api_key} ->
        H.unauthorized(
          conn,
          "Invalid API key or site ID. Please make sure you're using a valid API key with access to the site you've requested."
        )

      {:error, :upgrade_required} ->
        H.payment_required(
          conn,
          "#{Plausible.Billing.Feature.StatsAPI.display_name()} is part of the Plausible Business plan. To get access to this feature, please upgrade your account."
        )

      {:error, :site_locked} ->
        H.payment_required(
          conn,
          "This Plausible site is locked due to missing active subscription. In order to access it, the site owner should subscribe to a suitable plan"
        )
    end
  end

  defp verify_access(_api_key, nil), do: {:error, :missing_site_id}

  defp verify_access(api_key, site_id) do
    domain_based_search =
      from s in Plausible.Site, where: s.domain == ^site_id or s.domain_changed_from == ^site_id

    case Repo.one(domain_based_search) do
      %Plausible.Site{} = site ->
        is_member? = Sites.is_member?(api_key.user_id, site)
        is_super_admin? = Plausible.Auth.is_super_admin?(api_key.user_id)

        cond do
          is_super_admin? ->
            {:ok, site}

          Sites.locked?(site) ->
            {:error, :site_locked}

          Plausible.Billing.Feature.StatsAPI.check_availability(api_key.user) !== :ok ->
            {:error, :upgrade_required}

          is_member? ->
            {:ok, site}

          true ->
            {:error, :invalid_api_key}
        end

      nil ->
        {:error, :invalid_api_key}
    end
  end

  defp get_bearer_token(conn) do
    authorization_header =
      Plug.Conn.get_req_header(conn, "authorization")
      |> List.first()

    case authorization_header do
      "Bearer " <> token -> {:ok, String.trim(token)}
      _ -> {:error, :missing_api_key}
    end
  end

  @one_hour 60 * 60 * 1000
  defp check_api_key_rate_limit(api_key) do
    case Hammer.check_rate("api_request:#{api_key.id}", @one_hour, api_key.hourly_request_limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limit, api_key.hourly_request_limit}
    end
  end
end
