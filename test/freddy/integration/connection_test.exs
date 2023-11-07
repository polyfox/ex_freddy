defmodule Freddy.Integration.ConnectionTest do
  use ExUnit.Case

  alias Freddy.Connection
  alias Freddy.Core.Channel

  import Freddy.Adapter.AMQP.Core

  # This test assumes that RabbitMQ server is running with default settings on localhost

  describe "get_connection/1" do
    test "can retrieve the underlying connection pid" do
      assert {:ok, pid} = Connection.start_link()

      try do
        assert {:ok, conn_pid} = Connection.get_connection(pid)
        _data = :amqp_connection.info(conn_pid, [
          :type,
          :server_properties,
          :num_channels,
          :channel_max,
          :is_closing,
        ])
      after
        Connection.stop(pid)
      end
    end
  end

  describe "open_channel/1" do
    test "can open a channel" do
      assert {:ok, pid} = Connection.start_link()

      try do
        assert {:ok, %Channel{} = _channel} = Connection.open_channel(pid)
      after
        Connection.stop(pid)
      end
    end

    test "can safely handle multiple channel opens" do
      assert {:ok, pid} = Connection.start_link()

      try do
        for _ <- 1..10 do
          assert {:ok, %Channel{} = _channel} = Connection.open_channel(pid)
        end
      after
        Connection.stop(pid)
      end
    end

    test "can gracefully handle a dead channel" do
      assert {:ok, conn_pid} = Connection.start_link()

      try do
        assert {:ok, %Channel{chan: chan_pid} = chan} = Connection.open_channel(conn_pid)

        assert true == Connection.has_channel?(conn_pid, chan)

        # kill the channel
        ref = Process.monitor(chan_pid)
        Process.exit(chan_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, _, :killed}

        assert false == Connection.has_channel?(conn_pid, chan)
      after
        Connection.stop(conn_pid)
      end
    end
  end

  test "establishes connection to AMQP server" do
    assert {:ok, _pid} = Connection.start_link()
  end

  test "re-establishes connection if it's closed" do
    {:ok, pid} = Connection.start_link()

    assert {:ok, conn} = Connection.get_connection(pid)
    Connection.close(pid)

    assert {:ok, conn2} = Connection.get_connection(pid)
    assert conn != conn2
  end

  test "re-establishes connection if it's disrupted" do
    {:ok, pid} = Connection.start_link()
    assert {:ok, conn} = Connection.get_connection(pid)

    ref = Process.monitor(conn)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    assert {:ok, conn2} = Connection.get_connection(pid)
    assert conn != conn2
  end

  test "re-establishes connection if server closed it" do
    {:ok, pid} = Connection.start_link()
    assert {:ok, conn} = Connection.get_connection(pid)

    ref = Process.monitor(conn)
    Process.exit(conn, {:shutdown, {:server_initiated_close, 320, 'Good bye'}})
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert {:ok, conn2} = Connection.get_connection(pid)
    assert conn != conn2
  end

  test "closes channel gracefully if calling process is stopped" do
    {:ok, pid} = Connection.start_link()

    parent = self()

    child =
      spawn_link(fn ->
        assert {:ok, chan} = Connection.open_channel(pid)

        send(parent, {:channel, chan})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:channel, chan}, 3000
    ref = Channel.monitor(chan)

    send(child, :stop)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 3000
  end

  test "process can be stopped by Process.exit" do
    {:ok, pid} = Connection.start_link()

    try do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :restart)

      assert_receive {:DOWN, ^ref, :process, ^pid, :restart}, 3000
    after
      :ok
    end
  end

  test "establishes connection to secondary server if primary server is unavailable" do
    {:ok, pid} =
      Connection.start_link([
        [host: "127.0.0.2", connection_timeout: 500, port: 6389],
        [host: "127.0.0.1"]
      ])

    assert {:ok, conn} = Connection.get_connection(pid)
    assert is_pid(conn)
    assert [amqp_params: params] = :amqp_connection.info(conn, [:amqp_params])
    amqp_params_network(host: host) = params
    assert host == '127.0.0.1'
  end
end
