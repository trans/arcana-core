module Arcana
  # A non-LLM service that listens on the Bus and handles requests
  # using a fixed handler block. Validates input against a schema
  # and follows the Protocol handshake automatically.
  #
  #   svc = Arcana::Service.new(
  #     bus: bus,
  #     directory: dir,
  #     address: "arcana:resizer",   # owner:capability
  #     name: "Image Resizer",
  #     description: "Resizes images to specified dimensions",
  #     schema: JSON.parse(%({"type":"object","properties":{...},"required":["path","width"]})),
  #     tags: ["image"],
  #   ) do |data|
  #     # data is the validated JSON::Any payload
  #     path = data["path"].as_s
  #     JSON::Any.new({"output" => JSON::Any.new("/tmp/resized.png")})
  #   end
  #
  #   svc.start  # spawns a listener fiber
  #
  # Requests run concurrently, at most `max_concurrent` at once (default
  # 8; `nil` for no cap). The listing reports busy while at least one is in
  # flight. State the handler shares across requests belongs inside
  # `ctx.exclusive` (the handler's optional second argument, a
  # `HandlerContext`); see `Toolset` on shared state, and on lanes for a
  # handler in front of several backends.
  class Service
    getter address : String
    @locks = Locks.new

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @address : String,
      @name : String,
      @description : String,
      @schema : JSON::Any? = nil,
      @guide : String? = nil,
      @tags : Array(String) = [] of String,
      max_concurrent : Int32? = Dispatcher::DEFAULT_MAX_CONCURRENT,
      &handler : JSON::Any, HandlerContext -> JSON::Any
    )
      Directory.validate_address(@address)
      @handler = handler
      @running = false
      directory = @directory
      address = @address
      @dispatcher = Dispatcher.new(max_concurrent, ->(busy : Bool) { directory.set_busy(address, busy) })

      @directory.register(Directory::Listing.new(
        address: @address,
        name: @name,
        description: @description,
        kind: Directory::Kind::Service,
        schema: @schema,
        guide: @guide,
        tags: @tags,
        ephemeral: true,
      ))

      @mailbox = @bus.mailbox(@address)
    end

    # Start listening for requests. Spawns a fiber that hands each request
    # to its own fiber, up to `max_concurrent` at once.
    def start
      return if @running
      @running = true

      spawn do
        while @running
          submit(@mailbox.receive)
        end
      end
    end

    # The most requests that run at once (nil: no cap).
    def max_concurrent : Int32?
      @dispatcher.max_concurrent
    end

    # Run the block while no handler run holds the same key (see
    # `HandlerContext#exclusive`); returns its value.
    def exclusive(key : String | Symbol = :default, &)
      @locks.synchronize(key.to_s) { yield }
    end

    # A method per envelope, so each fiber gets its own.
    private def submit(envelope : Envelope) : Nil
      @dispatcher.submit { handle(envelope) }
    end

    # Stop the service. Requests already running finish.
    def stop
      @running = false
      @directory.unregister(@address)
    end

    private def handle(envelope : Envelope)
      data = extract_data(envelope.payload)

      # Respond to `{"tool":"help"}` with the service's guide + schema
      # wrapped as a normal result. Single-purpose services present one
      # "tool" (themselves); Toolset providers override this with a rich
      # multi-tool manifest.
      if data.str?("tool") == "help"
        guide_text = @guide || @description
        manifest = {
          "guide" => JSON::Any.new(guide_text),
        } of String => JSON::Any
        manifest["inputSchema"] = @schema.not_nil! if @schema
        reply(envelope, Protocol.result(JSON::Any.new(manifest)))
        return
      end

      # Validate against schema if present
      if schema = @schema
        missing = check_required(data, schema)
        unless missing.empty?
          reply(envelope, Protocol.need(
            schema: schema,
            message: "Missing required fields: #{missing.join(", ")}",
          ))
          return
        end
      end

      # Execute handler
      begin
        result = @handler.call(data, HandlerContext.new(envelope, @locks))
        reply(envelope, Protocol.result(result))
      rescue ex
        reply(envelope, Protocol.error(ex.message || "Unknown error"))
      end
    rescue ex
      # Guard against exceptions raised before the inner rescue (e.g.
      # malformed payloads reaching Protocol/extract_data/check_required
      # before the handler runs). Without this the fiber dies and the
      # mailbox loop stops consuming — so one bad message hangs the
      # whole service.
      reply(envelope, Protocol.error(ex.message || "Unknown error"))
    end

    # Extract the data from a payload, whether it's protocol-wrapped or raw.
    private def extract_data(payload : JSON::Any) : JSON::Any
      if Protocol.proto?(payload)
        Protocol.data(payload) || JSON::Any.new(nil)
      else
        payload
      end
    end

    # Check required fields from a JSON Schema against the data.
    # A non-hash payload counts every required field as missing, so the
    # caller gets a Protocol.need response instead of the fiber dying
    # on JSON::Any's "Expected Hash for #[]?(String)" error.
    private def check_required(data : JSON::Any, schema : JSON::Any) : Array(String)
      missing = [] of String
      hash = data.as_h?
      if required = schema["required"]?.try(&.as_a?)
        if hash.nil?
          required.each { |field| missing << field.as_s }
        else
          required.each do |field|
            name = field.as_s
            missing << name unless hash[name]?
          end
        end
      end
      missing
    end

    private def reply(envelope : Envelope, payload : JSON::Any)
      if reply_to = envelope.reply_to
        @bus.send?(Envelope.new(
          from: @address,
          to: reply_to,
          subject: envelope.subject,
          payload: payload,
          correlation_id: envelope.correlation_id,
        ))
      elsif !envelope.from.empty?
        @bus.send?(Envelope.new(
          from: @address,
          to: envelope.from,
          subject: envelope.subject,
          payload: payload,
          correlation_id: envelope.correlation_id,
        ))
      end
    end
  end
end
