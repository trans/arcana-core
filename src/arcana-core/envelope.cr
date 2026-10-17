require "json"

module Arcana
  enum Ordering
    Auto  # resolved by bus based on target kind (default)
    Async # fire and forget
    Sync  # sender blocks for reply
  end

  # A message passed between agents via the Bus.
  #
  # `id` and `re` are mail headers in the dot-ai sense, carried with the
  # message and never set by the bus. `id` is the message's own id, the
  # same on the sender's and the recipient's copy: hex, 8 digits or more
  # (dot-ai computes it from the sender, the sent copy's name and the
  # message). It isn't the correlation id, which a request and its reply
  # share. `re` says what a message answers: a message's id, or a topic's
  # post as `#topic:<seq>`. Either is dropped (nil) when it isn't in that
  # form, so neither can carry anything else into a mail file's headers.
  struct Envelope
    MESSAGE_ID = /\A[0-9a-fA-F]{8,64}\z/
    REPLY_TO   = /\A(?:[0-9a-fA-F]{8,64}|#[^\s:]+:\d+)\z/

    property from : String
    property to : String
    property subject : String
    property payload : JSON::Any
    property correlation_id : String
    property reply_to : String?
    property ordering : Ordering
    property timestamp : Time
    getter id : String?
    getter re : String?

    def initialize(
      @from : String,
      @to : String = "",
      @subject : String = "",
      @payload : JSON::Any = JSON::Any.new(nil),
      @correlation_id : String = Random::Secure.hex(8),
      @reply_to : String? = nil,
      @ordering : Ordering = Ordering::Auto,
      @timestamp : Time = Time.utc,
      id : String? = nil,
      re : String? = nil,
    )
      @id = id if id && id.matches?(MESSAGE_ID)
      @re = re if re && re.matches?(REPLY_TO)
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
        json.field "id", @id if @id
        json.field "re", @re if @re
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
        id: parsed["id"]?.try(&.as_s?),
        re: parsed["re"]?.try(&.as_s?),
      )
    end
  end
end
