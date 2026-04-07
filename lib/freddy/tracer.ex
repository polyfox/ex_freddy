defmodule Freddy.Tracer do
  # @response_queue_prefix "amq.gen-"

  def with_send_span(exchange, routing_key, block) do
    destination_kind =
      if exchange.type == :direct do
        "queue"
      else
        "topic"
      end

    :telemetry.span(
      [:freddy, :send],
      %{
        attributes: %{
          "messaging.system": "rabbitmq",
          "messaging.rabbitmq_routing_key": routing_key,
          "messaging.destination": exchange.name,
          "messaging.destination_kind": destination_kind
        },
        kind: :producer
      },
      block
    )
  end

  def with_process_span(meta, exchange, mod, block) do
    routing_key = Map.get(meta, :routing_key)

    destination_kind = if exchange.type == :direct, do: "queue", else: "topic"

    :telemetry.span(
      [:freddy, :process],
      %{
        attributes: %{
          "messaging.system": "rabbitmq",
          "messaging.rabbitmq_routing_key": routing_key,
          "messaging.destination": exchange.name,
          "messaging.destination_kind": destination_kind,
          "messaging.operation": "process",
          "messaging.freddy.worker": to_string(mod)
        },
        kind: :consumer
      },
      block
    )
  end
end
