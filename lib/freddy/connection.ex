defmodule Freddy.Connection do
  @moduledoc """
  Stable AMQP connection.
  """
  alias Freddy.Connection.ChannelManager
  alias Freddy.Utils.Backoff
  alias Freddy.Utils.MultikeyMap
  alias Freddy.Adapter
  alias Freddy.Core.Channel

  @params_docs [
    adapter: """
    Freddy adapter. Can be any module, but also can be passed as an alias `:amqp` or `:sandox`
    """,
    backoff: """
    Backoff can be specified either as a 1-arity function that accepts
    attempt number (starting from `1`) , or as a tuple `{module, function, arguments}`
    (in this case attempt number will appended to the arguments) or as a
    backoff config.
    """,
    host: "The hostname of the broker (defaults to \"localhost\")",
    port: "The port the broker is listening on (defaults to `5672`)",
    username: "The name of a user registered with the broker (defaults to \"guest\")",
    password: "The password of user (defaults to \"guest\")",
    virtual_host: "The name of a virtual host in the broker (defaults to \"/\")",
    channel_max: "The channel_max handshake parameter (defaults to `0`)",
    frame_max: "The frame_max handshake parameter (defaults to `0`)",
    heartbeat: "The hearbeat interval in seconds (defaults to `10`)",
    connection_timeout: "The connection timeout in milliseconds (defaults to `5000`)",
    ssl_options: "Enable SSL by setting the location to cert files (defaults to `none`)",
    client_properties:
      "A list of extra client properties to be sent to the server, defaults to `[]`",
    socket_options: """
    Extra socket options. These are appended to the default options.
    See `:inet.setopts/2` and `:gen_tcp.connect/4` for descriptions of the available options.
    """
  ]

  @options_doc @params_docs
               |> Enum.map(fn {param, value} -> "  * `:#{param}` - #{value}" end)
               |> Enum.join("\n")

  @type connection :: GenServer.server()
  @type connection_spec :: connection_params | connection_uri
  @type connection_uri :: String.t()
  @typedoc """
  Keyword list of AMQP connection params.

  ## Options

  #{@options_doc}
  """
  @type connection_params :: [
          adapter: atom,
          backoff: Backoff.spec(),
          host: String.t(),
          port: integer,
          username: String.t(),
          password: String.t(),
          virtual_host: String.t(),
          channel_max: non_neg_integer,
          frame_max: non_neg_integer,
          heartbeat: non_neg_integer,
          connection_timeout: timeout,
          client_properties: [{String.t(), atom, String.t()}],
          ssl_options: term,
          socket_options: [any],
          auth_mechanisms: [function]
        ]

  @typedoc @params_docs[:adapter]

  @type adapter :: :amqp | :sandbox | module

  use Connection

  @default_timeout 30_000

  @doc """
  Start a new AMQP connection.

  `connection_opts` can be supplied either as keyword list - in this case
  connection will be established to one RabbitMQ server - or as a list of
  keyword list - in this case `Freddy.Connection` will first attempt to
  establish connection to the host specified by the first element of the list,
  then to the second, if the first one has failed, and so on.

  ## Options

  #{@options_doc}

  ## Backoff configuration

  Backoff config specifies how intervals should be calculated between reconnection attempts.

  ### Available options

    * `:type` - should be `:constant`, `:normal` or `:jitter`. When type is set to `:constant`,
       interval between all reconnection attempts is the same, defined by option `:start`. When
       type is set to `:normal`, intervals between reconnection attempts are incremented exponentially.
       When type is set to `:jitter`, intervals are also incremented exponentially, but with
       randomness or jitter (see `:backoff.rand_increment/2`). Defaults to `:jitter`.
    * `:start` - an initial backoff interval in milliseconds. Defaults to `1000`.
    * `:max` - specifies maximum backoff interval in milliseconds. Defaults to `10000`.
  """
  @spec start_link(connection_spec | [connection_spec, ...], GenServer.options()) ::
          GenServer.on_start()
  def start_link(connection_opts \\ [], gen_server_opts \\ []) do
    Connection.start_link(__MODULE__, connection_opts, gen_server_opts)
  end

  @doc """
  Closes an AMQP connection. This will cause process to reconnect.
  """
  @spec close(connection, timeout) :: :ok | {:error, reason :: term}
  def close(connection, timeout \\ @default_timeout) do
    Connection.call(connection, {:close, timeout})
  end

  @doc """
  Stops the connection process
  """
  def stop(connection) do
    GenServer.stop(connection)
  end

  @doc """
  Opens a new AMQP channel
  """
  @spec open_channel(connection, timeout) :: {:ok, Channel.t()} | {:error, reason :: term}
  def open_channel(connection, timeout \\ @default_timeout) do
    timeout_at = System.monotonic_time(:millisecond) + timeout
    Connection.call(connection, {:open_channel, timeout_at}, timeout + 1000)
  end

  @doc """
  Determines if the specified channel exists on this connection or not
  """
  @spec has_channel?(connection, Channel.t(), timeout) :: boolean()
  def has_channel?(connection, %Channel{} = chan, timeout \\ @default_timeout) do
    Connection.call(connection, {:has_channel?, chan}, timeout)
  end

  @doc """
  Returns underlying connection PID
  """
  @spec get_connection(connection) :: {:ok, Freddy.Adapter.connection()} | {:error, :closed}
  def get_connection(connection) do
    Connection.call(connection, :get)
  end

  @doc false
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # Connection callbacks

  import Record

  defrecordp :state,
    adapter: nil,
    hosts: nil,
    connection: nil,
    channel_manager_pid: nil,
    pending_open_channels: %{},
    channels: MultikeyMap.new(),
    backoff: Backoff.new([])

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {adapter, opts} = Keyword.pop(opts, :adapter, :amqp)
    {backoff, opts} = Keyword.pop(opts, :backoff, [])

    state =
      state(
        hosts: prepare_connection_hosts(opts),
        adapter: Adapter.get(adapter),
        backoff: Backoff.new(backoff)
      )

    {:connect, :init, state}
  end

  defp prepare_connection_hosts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      [opts]
    else
      if Enum.all?(opts, &Keyword.keyword?/1) do
        opts
      else
        raise "Connection options must be supplied either as keywords or as a list of keywords"
      end
    end
  end

  @impl true
  def connect(
    _info,
    state(
      channel_manager_pid: channel_manager_pid,
      adapter: adapter,
      hosts: hosts,
      backoff: backoff
    ) = state
  ) do
    case do_connect(hosts, adapter, nil) do
      {:ok, connection} ->
        adapter.link_connection(connection)
        if channel_manager_pid do
          # unlink the channel manager so its exit signal doesn't kill us in the process
          Process.unlink(channel_manager_pid)
          # and then kill it, we don't care what channels its opening that connection is likely
          # long dead.
          Process.exit(channel_manager_pid, :kill)
        end

        case ChannelManager.start_link(self(), adapter, connection) do
          {:ok, channel_manager_pid} ->
            new_backoff = Backoff.succeed(backoff)

            {:ok, state(state,
              channel_manager_pid: channel_manager_pid,
              pending_open_channels: %{},
              connection: connection,
              backoff: new_backoff
            )}
        end

      _error ->
        {interval, new_backoff} = Backoff.fail(backoff)
        {:backoff, interval, state(state, backoff: new_backoff)}
    end
  end

  defp do_connect([], _adapter, acc) do
    acc
  end

  defp do_connect([host_opts | rest], adapter, _acc) do
    case adapter.open_connection(host_opts) do
      {:ok, connection} ->
        {:ok, connection}

      error ->
        do_connect(rest, adapter, error)
    end
  end

  @impl true
  def disconnect(_info, state) do
    {:connect, :reconnect, state(state, connection: nil)}
  end

  @impl true
  def handle_call(_, _, state(connection: nil) = state) do
    {:reply, {:error, :closed}, state}
  end

  @impl true
  def handle_call(:get, _from, state(connection: connection) = state) do
    {:reply, {:ok, connection}, state}
  end

  @impl true
  def handle_call(
    {:open_channel, timeout_at},
    from,
    state(
      pending_open_channels: pending_open_channels,
      channel_manager_pid: channel_manager_pid
    ) = state
  ) do
    :ok = ChannelManager.open_channel(channel_manager_pid, from, timeout_at)
    pending_open_channels = Map.put(pending_open_channels, from, timeout_at)
    {:noreply, state(state, pending_open_channels: pending_open_channels)}
  end

  @impl true
  def handle_call(
    {:has_channel?, %Channel{chan: pid}},
    _from,
    state(
      channels: channels
    ) = state
  ) do
    {:reply, MultikeyMap.has_key?(channels, pid), state}
  end

  @impl true
  def handle_call(
    {:close, timeout},
    _from,
    state(adapter: adapter, connection: connection) = state
  ) do
    {:disconnect, :close, close_connection(adapter, connection, timeout), state}
  end

  @impl true
  def handle_info(
    {:"$channel_manager", {:open_channel_resp, {from, _ref} = sender, result}},
    state(
      pending_open_channels: pending_open_channels,
      channels: channels
    ) = state
  ) do
    now = System.monotonic_time(:millisecond)
    case result do
      {:ok, %Channel{chan: pid} = chan} ->
        case Map.pop(pending_open_channels, sender) do
          {nil, pending_open_channels} ->
            # we don't have proof that this actually belonged to anyone, close it
            Channel.close(chan)
            {:noreply, state(state, pending_open_channels: pending_open_channels)}

          {timeout_at, pending_open_channels} ->
            state = state(state, pending_open_channels: pending_open_channels)

            if now < timeout_at do
              monitor_ref = Process.monitor(from)
              channel_ref = Channel.monitor(chan)
              channels = MultikeyMap.put(channels, [monitor_ref, channel_ref, pid], chan)

              GenServer.reply(sender, {:ok, chan})
              {:noreply, state(state, channels: channels)}
            else
              Channel.close(chan)
              # let it timeout on the sender side
              {:noreply, state}
            end
        end

      {:error, :timeout} ->
        # could not open connection in time, just timeout normally
        {:noreply, state}

      {:error, _reason} = reply ->
        GenServer.reply(sender, reply)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
    {:EXIT, connection, {:shutdown, :normal}},
    state(connection: connection) = state
  ) do
    {:noreply, state(state, connection: nil)}
  end

  @impl true
  def handle_info({:EXIT, connection, reason}, state(connection: connection) = state) do
    {:disconnect, {:error, reason}, state}
  end

  @impl true
  def handle_info(
    {:EXIT, channel_manager_pid, {:shutdown, :normal}},
    state(channel_manager_pid: channel_manager_pid) = state
  ) do
    {:noreply, state(state, channel_manager_pid: nil)}
  end

  @impl true
  def handle_info(
    {:EXIT, channel_manager_pid, {:shutdown, :normal}},
    state(
      channel_manager_pid: channel_manager_pid,
      adapter: adapter,
      connection: connection
    ) = state
  ) when not is_nil(connection) do
    case ChannelManager.start_link(self(), adapter, connection) do
      {:ok, channel_manager_pid} ->
        state =
          state(
            state,
            pending_open_channels: %{},
            channel_manager_pid: channel_manager_pid
          )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state(channels: channels) = state) do
    case MultikeyMap.pop(channels, pid) do
      {nil, ^channels} ->
        {:stop, reason, state}

      {_channel, new_channels} ->
        {:noreply, state(state, channels: new_channels)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, _, _pid, _reason}, state) do
    {:noreply, close_channel(ref, state)}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state(adapter: adapter, connection: connection)) do
    if connection do
      adapter.close_connection(connection)
    end
  end

  defp close_channel(ref, state(channels: channels) = state) do
    case MultikeyMap.pop(channels, ref) do
      {nil, ^channels} ->
        state

      {channel, new_channels} ->
        Channel.close(channel)
        state(state, channels: new_channels)
    end
  end

  defp close_connection(adapter, connection, timeout) do
    try do
      adapter.close_connection(connection)

      receive do
        {:EXIT, ^connection, _reason} -> :ok
      after
        timeout ->
          Process.exit(connection, :kill)

          receive do
            {:EXIT, ^connection, _reason} -> :ok
          end
      end
    catch
      :exit, {:noproc, _} -> {:error, :closed}
    end
  end
end
