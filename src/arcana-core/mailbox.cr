module Arcana
  # A buffered inbox for a single agent address.
  #
  # Backed by a Deque (not a Channel) so messages can be inspected
  # without consuming them and selectively received by id.
  class Mailbox
    getter address : String

    # Optional callback invoked on any activity (deliver, receive).
    # Used by Bus to refresh Directory last_seen.
    property on_activity : Proc(String, Nil)? = nil

    def initialize(@address : String)
      @messages = Deque(Envelope).new
      @mutex = Mutex.new
      @signal = Channel(Nil).new(1) # buffered signal for wake-ups
      @last_activity = Time.utc

      # Expected response tracking
      @expectations = Set(String).new
      @expect_mutex = Mutex.new
      @expect_signal = Channel(Nil).new(1)

      # Frozen message storage
      @frozen = {} of String => Envelope
      @frozen_by = {} of String => String
    end

    # Last time this mailbox had a deliver or receive operation.
    def last_activity : Time
      @mutex.synchronize { @last_activity }
    end

    # Set last activity timestamp directly (used by snapshot restore).
    def last_activity=(time : Time)
      @mutex.synchronize { @last_activity = time }
    end

    # Number of messages waiting to be received.
    def pending : Int32
      @mutex.synchronize { @messages.size }
    end

    # Deliver an envelope to this mailbox.
    def deliver(envelope : Envelope)
      @mutex.synchronize do
        @messages.push(envelope)
        @last_activity = Time.utc
      end
      on_deliver(envelope)
      # Auto-fulfill expectations
      fulfill(envelope.correlation_id)
      # Wake any blocking receiver (non-blocking send, ok if buffer full)
      select
      when @signal.send(nil)
      else
      end
    end

    # Non-destructive listing of message metadata.
    def inbox : Array(NamedTuple(correlation_id: String, from: String, subject: String, timestamp: Time))
      result = @mutex.synchronize do
        @messages.map do |env|
          {correlation_id: env.correlation_id, from: env.from, subject: env.subject, timestamp: env.timestamp}
        end
      end
      @on_activity.try(&.call(@address))
      result
    end

    # Block until an envelope arrives.
    def receive : Envelope
      loop do
        msg = try_receive
        return msg if msg
        @signal.receive
      end
    end

    # Block until an envelope arrives or timeout expires.
    # Returns nil on timeout.
    def receive(timeout : Time::Span) : Envelope?
      deadline = Time.instant + timeout
      loop do
        msg = try_receive
        return msg if msg
        remaining = deadline - Time.instant
        return nil if remaining <= Time::Span.zero
        select
        when @signal.receive
          # woken up, loop back to check deque
        when timeout(remaining)
          return try_receive # one last try
        end
      end
    end

    # Receive a specific message by correlation_id. Returns nil if not found.
    def receive(id : String) : Envelope?
      env = @mutex.synchronize do
        idx = @messages.index { |e| e.correlation_id == id }
        e = @messages.delete_at(idx) if idx
        @last_activity = Time.utc if e
        e
      end
      @on_activity.try(&.call(@address))
      on_consume(env) if env
      env
    end

    # Block until a specific message (by correlation_id) arrives or timeout expires.
    # Returns nil on timeout.
    def receive(id : String, timeout : Time::Span) : Envelope?
      deadline = Time.instant + timeout
      loop do
        env = receive(id)
        return env if env
        remaining = deadline - Time.instant
        return nil if remaining <= Time::Span.zero
        select
        when @signal.receive
          # woken up, loop back to check for our specific message
        when timeout(remaining)
          return receive(id) # one last try
        end
      end
    end

    # Non-blocking receive. Returns nil if empty.
    def try_receive : Envelope?
      env = @mutex.synchronize do
        e = @messages.shift?
        @last_activity = Time.utc if e
        e
      end
      @on_activity.try(&.call(@address))
      on_consume(env) if env
      env
    end

    # -- Expected response tracking --

    # Register that we expect a reply with this correlation_id.
    def expect(correlation_id : String)
      @expect_mutex.synchronize { @expectations.add(correlation_id) }
    end

    # Mark an expectation as fulfilled. Called automatically by deliver.
    def fulfill(correlation_id : String) : Bool
      fulfilled = @expect_mutex.synchronize do
        if @expectations.includes?(correlation_id)
          @expectations.delete(correlation_id)
          true
        else
          false
        end
      end
      if fulfilled
        select
        when @expect_signal.send(nil)
        else
        end
      end
      fulfilled
    end

    # Count of unfulfilled expectations.
    def outstanding : Int32
      @expect_mutex.synchronize { @expectations.size }
    end

    # Block until all expectations are met or timeout expires.
    # Returns true if all met, false on timeout.
    def await_outstanding(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      loop do
        return true if outstanding == 0
        remaining = deadline - Time.instant
        return false if remaining <= Time::Span.zero
        select
        when @expect_signal.receive
          # check again
        when timeout(remaining)
          return outstanding == 0
        end
      end
    end

    # -- Freeze/Thaw --

    # Freeze a message: move from deque to frozen map.
    # Returns true if a message was frozen.
    def freeze(id : String, by : String = "") : Bool
      result = @mutex.synchronize do
        idx = @messages.index { |env| env.correlation_id == id }
        if idx
          env = @messages.delete_at(idx)
          @frozen[id] = env
          @frozen_by[id] = by unless by.empty?
          true
        else
          false
        end
      end
      on_freeze(id, by) if result
      result
    end

    # Thaw a frozen message: move back to deque.
    # Returns the thawed envelope, or nil if not found.
    def thaw(id : String) : Envelope?
      env = @mutex.synchronize do
        e = @frozen.delete(id)
        @frozen_by.delete(id)
        @messages.push(e) if e
        e
      end
      if env
        on_thaw(id)
        select
        when @signal.send(nil)
        else
        end
      end
      env
    end

    # Thaw all frozen messages back to the deque.
    def thaw_all : Int32
      count = @mutex.synchronize do
        @frozen.each_value { |env| @messages.push(env) }
        c = @frozen.size
        @frozen.each_key { |id| on_thaw(id) }
        @frozen.clear
        @frozen_by.clear
        c
      end
      if count > 0
        select
        when @signal.send(nil)
        else
        end
      end
      count
    end

    # List frozen message metadata (non-destructive).
    def frozen : Array(NamedTuple(correlation_id: String, from: String, subject: String, frozen_by: String, timestamp: Time))
      @mutex.synchronize do
        @frozen.map do |id, env|
          {correlation_id: id, from: env.from, subject: env.subject,
           frozen_by: @frozen_by[id]? || "", timestamp: env.timestamp}
        end
      end
    end

    # Count of frozen messages.
    def frozen_count : Int32
      @mutex.synchronize { @frozen.size }
    end

    # -- Persistence lifecycle hooks (no-ops by default, overridden by persistence module) --

    protected def on_deliver(envelope : Envelope); end
    protected def on_consume(envelope : Envelope); end
    protected def on_freeze(id : String, by : String); end
    protected def on_thaw(id : String); end

    # -- Snapshot dump/load --

    # Snapshot the mailbox's full state for persistence.
    def dump : NamedTuple(messages: Array(Envelope), frozen: Hash(String, Envelope), frozen_by: Hash(String, String))
      @mutex.synchronize do
        {
          messages:  @messages.to_a,
          frozen:    @frozen.dup,
          frozen_by: @frozen_by.dup,
        }
      end
    end

    # Restore mailbox state from a snapshot. Replaces existing state.
    def load_snapshot(messages : Array(Envelope), frozen : Hash(String, Envelope), frozen_by : Hash(String, String))
      @mutex.synchronize do
        @messages.clear
        messages.each { |env| @messages.push(env) }
        @frozen = frozen.dup
        @frozen_by = frozen_by.dup
      end
    end
  end
end
