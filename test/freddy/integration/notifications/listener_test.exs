defmodule Freddy.Integration.Notifications.ListenerTest do
  use Freddy.IntegrationCase

  defmodule TestBroadcaster do
    use Freddy.Notifications.Broadcaster, warn: false

    def start_link(conn) do
      Freddy.Notifications.Broadcaster.start_link(__MODULE__, conn, nil)
    end
  end

  defmodule TestListener do
    use Freddy.Notifications.Listener, warn: false

    @config [
      queue: [opts: [auto_delete: true]],
      routing_keys: ["freddy-test"]
    ]

    def start_link(conn, pid) do
      Freddy.Notifications.Listener.start_link(__MODULE__, conn, @config, pid)
    end

    @impl true
    def handle_ready(_meta, pid) do
      send(pid, :consumer_ready)
      {:noreply, pid}
    end

    @impl true
    def handle_message(message, _meta, pid) do
      send(pid, {:message_received, message})
      {:reply, :ack, pid}
    end
  end

  test "consumes messages from freddy-topic exchange", %{connection: connection} do
    {:ok, broadcaster} = TestBroadcaster.start_link(connection)
    {:ok, _consumer} = TestListener.start_link(connection, self())

    assert_receive :consumer_ready

    payload = %{"key" => "value"}
    TestBroadcaster.broadcast(broadcaster, "freddy-test", payload)

    assert_receive {:message_received, ^payload}
  end
end
