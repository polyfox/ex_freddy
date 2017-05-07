# Freddy

RPC protocol over RabbitMQ. **In development stage**.

[![Build Status](https://travis-ci.org/salemove/ex_freddy.svg?branch=master)](https://travis-ci.org/salemove/ex_freddy)

## Installation

The package can be installed as:

  1. Add `freddy` to your list of dependencies in `mix.exs`:
  ```elixir
  def deps do
    [{:freddy, github: "salemove/ex_freddy"}]
  end
  ```

  2. Ensure `freddy` is started before your application:
  ```elixir
  def application do
    [applications: [:freddy]]
  end
  ```
## Usage

  1. Create Freddy connection:
  ```elixir
  {:ok, conn} = Freddy.Conn.start_link()
  ```
    
  2. Create RPC Client:
  ```elixir
  defmodule AMQPService do
    use Freddy.RPC.Client
    
    @config [routing_key: "amqp-service"]
    
    def start_link(conn, initial \\ nil, opts \\ []) do
      Freddy.RPC.Client.start_link(__MODULE__, conn, @config, initial, opts)
    end
    
    def ping(client) do
      Freddy.RPC.Client.request(client, %{type: "ping"})
    end
  end
  ```

  3. Put both connection and service under supervision tree (in this case we're registering
  connection process and RPC client process under static names):
  ```elixir
  defmodule MyApp do
    use Application
    
    def start(_type, _args) do
      import Supervisor.Spec
  
      children = [
        worker(Freddy.Conn, [[], [name: Freddy.Conn]]),
        worker(AMQPService, [Freddy.Conn, nil, [name: AMQPService]])
      ]
  
      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```
    
  4. You can now use your client:
  ```elixir
  case AMQPService.ping(AMQPService) do
    {:ok, resp} -> 
      IO.puts "Response: #{inspect response}"
      
    {:error, reason} ->
      IO.puts "Something went wrong: #{inspect reason}"
  end
  ```
