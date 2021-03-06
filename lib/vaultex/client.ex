defmodule Vaultex.Client do

  require Logger
  use GenServer
  @version "v1"
  @cache Elixir.Vaultex

  def start_link() do
    GenServer.start_link(__MODULE__, %{progress: "starting"}, name: :vault)
  end

  def auth(creds) do
    GenServer.call(:vault, {:auth, creds})
  end

  def read(key) do
    GenServer.call(:vault, {:read, key})
  end

  def write(key) do
    GenServer.call(:vault, {:write, key, nil})
  end

  def write(key, data) do
    GenServer.call(:vault, {:write, key, data})
  end

  def encrypt(key, data) do
    GenServer.call(:vault, {:encrypt, key, data}, 10000)
  end

  def decrypt(key, data) do
    GenServer.call(:vault, {:decrypt, key, data}, 10000)
  end


# GenServer callbacks

  def init(state) do
    url = "#{get_env(:scheme)}://#{get_env(:host)}:#{get_env(:port)}/#{@version}/"
    {:ok, Map.merge(state, %{url: url})}
  end

  def handle_call({:auth, {:github, github_token}}, _from, state) do
    {:ok, req} = request(:post, "#{state.url}auth/github/login", %{token: github_token})
    Logger.debug("Got auth response: #{inspect req}")

    {:reply, {:ok, :authenticated}, Map.merge(state, %{token: req["auth"]["client_token"]})} 
  end

  # authenticate and save the access token in `token`
  def handle_call({:auth, {:user_id, user_id}}, _from, state) do
    app_id = Application.get_env(:vaultex, :app_id, nil)
    # TODO should call write here now that we have it
    {:ok, req} = request(:post, "#{state.url}auth/app-id/login", %{app_id: app_id, user_id: user_id})
    Logger.debug("Got auth reponse: #{inspect req}")

    {:reply, {:ok, :authenticated}, Map.merge(state, %{token: req["auth"]["client_token"]})}
  end

  def handle_call({:auth, {:token, token}}, _from, state) do
    Logger.debug("Merged in token auth")
	{:reply, {:ok, :authenticated}, Map.merge(state, %{token: token})}
  end


  def handle_call({:read, key}, _from, state) do
    data = case :ets.lookup(@cache, key) do
      [] ->
        {:ok, req} = request(:get, state.url <> key, nil, state.token)
        Logger.debug("Got reponse: #{inspect req}")
        :ets.insert(@cache, {key, req["data"]})
        case req["lease_duration"] do
          nil -> Logger.debug("No lease duration, no need to purge the key later")
          sec ->
            # notify me and delete the ETS cache
            Logger.debug("Purge the key from our internal cache after #{sec} seconds")
            :erlang.send_after(sec, __MODULE__, {:purge, key})
        end
        req["data"]
      [{_, stuff}] -> stuff
    end
    {:reply, {:ok, data}, state}
  end

  def handle_call({:write, key, data}, _from, state) do
    case request(:post, state.url <> key, data, state.token) do
      {:ok, req} -> 
        Logger.debug("Got reponse: #{inspect req}")
        {:reply, {:ok, req}, state}
      {:error, error} ->
        Logger.debug("Got error: #{inspect error}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:encrypt, key, data}, _from, state) do
    data1 = %{data | "plaintext" => data["plaintext"] |> Base.encode64 }
    res = request(:post, "#{state.url}transit/encrypt/#{key}", data1, state.token)
    {:reply, res, state}
  end

  def handle_call({:decrypt, key, data}, _from, state) do
    case request(:post, "#{state.url}transit/decrypt/#{key}", data, state.token) do
      {:ok, data} ->
        {:ok, plain} = data["plaintext"] |> Base.decode64
        data1 = %{data | "plaintext" => plain }
        {:reply, {:ok, data1}, state}
      error -> 
        {:reply, error, state}
    end
  end

  def handle_info({:purge, key}, state) do
    :ets.delete(@cache, key)
    Logger.info("Expired '#{key}' from cache")
    {:noreply, state}
  end


# internal helper functions

  defp request(method, url, params) do
    request(method, url, params, nil)
  end
  defp request(method, url, params, auth) do
    case get_content(method, url, params, auth) do
      {:ok, %HTTPoison.Response{status_code: 200, body: res}} ->
        Logger.debug("[body] #{inspect res}")
        case Poison.decode(res) do
          {:ok, json} ->
            {:ok, json}
          {:error, json_err} ->
            case res do
              "" -> {:ok, :no_data}
              _  -> {:error, json_err}
            end
        end
      {:ok, %HTTPoison.AsyncResponse{id: {:maybe_redirect, _status, headers, _client}}} ->
        case Enum.find(headers, fn ({key, val}) -> key == "Location" end) do
          nil ->
            {:error, "Error redirecting"}
          {_key, new_url} ->
            request(method, new_url, params, auth)
        end
      error -> error
    end
  end

  defp get_content(method, url, params, auth) do
    headers = case auth do
      nil -> [{"Content-Type", "application/json"}]
      token -> 
        [{"Content-Type", "application/json"}, {"X-Vault-Token", token}]
    end
    Logger.debug("[#{method}] #{url}")
    Logger.debug("[HEADER] #{inspect headers}")

    case Poison.encode(params) do
      # empty params
      {:ok, "null"} ->
        HTTPoison.request(method, url, "", headers, [follow_redirect: true, hackney: [ssl_options: [versions: [:"tlsv1.2"]]]])

      {:ok, json} ->
        Logger.debug("[JSON] #{inspect json}")
        HTTPoison.request(method, url, json, headers, [follow_redirect: true, hackney: [ssl_options: [versions: [:"tlsv1.2"]]]])

      error -> error
    end
  end

  defp get_env(:host) do
      System.get_env("VAULT_HOST") || Application.get_env(:vaultex, :host) || "localhost"
  end
  defp get_env(:port) do
      System.get_env("VAULT_PORT") || Application.get_env(:vaultex, :port) || 8200
  end
  defp get_env(:scheme) do
      System.get_env("VAULT_SCHEME") || Application.get_env(:vaultex, :scheme) || "http"
  end
end
