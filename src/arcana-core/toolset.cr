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
  #   ts = Arcana::Toolset.new(
  #     bus: bus, directory: dir,
  #     address: "mj",
  #     name: "Minanime",
  #     description: "Image generation studio",
  #     capability: "image",
  #     tags: ["image", "generation"],
  #   )
  #
  #   ts.tool("pixelize",
  #     description: "Pixel-art stylization for a reference image",
  #     input_schema: JSON.parse(%({"type":"object","required":["prompt"]}))
  #   ) do |data|
  #     img = MyEngine.pixelize(prompt: data.str("prompt"))
  #     JSON::Any.new({"image_base64" => JSON::Any.new(img)})
  #   end
  #
  #   ts.tool("prop", description: "...") { |data| ... }
  #
  #   ts.start
  #
  # Callers:
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
      getter handler : Proc(JSON::Any, JSON::Any)

      def initialize(@name, @description, @input_schema, @handler)
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

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @address : String,
      @name : String,
      @description : String,
      @capability : String? = nil,
      @tags : Array(String) = [] of String,
    )
      Directory.validate_address(@address)
      @tools = {} of String => Tool
      @running = false

      @directory.register(Directory::Listing.new(
        address: @address,
        name: @name,
        description: @description,
        kind: Directory::Kind::Service,
        capability: @capability,
        tags: @tags,
      ))

      @mailbox = @bus.mailbox(@address)
    end

    # Register a tool. Add all tools before calling `start`.
    def tool(
      name : String,
      description : String,
      input_schema : JSON::Any? = nil,
      &handler : JSON::Any -> JSON::Any
    )
      raise Error.new("tool name 'help' is reserved; the manifest is generated automatically") if name == "help"
      @tools[name] = Tool.new(name, description, input_schema, handler)
    end

    # Return the tool manifest. Useful for tests and MCP bridging.
    def manifest : JSON::Any
      JSON::Any.new({
        "name"        => JSON::Any.new(@name),
        "description" => JSON::Any.new(@description),
        "tools"       => JSON::Any.new(@tools.values.map(&.to_manifest_entry)),
      } of String => JSON::Any)
    end

    # Start listening for requests. Spawns a fiber.
    def start
      return if @running
      @running = true

      spawn do
        while @running
          envelope = @mailbox.receive
          handle(envelope)
        end
      end
    end

    # Stop the toolset. Finishes the current request.
    def stop
      @running = false
      @directory.unregister(@address)
    end

    private def handle(envelope : Envelope)
      data = extract_data(envelope.payload)
      tool_name = data.str?("tool")

      if tool_name.nil? || tool_name.empty?
        reply(envelope, Protocol.error("payload missing 'tool' field. Send {\"tool\":\"help\"} for available tools."))
        return
      end

      if tool_name == "help"
        reply(envelope, Protocol.result(manifest))
        return
      end

      tool = @tools[tool_name]?
      unless tool
        known = @tools.keys.sort.join(", ")
        reply(envelope, Protocol.error("unknown tool #{tool_name.inspect}. Known: #{known}. Send {\"tool\":\"help\"} for schemas."))
        return
      end

      begin
        @directory.set_busy(@address, true)
        result = tool.handler.call(data)
        reply(envelope, Protocol.result(result))
      rescue ex
        reply(envelope, Protocol.error(ex.message || "handler crashed"))
      ensure
        @directory.set_busy(@address, false)
      end
    rescue ex
      reply(envelope, Protocol.error(ex.message || "Unknown error"))
    end

    private def extract_data(payload : JSON::Any) : JSON::Any
      if Protocol.proto?(payload)
        Protocol.data(payload) || JSON::Any.new(nil)
      else
        payload
      end
    end

    private def reply(envelope : Envelope, payload : JSON::Any)
      if reply_to = envelope.reply_to
        @bus.send?(Envelope.new(
          from: @address, to: reply_to,
          subject: envelope.subject, payload: payload,
          correlation_id: envelope.correlation_id,
        ))
      elsif !envelope.from.empty?
        @bus.send?(Envelope.new(
          from: @address, to: envelope.from,
          subject: envelope.subject, payload: payload,
          correlation_id: envelope.correlation_id,
        ))
      end
    end
  end
end
