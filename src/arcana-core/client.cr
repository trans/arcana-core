require "http/web_socket"
require "uri"
require "json"
require "./signing"

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
  # With `owner_token`, the join claims the address under it, as
  # `POST /register` does: no other client can then claim it, and a
  # join showing another token is refused. The address stays listed,
  # its mailbox collecting, when the client disconnects. A project's
  # token is the one in its `.ai/arcana.token`.
  #
  # With `key`, the project's `Key` (its `.ai/arcana.key`), the client
  # proves the address is its own: the join offers the public key, the
  # bus answers with a challenge, and the client signs it (see
  # `Signing`). The bus then holds the address for that key and stamps
  # what the client sends `verified`; `verified?` turns true once it
  # has. Each envelope the client sends also carries its signature, so
  # the receiver can check it too. A bus that doesn't check keys sends
  # no challenge, and the client works as one without a key.
  #
  class Client
    getter address : String

    @ws : HTTP::WebSocket?
    @handler : Proc(Envelope, Nil)?
    @pending_replies = {} of String => Channel(Envelope)
    @send_mutex = Mutex.new
    @pending_mutex = Mutex.new
    @bus_host = ""

    # Has the bus accepted this client's proof that the address is its
    # own? (Only with a `key`.)
    getter? verified = false

    # The last error the bus sent, such as a refused join.
    getter last_error : String?

    def initialize(
      url : String,
      @address : String,
      @name : String? = nil,
      @description : String? = nil,
      @kind : Directory::Kind? = nil,
      @guide : String? = nil,
      @schema : JSON::Any? = nil,
      @tags : Array(String) = [] of String,
      @listed : Bool = true,
      @owner_token : String? = nil,
      @key : Key? = nil,
    )
      @url = url
      Directory.validate_address(@address)
    end

    # Is this client registered as a service (vs. an agent)? If kind was
    # set explicitly at construction, use that; otherwise fall back to
    # the address-syntax guess.
    def service? : Bool
      k = @kind
      return k == Directory::Kind::Service if k
      Directory.service?(@address)
    end

    # Identity readers (Toolset reads these when constructed over Client).
    getter address : String
    getter name : String?
    getter description : String?
    getter guide : String?
    getter kind : Directory::Kind?

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

      # The Host header HTTP::WebSocket sends, which a join proof names.
      @bus_host = "#{host}:#{port}"
      @verified = false
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

    # Send an envelope to its `to` address (signed, with a `key`).
    def send(envelope : Envelope)
      send_frame({
        "type"     => JSON::Any.new("send"),
        "envelope" => JSON.parse(signed(envelope).to_json),
      })
    end

    # Publish an envelope to all subscribers of `topic`. Its `to` becomes
    # the topic, as the bus stores it, so a signature still matches.
    def publish(topic : String, envelope : Envelope)
      envelope.to = topic
      send_frame({
        "type"     => JSON::Any.new("publish"),
        "topic"    => JSON::Any.new(topic),
        "envelope" => JSON.parse(signed(envelope).to_json),
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
      if k = @kind
        frame["kind"] = JSON::Any.new(k.to_s.downcase)
      end
      if guide = @guide
        frame["guide"] = JSON::Any.new(guide)
      end
      if schema = @schema
        frame["schema"] = schema
      end
      unless @tags.empty?
        frame["tags"] = JSON::Any.new(@tags.map { |t| JSON::Any.new(t) })
      end
      # Only emit listed=false; the server defaults to listed when absent.
      frame["listed"] = JSON::Any.new(false) unless @listed
      if token = @owner_token
        frame["owner_token"] = JSON::Any.new(token)
      end
      if key = @key
        frame["key"] = JSON::Any.new(key.public_key)
      end
      send_frame(frame)
    end

    private def signed(envelope : Envelope) : Envelope
      (key = @key) ? envelope.signed(key) : envelope
    end

    private def send_frame(frame : Hash(String, JSON::Any))
      ws = @ws
      raise Error.new("Arcana::Client not connected") unless ws
      @send_mutex.synchronize { ws.send(JSON::Any.new(frame).to_json) }
    end

    private def handle_incoming(msg : String)
      parsed = JSON.parse(msg)
      return if bus_frame?(parsed)
      envelope = Envelope.from_json(parsed)

      # Route replies to any pending request() callers first.
      channel = @pending_mutex.synchronize { @pending_replies[envelope.correlation_id]? }
      if channel
        channel.send(envelope)
        return
      end

      @handler.try(&.call(envelope))
    end

    # Handle a frame from the bus itself rather than an envelope: a join
    # challenge, the bus's word that the join is proved, or an error.
    private def bus_frame?(frame : JSON::Any) : Bool
      return false unless frame.as_h?
      case frame["type"]?.try(&.as_s?)
      when "challenge"
        answer_challenge(frame["challenge"]?.try(&.as_s?) || "")
        true
      when "joined"
        @verified = frame["verified"]?.try(&.as_bool?) || false
        true
      else
        return false if frame["from"]?
        if error = frame["error"]?.try(&.as_s?)
          @last_error = error
          STDERR.puts "Arcana::Client (#{@address}): the bus said: #{error}"
          true
        else
          false
        end
      end
    end

    private def answer_challenge(challenge : String) : Nil
      key = @key
      return unless key && !challenge.empty?
      send_frame({
        "type"      => JSON::Any.new("prove"),
        "signature" => JSON::Any.new(key.sign(Signing.join_proof(@bus_host, @address, challenge))),
      })
    end
  end
end
