require "json"

module Arcana
  # Handshake protocol for agent/service communication.
  #
  # Messages follow a simple envelope convention where the payload
  # contains protocol metadata prefixed with `_`. This keeps the
  # protocol transparent — any envelope can be a protocol message,
  # and non-protocol envelopes work fine too.
  #
  # Flow:
  #   1. Sender sends a `request` payload
  #   2. Recipient replies with `result`, `need`, or `error`
  #   3. If `need`, sender provides more info and goto 2
  #
  module Protocol
    VERSION = "arcana/1"

    # Wrap data as a request payload.
    def self.request(data : JSON::Any, intent : String = "") : JSON::Any
      h = base("request")
      h["data"] = data
      h["_intent"] = JSON::Any.new(intent) unless intent.empty?
      JSON::Any.new(h)
    end

    # Wrap data as a successful result payload.
    def self.result(data : JSON::Any) : JSON::Any
      h = base("result")
      h["data"] = data
      JSON::Any.new(h)
    end

    # Signal that more information is needed.
    # Services send their schema. Agents can send natural language questions.
    def self.need(
      schema : JSON::Any? = nil,
      questions : Array(String)? = nil,
      message : String? = nil,
    ) : JSON::Any
      h = base("need")
      h["schema"] = schema if schema
      if qs = questions
        h["questions"] = JSON::Any.new(qs.map { |q| JSON::Any.new(q) })
      end
      h["_message"] = JSON::Any.new(message) if message
      JSON::Any.new(h)
    end

    # Respond with a how-to guide.
    def self.help(guide : String, schema : JSON::Any? = nil) : JSON::Any
      h = base("help")
      h["guide"] = JSON::Any.new(guide)
      h["schema"] = schema if schema
      JSON::Any.new(h)
    end

    # Signal an error.
    def self.error(message : String, code : String? = nil) : JSON::Any
      h = base("error")
      h["_message"] = JSON::Any.new(message)
      h["_code"] = JSON::Any.new(code) if code
      JSON::Any.new(h)
    end

    # -- Readers --

    # Is this a protocol-formatted payload?
    def self.proto?(payload : JSON::Any) : Bool
      return false unless h = payload.as_h?
      h["_proto"]?.try(&.as_s?) == VERSION
    end

    # Extract the status field.
    def self.status(payload : JSON::Any) : String?
      return nil unless h = payload.as_h?
      h["_status"]?.try(&.as_s?)
    end

    # Extract the data field.
    def self.data(payload : JSON::Any) : JSON::Any?
      payload.as_h?.try(&.["data"]?)
    end

    # Extract the message field (for need/error).
    def self.message(payload : JSON::Any) : String?
      payload.as_h?.try(&.["_message"]?).try(&.as_s?)
    end

    # Extract the intent field (for requests).
    def self.intent(payload : JSON::Any) : String?
      payload.as_h?.try(&.["_intent"]?).try(&.as_s?)
    end

    def self.result?(payload : JSON::Any) : Bool
      status(payload) == "result"
    end

    def self.need?(payload : JSON::Any) : Bool
      status(payload) == "need"
    end

    def self.error?(payload : JSON::Any) : Bool
      status(payload) == "error"
    end

    def self.request?(payload : JSON::Any) : Bool
      status(payload) == "request"
    end

    def self.help?(payload : JSON::Any) : Bool
      status(payload) == "help"
    end

    # Extract the guide text from a help response.
    def self.guide(payload : JSON::Any) : String?
      payload.as_h?.try(&.["guide"]?).try(&.as_s?)
    end

    private def self.base(status : String) : Hash(String, JSON::Any)
      {
        "_proto"  => JSON::Any.new(VERSION),
        "_status" => JSON::Any.new(status),
      } of String => JSON::Any
    end
  end
end
