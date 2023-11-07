defmodule Freddy.Connection.ChannelManager do
  use GenServer

  alias Freddy.Core.Channel

  import Record

  defrecord :state,
    adapter: nil,
    parent: nil,
    connection: nil

  def open_channel(pid, ref, timeout_at) do
    GenServer.cast(pid, {:open_channel, ref, timeout_at})
  end

  def start_link(parent, adapter, connection) do
    GenServer.start_link(__MODULE__, {parent, adapter, connection}, [])
  end

  @impl true
  def init({parent, adapter, connection}) do
    {:ok, state(parent: parent, adapter: adapter, connection: connection)}
  end

  @impl true
  def handle_cast(
    {:open_channel, ref, timeout_at},
    state(adapter: adapter, connection: connection) = state
  ) do
    now = System.monotonic_time(:millisecond)
    if now < timeout_at do
      try do
        case Channel.open(adapter, connection) do
          {:ok, _chan} = reply ->
            reply_to_parent(ref, reply, state)
            {:noreply, state}

          {:error, _reason} = reply ->
            reply_to_parent(ref, reply, state)
            {:noreply, state}
        end
      catch
        :exit, {:noproc, _} ->
          reply_to_parent(ref, {:error, :closed}, state)
          {:noreply, state}

        _, _ ->
          reply_to_parent(ref, {:error, :closed}, state)
          {:noreply, state}
      end
    else
      reply_to_parent(ref, {:error, :timeout}, state)
      {:noreply, state}
    end
  end

  defp reply_to_parent(ref, reply, state(parent: parent)) do
    send(parent, {:"$channel_manager", {:open_channel_resp, ref, reply}})
  end
end
