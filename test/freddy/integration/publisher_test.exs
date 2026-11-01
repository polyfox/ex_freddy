defmodule Freddy.Integration.PublisherTest do
  use Freddy.IntegrationCase

  defmodule TestPublisher do
    use Freddy.Publisher

    @config [
      exchange: [name: "freddy-test-fanout-exchange", type: :fanout, opts: [auto_delete: true]]
    ]

    def start_link(conn, pid, opts \\ []) do
      Freddy.Publisher.start_link(__MODULE__, conn, @config, pid, opts)
    end

    @impl true
    def init(pid) do
      send(pid, :init)

      {:ok, pid}
    end

    @impl true
    def handle_connected(meta, pid) do
      send(pid, {:connected, meta})
      {:noreply, pid}
    end

    @impl true
    def handle_disconnected(reason, pid) do
      send(pid, {:disconnected, reason})
      {:noreply, pid}
    end

    @impl true
    def before_publication(
          %{action: "keep"} = payload,
          routing_key,
          opts,
          _from,
          _timeout,
          pid
        ) do
      send(pid, {:before_publication, payload, routing_key, opts})

      {:ok, pid}
    end

    def before_publication(
          %{action: "change"} = payload,
          routing_key,
          opts,
          _from,
          _timeout,
          pid
        ) do
      new_payload = %{action: "change", state: "changed"}
      new_routing_key = routing_key <> ".changed"
      new_opts = opts ++ [changed: "added"]

      send(pid, {:before_publication, payload, routing_key, opts})

      {:ok, new_payload, new_routing_key, new_opts, pid}
    end

    @impl true
    def handle_call(:call, _from, pid) do
      {:reply, :response, pid}
    end

    @impl true
    def handle_cast(:cast, pid) do
      send(pid, :cast)
      {:noreply, pid}
    end

    @impl true
    def handle_info(:info, pid) do
      send(pid, :info)
      {:noreply, pid}
    end

    @impl true
    def terminate(reason, pid) do
      send(pid, {:terminate, reason})
    end
  end

  defmodule TestConsumer do
    use Freddy.Consumer

    @config [
      queue: [opts: [auto_delete: true]],
      exchange: [name: "freddy-test-fanout-exchange", type: :fanout, opts: [auto_delete: true]],
      routing_keys: ["#"]
    ]

    def start_link(conn, pid) do
      Freddy.Consumer.start_link(__MODULE__, conn, @config, pid)
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

  setup context do
    name =
      if context[:use_registry] do
        {:ok, _registry} = Registry.start_link(keys: :unique, name: __MODULE__.Registry)

        {:via, Registry, {__MODULE__.Registry, "test_publisher"}}
      else
        nil
      end

    {:ok, pid} = TestPublisher.start_link(context[:connection], self(), name: name)

    {:ok, Map.put(context, :publisher, name || pid)}
  end

  describe "init/1" do
    test "init/1 is called on initialization" do
      assert_receive :init
    end
  end

  describe "handle_connected/2" do
    test "handle_connected/2 is called when RabbitMQ channel is opened" do
      assert_receive :init
      assert_receive {:connected, %{exchange: _}}
    end
  end

  describe "handle_disconnected/2" do
    test "handle_disconnected/2 is called when RabbitMQ connection is disrupted", %{
      connection: connection
    } do
      assert_receive :init
      assert_receive {:connected, %{exchange: _}}

      assert {:ok, conn} = Freddy.Connection.get_connection(connection)

      ref = Process.monitor(conn)
      Process.exit(conn, {:shutdown, {:server_initiated_close, 320, ~c'Good bye'}})
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert_receive {:disconnected, :shutdown}
      refute_receive :init
      assert_receive {:connected, _}
    end
  end

  describe "before_publication/4" do
    test "before_publication/4 keeps message unchanged when returns {:ok, state}", %{
      connection: connection,
      publisher: publisher
    } do
      {:ok, _consumer} = TestConsumer.start_link(connection, self())
      assert_receive :consumer_ready

      payload = %{action: "keep"}
      expected_payload = %{"action" => "keep"}
      routing_key = "routing_key"

      Freddy.Publisher.publish(publisher, payload, routing_key, mandatory: true)

      assert_receive {:before_publication, ^payload, ^routing_key, [mandatory: true]}
      assert_receive {:message_received, ^expected_payload}
    end

    test "before_publication/4 changes payload, routing_key and opts " <>
           "when returns {:ok, payload, routing_key, opts}",
         %{connection: connection, publisher: publisher} do
      {:ok, _consumer} = TestConsumer.start_link(connection, self())
      assert_receive :consumer_ready

      payload = %{action: "change"}
      expected_payload = %{"action" => "change", "state" => "changed"}
      routing_key = "routing_key"
      opts = [mandatory: true]

      Freddy.Publisher.publish(publisher, payload, routing_key, opts)

      assert_receive {:before_publication, ^payload, ^routing_key, [mandatory: true]}
      assert_receive {:message_received, ^expected_payload}
    end

    @tag use_registry: true
    test "publish works when publisher is registered via a registry",
         %{connection: connection, publisher: publisher} do
      {:ok, _consumer} = TestConsumer.start_link(connection, self())
      assert_receive :consumer_ready

      payload = %{action: "change"}
      expected_payload = %{"action" => "change", "state" => "changed"}
      routing_key = "routing_key"
      opts = [mandatory: true]

      Freddy.Publisher.publish(publisher, payload, routing_key, opts)

      assert_receive {:before_publication, ^payload, ^routing_key, [mandatory: true]}
      assert_receive {:message_received, ^expected_payload}
    end
  end

  describe "handle_call/3" do
    test "handle_call/3 is called on Freddy.Publisher.call", %{publisher: publisher} do
      assert :response = Freddy.Publisher.call(publisher, :call)
    end
  end

  describe "handle_cast/2" do
    test "handle_cast/2 is called on Freddy.Publisher.cast", %{publisher: publisher} do
      assert :ok = Freddy.Publisher.cast(publisher, :cast)
      _ = :sys.get_state(publisher)
      assert_receive :cast
    end
  end

  describe "handle_info/2" do
    test "handle_info/2 is called on other messages", %{publisher: publisher} do
      send(publisher, :info)
      _ = :sys.get_state(publisher)
      assert_receive :info
    end
  end

  describe "terminate/2" do
    test "terminate/2 is called when the process stops", %{publisher: publisher} do
      Freddy.Publisher.stop(publisher, :normal)
      assert_receive {:terminate, :normal}
    end
  end

  @tag server: true
  test "process stops if publisher can't declare an exchange due to permanent error", %{
    connection: connection
  } do
    {:ok, pid} =
      Freddy.Publisher.start(
        TestPublisher,
        connection,
        [exchange: [name: "amq.direct", type: :topic]],
        self()
      )

    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :precondition_failed}
  end
end
