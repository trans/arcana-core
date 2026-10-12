module Arcana
  # A multi-tool bus provider. One directory listing, many callable tools
  # dispatched by the `tool` field in the payload. Auto-registers a
  # `help` tool that returns the tool manifest so callers can discover
  # what the provider offers.
  #
  # Use when you have more than one operation to expose under a single
  # address. For a single-purpose service (echo, markdown, one chat
  # endpoint), use `Arcana::Service` directly.
  #
  # **Two transports.**
  #
  # 1. In-process (Bus + Directory) — for tools registered inside the
  #    arcana daemon itself:
  #
  #      ts = Arcana::Toolset.new(
  #        bus: bus, directory: dir,
  #        address: "markdown",
  #        name: "Markdown", description: "Converts markdown to HTML/ANSI",
  #      )
  #      ts.tool("to_html", ...) { |data| ... }
  #      ts.start
  #
  # 2. Over a WebSocket Client — for a separate process (your Kemal
  #    app, mj, etc.) exposing tools on the daemon's bus:
  #
  #      client = Arcana::Client.new(
  #        url: "ws://localhost:19118/bus",
  #        address: "mj", name: "Minanime",
  #        description: "Image generation studio",
  #        kind: Arcana::Directory::Kind::Service,
  #        tags: ["image"],
  #      )
  #      ts = Arcana::Toolset.new(client: client)
  #      ts.tool("pixelize", "Pixel-art stylize", input_schema: ...) do |data|
  #        JSON::Any.new({"image_base64" => ...})
  #      end
  #      ts.run  # joins the bus, then blocks running the WebSocket loop
  #
  #    `run` is `start` + `client.connect`. Over a Client, `start` alone
  #    only installs the message handler: the service has no directory
  #    listing until the Client connects, and a Toolset still unconnected
  #    `connect_grace` after `start` warns on STDERR. To serve several
  #    Toolsets from one process, run all but the last in fibers:
  #
  #      spawn { camera.run }
  #      voice.run
  #
  # Same tool-registration API, same manifest shape, same dispatch. The
  # transport is the only thing that differs.
  #
  # **Concurrency.** Requests run concurrently, each in its own fiber, at
  # most `max_concurrent` at once (default 8; `nil` for no cap). Set it to
  # what the backend your handlers call can take: `max_concurrent: 3` for
  # a provider that asks for 2–4 concurrent requests. The listing reports
  # busy while at least one request is in flight. See `Dispatcher`.
  #
  # **Lanes, for a toolset in front of several backends.** One cap for the
  # whole toolset lets requests queued for a slow backend crowd out ones
  # another backend could serve. Give each backend a lane with its own
  # cap, and say which lane a request takes, fixed per tool or worked out
  # from its data:
  #
  #   ts.lane("runware", max_concurrent: 3)
  #   ts.lane("google", max_concurrent: 6)
  #   ts.tool("shoot", "Take a picture",
  #     lane: ->(data : JSON::Any) { backend_for(data) }) { |data| ... }
  #
  # A request waits for its lane before it takes one of the toolset's
  # slots, so waiting on a busy lane blocks no one else; `max_concurrent`
  # stays the overall backstop. The lane function runs before the
  # handler: keep it quick, and return nil for no lane.
  #
  # **Shared state.** Handlers run at the same time, and even though
  # fibers share one thread, any IO can pause one partway through while
  # another runs. State they share (an append-only log, a counter read
  # and written around a call, a cached client) belongs inside
  # `ctx.exclusive`, which runs one block at a time per key and leaves the
  # rest of the handler concurrent:
  #
  #   ts.tool("shoot", "Take a picture") do |data, ctx|
  #     image = camera.shoot(data)
  #     ctx.exclusive(:ledger) { ledger << cost }
  #     image
  #   end
  #
  # Code outside handlers can share the same locks with `Toolset#exclusive`.
  #
  # Callers (from any transport):
  #   deliver to:"mj" payload:{"tool":"help"}
  #   → {"tools":[{"name":"pixelize","description":"...","inputSchema":{...}}, ...]}
  #
  #   deliver to:"mj" payload:{"tool":"pixelize","prompt":"..."}
  #   → (result)
  class Toolset
    struct Tool
      getter name : String
      getter description : String
      getter input_schema : JSON::Any?
      getter lane : String | Proc(JSON::Any, String?) | Nil
      getter handler : Proc(JSON::Any, HandlerContext, JSON::Any)

      def initialize(@name, @description, @input_schema, @lane, @handler)
      end

      def to_manifest_entry : JSON::Any
        h = {
          "name"        => JSON::Any.new(@name),
          "description" => JSON::Any.new(@description),
        } of String => JSON::Any
        h["inputSchema"] = @input_schema.not_nil! if @input_schema
        JSON::Any.new(h)
      end
    end

    getter address : String

    # How long a Client-transport Toolset may stay unconnected after
    # `start` before it warns that it is invisible on the bus.
    property connect_grace : Time::Span = 5.seconds

    @bus : Bus?
    @directory : Directory?
    @mailbox : Mailbox?
    @client : Client?
    @dispatcher : Dispatcher
    @locks = Locks.new

    # In-process constructor: registers a listing on `directory` and
    # reads envelopes from a `Bus` mailbox.
    def initialize(
      bus : Bus,
      directory : Directory,
      @address : String,
      @name : String,
      @description : String,
      @tags : Array(String) = [] of String,
      max_concurrent : Int32? = Dispatcher::DEFAULT_MAX_CONCURRENT,
    )
      Directory.validate_address(@address)
      @bus = bus
      @directory = directory
      @client = nil
      @tools = {} of String => Tool
      @running = false
      address = @address
      @dispatcher = Dispatcher.new(max_concurrent, ->(busy : Bool) { directory.set_busy(address, busy) })

      directory.register(Directory::Listing.new(
        address: @address,
        name: @name,
        description: @description,
        kind: Directory::Kind::Service,
        tags: @tags,
        ephemeral: true,
      ))

      @mailbox = bus.mailbox(@address)
    end

    # Client-transport constructor: wraps a `Client` (already
    # configured with address/name/kind/tags). Envelopes flow over the
    # Client's WebSocket. The daemon's Directory is populated by the
    # Client's join frame — this constructor does not register a
    # listing itself.
    #
    # `name:` and `description:` are optional overrides for the tools
    # manifest header; if omitted, the client's own name/description
    # are used.
    def initialize(
      client : Client,
      name : String? = nil,
      description : String? = nil,
      max_concurrent : Int32? = Dispatcher::DEFAULT_MAX_CONCURRENT,
    )
      @dispatcher = Dispatcher.new(max_concurrent)
      @client = client
      @address = client.address
      @bus = nil
      @directory = nil
      @mailbox = nil
      @name = name || client.name || client.address
      @description = description || client.description || ""
      @tags = [] of String
      @tools = {} of String => Tool
      @running = false
    end

    # Register a tool. Add all tools before calling `start`. The handler
    # takes the request's data and, optionally, a `HandlerContext`. `lane`
    # names the lane its requests take, or works it out from their data.
    def tool(
      name : String,
      description : String,
      input_schema : JSON::Any? = nil,
      lane : String | Proc(JSON::Any, String?) | Nil = nil,
      &handler : JSON::Any, HandlerContext -> JSON::Any
    )
      raise Error.new("tool name 'help' is reserved; the manifest is generated automatically") if name == "help"
      @tools[name] = Tool.new(name, description, input_schema, lane, handler)
    end

    # Cap a lane: requests in it run at most `max_concurrent` at once.
    def lane(name : String, max_concurrent : Int32) : Nil
      @dispatcher.limit_lane(name, max_concurrent)
    end

    # Run the block while no handler of this toolset runs one under the
    # same key (see `HandlerContext#exclusive`); returns its value.
    def exclusive(key : String | Symbol = :default, &)
      @locks.synchronize(key.to_s) { yield }
    end

    # Return the tool manifest.
    def manifest : JSON::Any
      JSON::Any.new({
        "name"        => JSON::Any.new(@name),
        "description" => JSON::Any.new(@description),
        "tools"       => JSON::Any.new(@tools.values.map(&.to_manifest_entry)),
      } of String => JSON::Any)
    end

    # Start listening for envelopes. On Bus transport, spawns a fiber
    # reading from the mailbox. On Client transport, registers an
    # on_message handler — the caller still owns Client#connect (which
    # blocks running the WebSocket loop), or can call `run` instead.
    #
    # Also unions the user-provided tags with the registered tool names
    # so `arcana_directory tag:"chat"` finds every entity offering a
    # chat tool without the user having to double-declare.
    def start
      return if @running
      @running = true

      union_tool_tags

      if mb = @mailbox
        spawn do
          while @running
            submit(mb.receive)
          end
        end
      elsif c = @client
        # Never block the WebSocket read loop: it also carries replies.
        c.on_message do |envelope|
          submit_nowait(envelope)
        end
        warn_unless_connected(c)
      end
    end

    # The most requests that run at once (nil: no cap).
    def max_concurrent : Int32?
      @dispatcher.max_concurrent
    end

    # A method per envelope, so each fiber gets its own. In-process, the
    # mailbox reader waits for a slot, unless requests take lanes: then
    # each waits in its own fiber, so one busy lane can't stall the reader.
    private def submit(envelope : Envelope) : Nil
      if lanes?
        submit_nowait(envelope)
      else
        @dispatcher.submit { dispatch(envelope) }
      end
    end

    private def submit_nowait(envelope : Envelope) : Nil
      @dispatcher.submit_nowait(-> { lane_for(envelope) }) { dispatch(envelope) }
    end

    private def lanes? : Bool
      @dispatcher.lanes? || @tools.each_value.any?(&.lane)
    end

    private def lane_for(envelope : Envelope) : String?
      data = extract_data(envelope.payload)
      tool = @tools[data.str?("tool") || ""]?
      case lane = tool.try(&.lane)
      when String then lane
      when Proc   then lane.call(data)
      end
    end

    # Start and serve until the connection closes. On Client transport
    # this is `start` followed by `Client#connect`, which sends the join
    # frame (creating the directory listing) and blocks running the
    # WebSocket loop. On Bus transport the listing already exists, so
    # `run` starts and then blocks forever.
    def run
      start
      if c = @client
        c.connect
      else
        sleep
      end
    end

    private def warn_unless_connected(client : Client) : Nil
      spawn do
        sleep @connect_grace
        if @running && !client.connected?
          STDERR.puts "Arcana::Toolset #{@address}: started but its Client is not connected, " \
                      "so it has no directory listing and receives nothing. " \
                      "Call client.connect after start, or use Toolset#run."
        end
      end
    end

    # For Bus transport: retag the listing to include registered tool
    # names. For Client transport: no local directory to update — the
    # client already sent its join-frame tags; a future enhancement
    # could send an update frame here.
    private def union_tool_tags : Nil
      return unless dir = @directory
      combined = (@tags + @tools.keys.to_a).uniq
      dir.retag(@address, combined)
    end

    # Stop the toolset. In Bus mode, unregisters and drops the read
    # loop. In Client mode, this just flips a flag — the caller closes
    # the Client separately.
    def stop
      @running = false
      dir = @directory
      dir.unregister(@address) if dir
    end

    private def dispatch(envelope : Envelope)
      data = extract_data(envelope.payload)
      tool_name = data.str?("tool")

      reply_payload =
        if tool_name.nil? || tool_name.empty?
          Protocol.error("payload missing 'tool' field. Send {\"tool\":\"help\"} for available tools.")
        elsif tool_name == "help"
          Protocol.result(manifest)
        elsif tool_entry = @tools[tool_name]?
          begin
            Protocol.result(tool_entry.handler.call(data, HandlerContext.new(envelope, @locks)))
          rescue ex
            Protocol.error(ex.message || "handler crashed")
          end
        else
          known = @tools.keys.sort.join(", ")
          Protocol.error("unknown tool #{tool_name.inspect}. Known: #{known}. Send {\"tool\":\"help\"} for schemas.")
        end

      send_reply(envelope, reply_payload)
    rescue ex
      send_reply(envelope, Protocol.error(ex.message || "Unknown error"))
    end

    private def extract_data(payload : JSON::Any) : JSON::Any
      if Protocol.proto?(payload)
        Protocol.data(payload) || JSON::Any.new(nil)
      else
        payload
      end
    end

    private def send_reply(envelope : Envelope, payload : JSON::Any) : Nil
      destination = envelope.reply_to || envelope.from
      return if destination.empty?

      reply_env = Envelope.new(
        from: @address,
        to: destination,
        subject: envelope.subject,
        payload: payload,
        correlation_id: envelope.correlation_id,
      )

      if b = @bus
        b.send?(reply_env)
      elsif c = @client
        c.send(reply_env)
      end
    end
  end
end
