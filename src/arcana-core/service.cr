module Arcana
  # A non-LLM service that listens on the Bus and handles requests
  # using a fixed handler block. Validates input against a schema
  # and follows the Protocol handshake automatically.
  #
  #   svc = Arcana::Service.new(
  #     bus: bus,
  #     directory: dir,
  #     address: "resizer",
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
  class Service
    getter address : String

    def initialize(
      @bus : Bus,
      @directory : Directory,
      address : String,
      @name : String,
      @description : String,
      @schema : JSON::Any? = nil,
      @guide : String? = nil,
      @tags : Array(String) = [] of String,
      &handler : JSON::Any -> JSON::Any
    )
      @address = Directory.qualify(address, Directory::Kind::Service)
      @handler = handler
      @running = false

      @directory.register(Directory::Listing.new(
        address: @address,
        name: @name,
        description: @description,
        kind: Directory::Kind::Service,
        schema: @schema,
        guide: @guide,
        tags: @tags,
      ))

      @mailbox = @bus.mailbox(@address)
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

    # Stop the service. It will finish processing the current request.
    def stop
      @running = false
      @directory.unregister(@address)
    end

    private def handle(envelope : Envelope)
      # Respond to help requests with the guide.
      if Protocol.proto?(envelope.payload) && Protocol.intent(envelope.payload) == "help"
        guide_text = @guide || @description
        reply(envelope, Protocol.help(guide_text, schema: @schema))
        return
      end

      data = extract_data(envelope.payload)

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
        @directory.set_busy(@address, true)
        result = @handler.call(data)
        reply(envelope, Protocol.result(result))
      rescue ex
        reply(envelope, Protocol.error(ex.message || "Unknown error"))
      ensure
        @directory.set_busy(@address, false)
      end
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
    private def check_required(data : JSON::Any, schema : JSON::Any) : Array(String)
      missing = [] of String
      if required = schema["required"]?.try(&.as_a?)
        required.each do |field|
          name = field.as_s
          missing << name unless data[name]?
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
