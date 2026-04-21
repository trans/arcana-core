require "json"

module Arcana
  enum Ordering
    Auto  # resolved by bus based on target kind (default)
    Async # fire and forget
    Sync  # sender blocks for reply
  end

  # A message passed between agents via the Bus.
  struct Envelope
    property from : String
    property to : String
    property subject : String
    property payload : JSON::Any
    property correlation_id : String
    property reply_to : String?
    property ordering : Ordering
    property timestamp : Time

    def initialize(
      @from : String,
      @to : String = "",
      @subject : String = "",
      @payload : JSON::Any = JSON::Any.new(nil),
      @correlation_id : String = Random::Secure.hex(8),
      @reply_to : String? = nil,
      @ordering : Ordering = Ordering::Auto,
      @timestamp : Time = Time.utc,
    )
    end

    # Create a reply to this envelope.
    def reply(from : String, payload : JSON::Any, subject : String? = nil) : Envelope
      Envelope.new(
        from: from,
        to: @reply_to || @from,
        subject: subject || @subject,
        payload: payload,
        correlation_id: @correlation_id,
      )
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "from", @from
        json.field "to", @to
        json.field "subject", @subject
        json.field "payload", @payload
        json.field "correlation_id", @correlation_id
        json.field "reply_to", @reply_to if @reply_to
        json.field "ordering", @ordering.to_s.downcase unless @ordering.auto?
        json.field "timestamp", @timestamp.to_rfc3339
      end
    end

    def self.from_json(raw : String) : self
      parsed = JSON.parse(raw)
      ordering = case parsed["ordering"]?.try(&.as_s?)
                 when "sync"  then Ordering::Sync
                 when "async" then Ordering::Async
                 else              Ordering::Auto
                 end
      new(
        from: parsed["from"].as_s,
        to: parsed["to"]?.try(&.as_s?) || "",
        subject: parsed["subject"]?.try(&.as_s?) || "",
        payload: parsed["payload"]? || JSON::Any.new(nil),
        correlation_id: parsed["correlation_id"]?.try(&.as_s?) || Random::Secure.hex(8),
        reply_to: parsed["reply_to"]?.try(&.as_s?),
        ordering: ordering,
        timestamp: parsed["timestamp"]?.try { |t| Time.parse_rfc3339(t.as_s) } || Time.utc,
      )
    end
  end
end
