defmodule Freddy.Core.ActorTest do
  use ExUnit.Case, async: true

  defmodule ConnectionSlowProxy do
    # proxies calls to Freddy.Connection, but adds a delay before
    # opening a channel first time

    use GenServer

    def start_link(initial_delay) do
      GenServer.start_link(__MODULE__, initial_delay)
    end

    def init(initial_delay) do
      {:ok, connection} = Freddy.Connection.start_link(adapter: :sandbox)
      {:ok, %{connection: connection, delay: initial_delay}}
    end

    def handle_call(
      {:open_channel, _timeout_at},
      _from,
      %{connection: connection, delay: delay}
    ) do
      Process.sleep(delay)
      {:reply, Freddy.Connection.open_channel(connection), %{connection: connection, delay: 0}}
    end
  end

  defmodule TestActor do
    @behaviour Freddy.Core.Actor

    def start_link(connection) do
      Freddy.Core.Actor.start_link(__MODULE__, connection, false)
    end

    def connected?(actor) do
      GenServer.call(actor, :get)
    end

    def init(connected?) do
      {:ok, connected?}
    end

    def handle_connected(_meta, _connected?) do
      {:noreply, true}
    end

    def handle_disconnected(_reason, _connected?) do
      {:noreply, false}
    end

    def handle_call(:get, _from, connected?) do
      {:reply, connected?, connected?}
    end

    def handle_cast(_message, state) do
      {:noreply, state}
    end

    def handle_info(_message, state) do
      {:noreply, state}
    end

    def terminate(_reason, _state) do
      :ok
    end
  end

  test "retries if channel couldn't be opened" do
    {:ok, conn} = ConnectionSlowProxy.start_link(5000)
    {:ok, actor} = TestActor.start_link(conn)

    refute TestActor.connected?(actor)
    Process.sleep(5000)
    assert TestActor.connected?(actor)
  end

  test "accepts connection names via Registry" do
    registry_name = :"freddy-actor-test-registry-#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    connection_name = {:via, Registry, {registry_name, :connection}}
    {:ok, _connection} = Freddy.Connection.start_link([adapter: :sandbox], name: connection_name)

    {:ok, actor} = TestActor.start_link(connection_name)

    assert_eventually(fn -> TestActor.connected?(actor) end)

    ref = Process.monitor(actor)
    Freddy.Connection.stop(connection_name)

    assert_receive {:DOWN, ^ref, :process, ^actor, :normal}
  end

  defp assert_eventually(predicate, timeout \\ 2000)

  defp assert_eventually(predicate, timeout) when timeout <= 0 do
    assert predicate.()
  end

  defp assert_eventually(predicate, timeout) do
    if predicate.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(predicate, timeout - 25)
    end
  end
end
