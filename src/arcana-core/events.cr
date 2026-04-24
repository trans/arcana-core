require "json"
require "uri"

module Arcana
  # Append-only event log for the Arcana bus.
  #
  # Every material action (registrations, sends, publishes, freezes,
  # auth events, lifecycle) is recorded as an Event and written to a
  # Backend. The default `FileBackend` stores JSONL files with daily
  # rotation, gzip compression of older days, and time-based
  # purge/archive retention.
  #
  # Privacy: the event log stores *metadata only* — addresses, subjects,
  # correlation IDs, timestamps, sizes. Envelope payloads are not
  # persisted. If replay-based durability is ever needed, that would be
  # a separate "journal" stream with different retention and access rules.
  #
  # Enterprise / future work: tamper-evident logs (hash-chained events,
  # Merkle-tree periodic checkpoints) for audit compliance. Today's
  # FileBackend is trust-the-filesystem. When a customer needs
  # cryptographic audit guarantees, a `TamperEvidentFileBackend` (or a
  # separate `AuditBackend`) can layer on top — each event carries the
  # hash of the previous event, and a signed daily checkpoint ties the
  # chain to wall time. Deliberately scoped out for now.
  module Events
    # A single recorded event.
    struct Event
      property id : String
      property timestamp : Time
      property type : String           # e.g. "message.sent", "listing.registered"
      property subject : String        # primary address
      property object : String?        # secondary address (e.g. sender of a delivery)
      property correlation_id : String?
      property metadata : Hash(String, JSON::Any)?

      def initialize(
        @type : String,
        @subject : String,
        @object : String? = nil,
        @correlation_id : String? = nil,
        @metadata : Hash(String, JSON::Any)? = nil,
        @id : String = Random::Secure.hex(8),
        @timestamp : Time = Time.utc,
      )
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", @id
          json.field "timestamp", @timestamp.to_rfc3339
          json.field "type", @type
          json.field "subject", @subject
          json.field "object", @object if @object
          json.field "correlation_id", @correlation_id if @correlation_id
          if meta = @metadata
            json.field "metadata", meta unless meta.empty?
          end
        end
      end

      def self.from_json(raw : String) : self
        parsed = JSON.parse(raw)
        from_json_any(parsed)
      end

      def self.from_json_any(parsed : JSON::Any) : self
        metadata = parsed["metadata"]?.try(&.as_h?)
        new(
          type: parsed["type"].as_s,
          subject: parsed["subject"].as_s,
          object: parsed["object"]?.try(&.as_s?),
          correlation_id: parsed["correlation_id"]?.try(&.as_s?),
          metadata: metadata,
          id: parsed["id"]?.try(&.as_s?) || Random::Secure.hex(8),
          timestamp: parsed["timestamp"]?.try { |t| Time.parse_rfc3339(t.as_s) } || Time.utc,
        )
      end
    end

    # Abstract base. Implementations decide where events land.
    abstract class Backend
      # Record an event. Should not block on I/O — implementations may
      # queue asynchronously and return immediately.
      abstract def record(event : Event) : Nil

      # Query stored events. Filters are AND-combined.
      abstract def query(
        since : Time? = nil,
        type : String? = nil,
        subject : String? = nil,
        limit : Int32 = 100,
      ) : Array(Event)

      # Release resources; flush any buffered writes.
      def close : Nil
      end
    end
  end
end

require "./events/file_backend"
