require "http/web_socket"
require "uri"
require "json"

module Arcana
  # WebSocket client for connecting to an Arcana bus server.
  #
  # Connects to ws://host:port/bus, joins with an address, then becomes
  # a full bus participant — send, publish, subscribe, and receive pushed
  # envelopes in real time via the on_message handler.
  #
  #   client = Arcana::Client.new(
  #     url: "ws://localhost:19118/bus",
  #     address: "shoppe:storefront",   # services: owner:capability
  #     name: "Shoppe",
  #     description: "Print-on-demand storefront generator",
  #     tags: ["storefront", "print-on-demand"],
  #   )
  #
  #   client.on_message do |envelope|
  #     # handle the envelope; reply via client.send(envelope.reply(...))
  #   end
  #
  #   client.connect  # blocks: runs the receive loop
  #
  # For pure consumers (code that *uses* services but doesn't expose any),
  # pass `listed: false` so the directory doesn't show an entry that's
  # never meant to be addressed:
  #
  #   client = Arcana::Client.new(
  #     url: "ws://localhost:19118/bus",
  #     address: "wow-io",       # plain agent name
  #     listed: false,           # mailbox only, no directory entry
  #   )
  #
  class Client
    getter address : String

    @ws : HTTP::WebSocket?
    @handler : Proc(Envelope, Nil)?
    @pending_replies = {} of String => Channel(Envelope)
    @send_mutex = Mutex.new
    @pending_mutex = Mutex.new

    def initialize(
      url : String,
      @address : String,
      @name : String? = nil,
      @description : String? = nil,
      @tags : Array(String) = [] of String,
      @listed : Bool = true,
    )
      @url = url
      Directory.validate_address(@address)
    end

    # Is this client registered as a service (vs. an agent)?
    def service? : Bool
      Directory.service?(@address)
    end

    # Register a handler for incoming envelopes. Set before calling `connect`.
    def on_message(&block : Envelope -> Nil)
      @handler = block
    end

    # Open the WebSocket, send the join frame, and run the receive loop.
    # Blocks until the connection closes. Run in a fiber (`spawn { client.connect }`)
    # if you need to do other work concurrently.
    def connect
      uri = URI.parse(@url)
      host = uri.host || "localhost"
      port = uri.port || (uri.scheme == "wss" ? 443 : 80)
      path = uri.path.empty? ? "/bus" : uri.path
      tls = uri.scheme == "wss"

      ws = HTTP::WebSocket.new(host: host, port: port, path: path, tls: tls)
      @ws = ws

      ws.on_message do |msg|
        begin
          handle_incoming(msg)
        rescue ex
          STDERR.puts "Arcana::Client message handler error: #{ex.message}"
        end
      end

      ws.on_close do |_code, _message|
        @ws = nil
      end

      send_join
      ws.run
    end

    # Send an envelope to its `to` address.
    def send(envelope : Envelope)
      send_frame({
        "type"     => JSON::Any.new("send"),
        "envelope" => JSON.parse(envelope.to_json),
      })
    end

    # Publish an envelope to all subscribers of `topic`.
    def publish(topic : String, envelope : Envelope)
      send_frame({
        "type"     => JSON::Any.new("publish"),
        "topic"    => JSON::Any.new(topic),
        "envelope" => JSON.parse(envelope.to_json),
      })
    end

    # Subscribe this address to a topic.
    def subscribe(topic : String)
      send_frame({
        "type"  => JSON::Any.new("subscribe"),
        "topic" => JSON::Any.new(topic),
      })
    end

    # Unsubscribe this address from a topic.
    def unsubscribe(topic : String)
      send_frame({
        "type"  => JSON::Any.new("unsubscribe"),
        "topic" => JSON::Any.new(topic),
      })
    end

    # Send an envelope and block until a reply with the same correlation_id
    # arrives or the timeout expires. Returns nil on timeout.
    def request(envelope : Envelope, timeout : Time::Span = 30.seconds) : Envelope?
      channel = Channel(Envelope).new(1)
      @pending_mutex.synchronize { @pending_replies[envelope.correlation_id] = channel }

      send(envelope)

      select
      when reply = channel.receive
        @pending_mutex.synchronize { @pending_replies.delete(envelope.correlation_id) }
        reply
      when timeout(timeout)
        @pending_mutex.synchronize { @pending_replies.delete(envelope.correlation_id) }
        nil
      end
    end

    # Close the connection.
    def close
      @ws.try(&.close)
      @ws = nil
    end

    # Is the client currently connected?
    def connected? : Bool
      !@ws.nil?
    end

    private def send_join
      frame = {
        "type"    => JSON::Any.new("join"),
        "address" => JSON::Any.new(@address),
      } of String => JSON::Any
      if name = @name
        frame["name"] = JSON::Any.new(name)
      end
      if description = @description
        frame["description"] = JSON::Any.new(description)
      end
      unless @tags.empty?
        frame["tags"] = JSON::Any.new(@tags.map { |t| JSON::Any.new(t) })
      end
      # Only emit listed=false; the server defaults to listed when absent.
      frame["listed"] = JSON::Any.new(false) unless @listed
      send_frame(frame)
    end

    private def send_frame(frame : Hash(String, JSON::Any))
      ws = @ws
      raise Error.new("Arcana::Client not connected") unless ws
      @send_mutex.synchronize { ws.send(JSON::Any.new(frame).to_json) }
    end

    private def handle_incoming(msg : String)
      envelope = Envelope.from_json(msg)

      # Route replies to any pending request() callers first.
      channel = @pending_mutex.synchronize { @pending_replies[envelope.correlation_id]? }
      if channel
        channel.send(envelope)
        return
      end

      @handler.try(&.call(envelope))
    end
  end
end
