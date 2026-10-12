Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule HoocoohMine do
  @moduledoc false

  @my_project "Hoocooh Miniapp"
  @base_url "https://hoocooh-miner-roan.vercel.app"

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    if accounts == [] do
      red("File data.txt is empty, please add your initData entries")
      System.halt(1)
    end

    proxies = load_lines("proxy.txt")
    settings = load_settings()

    loop(accounts, proxies, settings, 1)
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    accounts
    |> roster()
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> yellow("Running without proxy for this account")
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      try do
        process_account(entry, index + 1, proxy)
      rescue
        _error ->
          red("Account #{index + 1} was skipped after an error")
      end
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    countdown(sleep_seconds(settings), "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp roster(accounts) do
    Enum.map(accounts, fn line ->
      case identity(line) do
        {:ok, user_id, profile, username} ->
          %{user_id: user_id, init_data: line, profile: profile, username: username,
            device_id: device_for(user_id)}

        {:error, _reason} ->
          %{user_id: nil, init_data: line, profile: %{}, username: "", device_id: nil}
      end
    end)
  end

  defp process_account(%{user_id: nil}, label, _proxy) do
    red("Account #{label} initData has no readable user object")
  end

  defp process_account(entry, label, proxy) do
    case fetch_user(entry, proxy) do
      {:ok, user} ->
        name = display_name(entry.profile, user)
        balance = money(number(get(user, "balance", 0)))

        green("Signed in #{shorten(clean_text(name, "account"), "account", 20)} with #{balance} HOOCOOH")

        state = %{entry: entry, user: user}

        state
        |> process_mining(proxy)
        |> process_ads(proxy)
        |> process_spin(proxy)
        |> process_tasks(proxy)
        |> process_milestones(proxy)
        |> process_checkin(proxy)
        |> process_status(proxy)

      {:error, reason} ->
        red("Account #{label} initData refused with #{short_reason(reason)}")
    end
  end

  defp process_mining(state, proxy) do
    user = state.user
    interval = whole(get(user, "mineIntervalMs", 7_200_000), 7_200_000)
    last = whole(get(user, "lastMineCollectedAt", 0), 0)
    left = if last > 0, do: max(div(last + interval - now_ms(), 1000), 0), else: 0

    if left > 0 do
      yellow("Mining cycle is still running with #{format_duration(left)} left")
      state
    else
      case solve_captcha(state, proxy) do
        {:ok, puzzle} ->
          payload = %{"actionToken" => token_of(state.user, "mine")}
          payload = Map.put(payload, "captchaToken", puzzle)

          case call("/api/collect", payload, state, proxy) do
            {:ok, data} ->
              case number(get(data, "reward", 0)) do
                amount when amount > 0 ->
                  green("Mining cycle reward of #{money(amount)} HOOCOOH was claimed")

                _other ->
                  yellow("Mining cycle claim was accepted without a reward")
              end

            {:error, reason} ->
              yellow("Mining cycle claim was refused with #{short_reason(reason)}")
          end

        {:error, reason} ->
          yellow("Mining puzzle was refused with #{short_reason(reason)}")
      end

      refresh(state, proxy)
    end
  end

  defp process_ads(state, proxy) do
    case fetch_ads(state, proxy) do
      {:ok, data} ->
        ads = get(data, "ads", %{})
        left = whole(get(ads, "remainingToday", 0), 0)

        cond do
          left <= 0 ->
            green("Reward ad quota was used up at #{whole(get(ads, "watchedToday", 0), 0)} of #{whole(get(ads, "maxAds", 0), 0)}")
            state

          true ->
            green("Found #{plural(left, "reward ad")} to watch on this account")
            ad_loop(state, proxy, left, 0)

        end

      {:error, reason} ->
        yellow("Reward ad status was refused with #{short_reason(reason)}")
        state
    end
  end

  defp ad_loop(state, _proxy, left, _waits) when left <= 0, do: state

  defp ad_loop(state, proxy, left, waits) do
    case fetch_ads(state, proxy) do
      {:ok, data} ->
        ads = get(data, "ads", %{})
        ready = whole(get(ads, "remainingToday", 0), 0)
        next_reset = whole(get(ads, "nextResetMs", 0), 0)

        cond do
          ready <= 0 ->
            green("Reward ad quota was used up at #{whole(get(ads, "watchedToday", 0), 0)} of #{whole(get(ads, "maxAds", 0), 0)}")
            state

          next_reset > 0 and next_reset <= 90_000 and waits < 6 ->
            countdown(div(next_reset, 1000) + 1, "Waiting for the next reward ad slot")
            ad_loop(state, proxy, left, waits + 1)

          true ->
            watch_ad(state, proxy, ads)

            case refresh(state, proxy) do
              %{user: user} = next ->
                ad_loop(%{next | user: user}, proxy, left - 1, waits)

              other ->
                other
            end
        end

      {:error, reason} ->
        yellow("Reward ad status was refused with #{short_reason(reason)}")
        state
    end
  end

  defp watch_ad(state, proxy, ads) do
    token =
      case get(ads, "requiresCaptcha", false) do
        true -> captcha_or_nil(state, proxy)
        _other -> nil
      end

    if get(ads, "requiresCaptcha", false) == true and token == nil do
      yellow("Reward ad needs a puzzle and it could not be solved")
    else
      countdown(10, "Watching the reward ad")

      payload = %{"watchDurationMs" => 10_000}
      payload = if token, do: Map.put(payload, "captchaToken", token), else: payload

      case call("/api/ads", payload, state, proxy) do
        {:ok, data} ->
          case number(get(data, "reward", 0)) do
            amount when amount > 0 ->
              green("Reward ad #{whole(get(data, "adsWatchedToday", 0), 0)} claimed earning #{money(amount)} HOOCOOH")

            _other ->
              yellow("Reward ad was accepted without a confirmed reward")
          end

        {:error, reason} ->
          yellow("Reward ad claim was refused with #{short_reason(reason)}")
      end
    end
  end

  defp process_spin(state, proxy) do
    case fetch_ads(state, proxy) do
      {:ok, data} ->
        spin = get(data, "spin", %{})
        tickets = whole(get(spin, "tickets", 0), 0)

        state = spin_ticket_loop(state, proxy, whole(get(spin, "remainingToday", 0), 0), 0)

        case fetch_ads(state, proxy) do
          {:ok, fresh} ->
            ready = whole(get(get(fresh, "spin", %{}), "tickets", tickets), tickets)

            if ready > 0 do
              green("Found #{plural(ready, "spin ticket")} ready to spin")
              spin_loop(state, proxy, ready)
            else
              yellow("No spin ticket is ready on this account")
              state
            end

          {:error, _reason} ->
            state
        end

      {:error, reason} ->
        yellow("Spin status was refused with #{short_reason(reason)}")
        state
    end
  end

  defp spin_ticket_loop(state, _proxy, left, _waits) when left <= 0, do: state

  defp spin_ticket_loop(state, proxy, left, waits) do
    countdown(6, "Watching the spin ticket ad")

    payload = %{
      "action" => "spin_watch_ad",
      "watchDurationMs" => 6_000,
      "actionToken" => token_of(state.user, "spin_watch_ad")
    }

    case call("/api/ads", payload, state, proxy) do
      {:ok, data} ->
        if number(get(data, "ticketAdded", 0)) > 0 do
          green("Spin ticket #{whole(get(data, "spinAdsWatchedToday", 0), 0)} claimed, #{whole(get(data, "spinTickets", 0), 0)} ready")
          spin_ticket_loop(refresh(state, proxy), proxy, left - 1, waits)
        else
          yellow("Spin ticket claim was accepted without a ticket")
          state
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        cond do
          String.contains?(text, "LIMIT") or String.contains?(text, "USED") ->
            green("Spin ticket quota was used up for today")
            state

          waits < 6 ->
            countdown(90, "Waiting for the next spin ticket slot")
            spin_ticket_loop(state, proxy, left, waits + 1)

          true ->
            yellow("Spin ticket claim was refused with #{short_reason(reason)}")
            state
        end
    end
  end

  defp spin_loop(state, _proxy, left) when left <= 0, do: state

  defp spin_loop(state, proxy, left) do
    case call("/api/ads", %{"action" => "spin"}, state, proxy) do
      {:ok, data} ->
        case number(get(data, "reward", 0)) do
          amount when amount > 0 ->
            green("Lucky wheel earned #{money(amount)} HOOCOOH with #{whole(get(data, "spinTickets", 0), 0)} left")
            spin_loop(refresh(state, proxy), proxy, left - 1)

          _other ->
            yellow("Lucky wheel spin was accepted without a reward")
            state
        end

      {:error, reason} ->
        yellow("Lucky wheel spin was refused with #{short_reason(reason)}")
        state
    end
  end

  defp process_tasks(state, proxy) do
    case fetch_tasks(state, proxy) do
      {:ok, tasks} ->
        open = Enum.filter(tasks, fn task -> get(task, "isCompleted", false) != true end)

        cond do
          tasks == [] ->
            yellow("No account task is published on the server yet")
            state

          open == [] ->
            green("Every available account task was already completed")
            state

          true ->
            green("Found #{plural(length(open), "account task")} to process")
            Enum.each(open, fn task -> claim_task(state, proxy, task) end)
            refresh(state, proxy)
        end

      {:error, reason} ->
        yellow("Task list was refused with #{short_reason(reason)}")
        state
    end
  end

  defp claim_task(state, proxy, task) do
    id = get(task, "id", "")
    title = task_title(task)

    payload = %{
      "action" => "claim",
      "taskId" => id,
      "actionToken" => token_of(state.user, "complete_task")
    }

    case call("/api/tasks", payload, state, proxy) do
      {:ok, data} ->
        case number(get(data, "reward", 0)) do
          amount when amount > 0 ->
            green("Task #{title} claimed earning #{money(amount)} HOOCOOH")

          _other ->
            yellow("Task #{title} was accepted without a reward")
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        cond do
          String.contains?(text, "ALREADY") ->
            yellow("Task #{title} was already completed on this account")

          String.contains?(text, "JOIN") or String.contains?(text, "MEMBER") ->
            yellow("Task #{title} still needs a manual channel join")

          String.contains?(text, "VERIF") ->
            yellow("Task #{title} still needs verified completion")

          true ->
            yellow("Task #{title} was refused with #{short_reason(reason)}")
        end
    end

    :timer.sleep(900)
  end

  defp task_title(task) do
    shorten(clean_text(get(task, "title", ""), "task"), "task", 18)
  end

  defp process_milestones(state, proxy) do
    case call_get("/api/referral", state, proxy) do
      {:ok, data} ->
        ready =
          data
          |> get("milestones", [])
          |> case do
            list when is_list(list) -> list
            _other -> []
          end
          |> Enum.filter(fn item -> get(item, "canClaim", false) == true end)

        if ready == [] do
          green("No referral milestone is ready to claim yet")
          state
        else
          Enum.each(ready, fn item -> claim_milestone(state, proxy, item) end)
          state
        end

      {:error, reason} ->
        yellow("Milestones were refused with #{short_reason(reason)}")
        state
    end
  end

  defp claim_milestone(state, proxy, item) do
    id = whole(get(item, "id", 0), 0)
    payload = %{"action" => "claim_milestone", "milestoneId" => id}

    case call("/api/referral", payload, state, proxy) do
      {:ok, data} ->
        case number(get(data, "reward", 0)) do
          amount when amount > 0 ->
            green("Milestone #{id} claimed earning #{money(amount)} HOOCOOH")

          _other ->
            yellow("Milestone #{id} was accepted without a reward")
        end

      {:error, reason} ->
        yellow("Milestone #{id} was refused with #{short_reason(reason)}")
    end
  end

  defp process_checkin(state, proxy) do
    case captcha_or_nil(state, proxy) do
      nil ->
        yellow("Daily check in needs a puzzle and it could not be solved")
        state

      token ->
        payload = %{
          "actionToken" => token_of(state.user, "checkin"),
          "captchaToken" => token
        }

        case call("/api/checkin", payload, state, proxy) do
          {:ok, data} ->
            case number(get(data, "reward", 0)) do
              amount when amount > 0 ->
                green("Daily check in claimed earning #{money(amount)} HOOCOOH")

              _other ->
                yellow("Daily check in was accepted without a reward")
            end

          {:error, reason} ->
            yellow("Daily check in was refused with #{short_reason(reason)}")
        end

        refresh(state, proxy)
    end
  end

  defp process_status(state, proxy) do
    case refresh(state, proxy) do
      %{user: user} = next ->
        name = display_name(next.entry.profile, user)
        level = whole(get(user, "minerLevel", 0), 0)
        recruits = whole(get(user, "recruitsCount", 0), 0)

        green(
          "Map level #{level} with #{plural(recruits, "recruit")} for #{shorten(clean_text(name, "account"), "account", 20)}"
        )

        next

      other ->
        other
    end
  end

  defp refresh(state, proxy) do
    case fetch_user(state.entry, proxy) do
      {:ok, user} -> %{state | user: user}
      {:error, _reason} -> state
    end
  end

  defp captcha_or_nil(state, proxy) do
    case solve_captcha(state, proxy) do
      {:ok, token} -> token
      {:error, _reason} -> nil
    end
  end

  defp solve_captcha(state, proxy) do
    case call("/api/captcha", %{"action" => "create"}, state, proxy) do
      {:ok, data} ->
        challenge = get(data, "challengeId", "")
        target = whole(get(data, "targetX", 0), 0)

        if is_binary(challenge) and challenge != "" do
          verify_captcha(state, proxy, challenge, target)
        else
          {:error, "puzzle was not issued"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_captcha(state, proxy, challenge, target) do
    {elapsed, trail} = drag_trail(target)

    payload = %{
      "action" => "verify",
      "challengeId" => challenge,
      "solvedX" => target,
      "timeElapsed" => elapsed,
      "trail" => trail
    }

    case call("/api/captcha", payload, state, proxy) do
      {:ok, data} ->
        token = get(data, "captchaToken", "")

        if is_binary(token) and token != "" do
          {:ok, token}
        else
          {:error, "puzzle returned no token"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drag_trail(target) do
    steps = Enum.to_list(1..12)
    span = 1_100 + :rand.uniform(900)

    trail =
      Enum.map(steps, fn step ->
        frac = step / 12
        eased = target * (1 - :math.pow(1 - frac, 2.2))
        at = trunc(span * frac)

        %{"x" => round(eased), "y" => at, "t" => at}
      end)

    {span, trail}
  end

  defp fetch_user(entry, proxy) do
    path = "/api/user?start_param=" <> start_param(entry.init_data)

    case call_get(path, %{entry: entry, user: %{}}, proxy) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, "empty account snapshot"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_ads(state, proxy) do
    case call_get("/api/ads", state, proxy) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, "empty ad snapshot"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_tasks(state, proxy) do
    case call_get("/api/tasks", state, proxy) do
      {:ok, data} ->
        case get(data, "tasks", []) do
          list when is_list(list) -> {:ok, list}
          _other -> {:error, "empty task list"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_param(init_data) do
    case identity_of(init_data) do
      {:ok, user, _username} ->
        value = get(user, "id", "")
        if is_binary(value) or is_integer(value), do: "ref_" <> to_string(value), else: ""

      _other ->
        ""
    end
  end

  defp token_of(user, key) do
    case get(user, "actionTokens", %{}) do
      %{} = tokens -> get(tokens, key, "")
      _other -> ""
    end
  end

  defp call(path, payload, state, proxy) do
    case request(:post, path, payload, state, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_get(path, state, proxy) do
    case request(:get, path, %{}, state, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(body) do
    case body do
      %{"error" => error} -> {:error, error}
      %{} = data -> {:ok, data}
      _other -> {:ok, %{}}
    end
  end

  defp request(method, path, payload, state, proxy) do
    url = String.to_charlist(String.trim_trailing(@base_url, "/") <> path)
    {profile, auth} = proxy_setup(proxy)

    headers =
      [
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"*/*"},
        {~c"accept-language", ~c"en-US,en;q=0.9"},
        {~c"origin", String.to_charlist(@base_url)},
        {~c"referer", String.to_charlist(@base_url <> "/")},
        {~c"user-agent",
         ~c"Mozilla/5.0 (Linux; Android 13; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
      ] ++ session_headers(state)

    body = payload |> YuurisanJSON.encode()

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    dispatch(method, url, headers, body, options, profile)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp session_headers(state) do
    init_data = state.entry.init_data
    device = state.entry.device_id || ""

    [
      {~c"x-telegram-init-data", String.to_charlist(init_data)},
      {~c"x-device-id", String.to_charlist(device)}
    ]
  end

  defp dispatch(:get, url, headers, _body, options, profile) do
    handle(:httpc.request(:get, {url, headers}, options, [body_format: :binary], profile))
  end

  defp dispatch(:post, url, headers, body, options, profile) do
    handle(
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", body},
        options,
        [body_format: :binary],
        profile
      )
    )
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}})
       when status >= 200 and status < 300 do
    case YuurisanJSON.decode(response) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "unreadable response"}
    end
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}}) do
    case YuurisanJSON.decode(response) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, %{"message" => message}} -> {:error, message}
      {:ok, _value} -> {:error, "HTTP #{status}"}
      {:error, _reason} -> {:error, "HTTP #{status}"}
    end
  end

  defp handle({:error, reason}), do: {:error, reason}

  defp device_for(user_id) do
    store = load_store()

    case Map.get(store, user_id) do
      %{"device_id" => device} when is_binary(device) and device != "" ->
        device

      _entry ->
        device = new_device_id()
        entry = %{"device_id" => device}
        save_store(Map.put(store, user_id, entry))
        device
    end
  end

  defp new_device_id do
    suffix =
      :crypto.strong_rand_bytes(8)
      |> :binary.decode_unsigned()
      |> Integer.to_string(36)
      |> String.slice(0, 8)
      |> String.pad_leading(8, "0")

    "dev_" <> suffix <> "_" <> Integer.to_string(System.system_time(:millisecond), 36)
  end

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _other -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _other -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _other -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _other -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _other -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _other -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _other ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil
  defp proxy_for(proxies, index), do: Enum.at(proxies, rem(index, length(proxies)))

  defp load_lines(name) do
    case File.read(Path.join(__DIR__, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp load_store do
    case File.read(Path.join(__DIR__, "device.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, %{} = store} -> store
          _other -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp save_store(store) do
    File.write(Path.join(__DIR__, "device.json"), YuurisanJSON.encode_pretty(store))
  end

  defp load_settings do
    case File.read(Path.join(__DIR__, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _reason} -> default_settings()
        end

      {:error, _reason} ->
        settings = default_settings()
        File.write(Path.join(__DIR__, "config.json"), YuurisanJSON.encode_pretty(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _other -> 3600
    end
  end

  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp display_name(profile, user) do
    value = get(user, "firstName", "")

    cond do
      is_binary(value) and String.trim(value) != "" -> value
      true -> get(profile, "first_name", "account")
    end
  end

  defp clean_text(value, fallback) do
    text =
      value
      |> stringify()
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp short_reason(reason), do: shorten(clean_text(reason, "reason"), "reason", 26)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify({:failed_connect, _reason}), do: "no network connection"
  defp stringify({:timeout, _reason}), do: "the request timed out"
  defp stringify({:failed_connect, _reason, _host}), do: "no network connection"
  defp stringify(value), do: inspect(value)

  defp whole(value, _fallback) when is_integer(value), do: value
  defp whole(value, _fallback) when is_float(value), do: trunc(value)
  defp whole(_value, fallback), do: fallback

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: value
  defp number(_value), do: 0

  defp money(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp money(value), do: to_string(value)

  defp now_ms, do: System.system_time(:millisecond)

  defp identity(init_data) do
    with {:ok, profile, username} <- identity_of(init_data),
         id when not is_nil(id) <- get(profile, "id") do
      {:ok, "usr_" <> to_string(id), profile, username}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp identity_of(init_data) do
    with {:ok, params} <- parse_query(init_data),
         raw when is_binary(raw) <- Map.get(params, "user"),
         {:ok, user} <- YuurisanJSON.decode(URI.decode_www_form(raw)),
         id when not is_nil(id) <- get(user, "id") do
      {:ok, user, to_string(get(user, "username", ""))}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp parse_query(raw) do
    pairs =
      raw
      |> String.trim()
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    if Enum.any?(pairs, fn {key, _value} -> key == "hash" end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "initData has no hash"}
    end
  end

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    for signal <- [:sigterm, :sighup, :sigquit] do
      try do
        System.trap_signal(signal, handler)
      rescue
        _error -> :ok
      end
    end
  end

  defp shorten(value, fallback, limit) do
    text = value |> to_string() |> String.trim()

    case String.slice(text, 0, limit) do
      "" -> fallback
      short -> String.trim(short)
    end
  end

  defp fit(text) do
    value = to_string(text)
    if String.length(value) <= 63, do: value, else: String.slice(value, 0, 63)
  end

  defp plural(count, word) do
    if count == 1, do: "#{count} #{word}", else: "#{count} #{pluralize(word)}"
  end

  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") -> String.slice(word, 0, String.length(word) - 1) <> "ies"
      true -> word <> "s"
    end
  end

  defp countdown(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> fit(message) <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> fit(message) <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> fit(message) <> @reset)
end

HoocoohMine.run()
