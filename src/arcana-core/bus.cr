module Arcana
  # Central message router for agent-to-agent communication.
  #
  # Supports direct delivery (send) and topics (publish/subscribe).
  # A `#topic` is a shared log: publishing stores a post once, anyone
  # reads it with `topic_log(topic).read(after:)`, and subscribers get a
  # short notification of each post. Other topic names fan a full copy
  # out to each subscriber (the older form). Addresses are resolved
  # through the directory when available — bare names like "memo"
  # resolve to "memo:agent" or "memo:service" if unambiguous.
  #
  #   bus = Arcana::Bus.new
  #   writer = bus.mailbox("writer:agent")
  #   artist = bus.mailbox("artist:agent")
  #
  #   # Direct message — bare name resolves if unambiguous
  #   bus.send(Envelope.new(from: "writer:agent", to: "artist", ...))
  #
  class Bus
    alias MailboxFactory = Proc(String, Mailbox)

    @mailboxes = {} of String => Mailbox
    @subscriptions = {} of String => Set(String)
    @topics = {} of String => TopicLog
    @mutex = Mutex.new
    getter directory : Directory?

    # Topics are registered in the directory, and their listings show
    # each topic's newest post, so the directory asks the bus for that.
    def directory=(directory : Directory?)
      @directory = directory
      directory.try &.topic_status = ->(address : String) { topic_status(address) }
    end

    # Default max queue length for newly created mailboxes. `nil` means
    # unbounded (the historical default). Set via bin/arcana.cr from
    # ARCANA_MAILBOX_MAX_QUEUE. Mailboxes created with an explicit
    # `max_queue:` via a custom `mailbox_factory` override this.
    property default_max_queue : Int32? = nil

    property mailbox_factory : MailboxFactory = ->(address : String) { Mailbox.new(address).as(Mailbox) }

    # Optional event recorder. When set, material bus actions (sends,
    # publishes, subscribe/unsubscribe, prune) emit events. Newly
    # created mailboxes inherit this recorder via their persistence
    # hooks.
    property events : Events::Backend?

    # When true, every successful send fans out a metadata copy to the
    # `sys.message.sent` topic. Reactive infrastructure (like AIX's
    # tmux bridge) subscribes to it and gets push-quality wake
    # notifications without polling GET /events. Default OFF — enable
    # via ARCANA_SYSTEM_TOPICS=1 in the daemon, or set directly here.
    # Fanout cost: one extra Mailbox#deliver per subscriber per send.
    property system_topics : Bool = false

    # Get or create a mailbox for an address. Topics have none: see
    # `topic_log`.
    def mailbox(address : String) : Mailbox
      raise Error.new("#{address} is a topic, which has a log instead of a mailbox") if Directory.topic?(address)
      @mutex.synchronize do
        mb = @mailboxes[address]?
        unless mb
          mb = @mailbox_factory.call(address)
          # If the factory didn't set a bound, apply the bus-wide default.
          if mb.max_queue.nil? && (default = @default_max_queue)
            mb = Mailbox.new(address, max_queue: default)
          end
          @mailboxes[address] = mb
        end
        if mb.on_activity.nil?
          mb.on_activity = ->(addr : String) {
            @directory.try(&.touch(addr))
            nil
          }
        end
        mb.events ||= @events
        mb
      end
    end

    # Does a mailbox exist for this address?
    def has_mailbox?(address : String) : Bool
      @mutex.synchronize { @mailboxes.has_key?(address) }
    end

    # Remove a mailbox. Messages in flight are lost.
    def remove_mailbox(address : String)
      @mutex.synchronize { @mailboxes.delete(address) }
    end

    # Prune stale agent listings and inactive mailboxes.
    # - Agent listings with last_seen older than `listing_ttl` are removed.
    # - Mailboxes with last_activity older than `mailbox_ttl` are removed.
    # Services are never pruned (they are re-registered from code at startup).
    # Returns {pruned_listings, pruned_mailboxes}.
    def prune_stale(listing_ttl : Time::Span, mailbox_ttl : Time::Span) : {Array(String), Array(String)}
      pruned_listings = [] of String
      if dir = @directory
        pruned_listings = dir.prune_stale_agents(listing_ttl)
      end

      mailbox_cutoff = Time.utc - mailbox_ttl
      stale_mailboxes = [] of String
      @mutex.synchronize do
        @mailboxes.each do |addr, mb|
          next if addr.starts_with?("_reply:")
          # Skip mailboxes whose address still has an active listing
          if dir = @directory
            next if dir.lookup(addr)
          end
          stale_mailboxes << addr if mb.last_activity < mailbox_cutoff
        end
        stale_mailboxes.each { |addr| @mailboxes.delete(addr) }
      end

      {pruned_listings, stale_mailboxes}
    end

    # List all registered addresses.
    def addresses : Array(String)
      @mutex.synchronize { @mailboxes.keys.sort }
    end

    # Pending message count for an address. Returns 0 if no mailbox.
    def pending(address : String) : Int32
      mb = @mutex.synchronize { @mailboxes[address]? }
      mb.try(&.pending) || 0
    end

    # -- Direct delivery --

    # Send an envelope to its `to` address. Raises if no mailbox exists,
    # or `MailboxFull` if the recipient's queue is at capacity.
    def send(envelope : Envelope)
      raise Error.new("#{envelope.to} is a topic: publish to it instead") if Directory.topic?(envelope.to)
      mb = @mutex.synchronize { @mailboxes[envelope.to]? }
      raise Error.new("No mailbox for address: #{envelope.to}") unless mb
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      begin
        mb.deliver(envelope)
      rescue ex : MailboxFull
        record_rejected(envelope, "mailbox_full")
        raise ex
      end
      record_send(envelope)
      broadcast_system_send(envelope) if @system_topics
    end

    # Send, but return false instead of raising when the target mailbox
    # doesn't exist OR is full. Backpressure and missing-address both
    # collapse to "message didn't land" — callers who want to distinguish
    # should use `send` and catch specific errors.
    def send?(envelope : Envelope) : Bool
      mb = @mutex.synchronize { @mailboxes[envelope.to]? }
      return false unless mb
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      begin
        mb.deliver(envelope)
      rescue MailboxFull
        record_rejected(envelope, "mailbox_full")
        return false
      end
      record_send(envelope)
      broadcast_system_send(envelope) if @system_topics
      true
    end

    # Fan a metadata copy of the just-sent envelope to subscribers of
    # `sys.message.sent`. Uses direct mailbox delivery (not publish/
    # send) so there's no recursion back through record_send /
    # broadcast_system_send. Subscribers that can't keep up (MailboxFull)
    # are dropped silently — the firehose is best-effort.
    private def broadcast_system_send(envelope : Envelope) : Nil
      return if envelope.to.starts_with?("sys.") # never fan our own broadcasts
      subs = @mutex.synchronize { @subscriptions["sys.message.sent"]?.try(&.dup) }
      return unless subs && !subs.empty?

      payload = JSON::Any.new({
        "recipient"      => JSON::Any.new(envelope.to),
        "sender"         => JSON::Any.new(envelope.from),
        "ordering"       => JSON::Any.new(envelope.ordering.to_s.downcase),
        "correlation_id" => JSON::Any.new(envelope.correlation_id),
        "subject"        => JSON::Any.new(envelope.subject),
        "timestamp"      => JSON::Any.new(envelope.timestamp.to_rfc3339),
      } of String => JSON::Any)

      subs.each do |sub_addr|
        mb = @mutex.synchronize { @mailboxes[sub_addr]? }
        next unless mb
        copy = Envelope.new(
          from: "sys.message.sent",
          to: sub_addr,
          subject: "sys.message.sent",
          payload: payload,
          correlation_id: envelope.correlation_id,
        )
        begin
          mb.deliver(copy)
        rescue MailboxFull
          # Firehose is best-effort. Subscriber that can't keep up
          # loses this wake — better than blocking the sender.
        end
      end
    end

    private def record_rejected(envelope : Envelope, reason : String)
      @events.try &.record(Events::Event.new(
        type: "message.rejected",
        subject: envelope.to,
        object: (envelope.from.empty? ? nil : envelope.from),
        correlation_id: envelope.correlation_id,
        metadata: {
          "reason"  => JSON::Any.new(reason),
          "subject" => JSON::Any.new(envelope.subject),
        } of String => JSON::Any,
      ))
    end

    private def record_send(envelope : Envelope)
      @events.try &.record(Events::Event.new(
        type: "message.sent",
        subject: envelope.to,
        object: (envelope.from.empty? ? nil : envelope.from),
        correlation_id: envelope.correlation_id,
        metadata: {"subject" => JSON::Any.new(envelope.subject)} of String => JSON::Any,
      ))
    end

    # Send an envelope and register an expectation for a reply on the sender's mailbox.
    # Returns the correlation_id for tracking.
    def send_expecting(envelope : Envelope) : String
      if !envelope.from.empty?
        from_mb = mailbox(envelope.from)
        from_mb.expect(envelope.correlation_id)
      end
      send(envelope)
      envelope.correlation_id
    end

    # -- Topics --

    # The log of a registered `#topic`, created on first use. Raises
    # unless the directory lists `address` as a topic. Its retention
    # follows the listing's.
    def topic_log(address : String) : TopicLog
      listing = @directory.try(&.lookup(address))
      unless listing && listing.kind.topic?
        raise Error.new("no topic #{address} on the bus: register it first, with kind \"topic\"")
      end
      retention = listing.retention || TopicLog::DEFAULT_RETENTION
      log = @mutex.synchronize { @topics[address] ||= TopicLog.new(address, retention) }
      log.retention = retention unless log.retention == retention
      log
    end

    # The log of a `#topic`, if it has one yet.
    def topic_log?(address : String) : TopicLog?
      @mutex.synchronize { @topics[address]? }
    end

    # Every topic log, for a snapshot.
    def topic_logs : Array(TopicLog)
      @mutex.synchronize { @topics.values }
    end

    # Drop a topic's log and subscriptions (when it's unregistered).
    def remove_topic(address : String) : Nil
      @mutex.synchronize do
        @topics.delete(address)
        @subscriptions.delete(address)
      end
    end

    # Set a topic's subscribers as a snapshot recorded them, without the
    # checks `subscribe` makes.
    def restore_subscribers(topic : String, addresses : Array(String)) : Nil
      @mutex.synchronize { @subscriptions[topic] = addresses.to_set }
    end

    # What a topic's directory listing shows: its newest post and how
    # many subscribe. Nil before its log exists.
    def topic_status(address : String) : Directory::TopicStatus?
      log = topic_log?(address)
      return unless log
      Directory::TopicStatus.new(log.head, log.published_at, subscribers(address).size)
    end

    # -- Pub/Sub --

    # Subscribe an address to a topic. For a `#topic`, the topic must be
    # registered and the subscriber must have a mailbox, since that's
    # where notifications go. `cadence` is how often to be told:
    # only `"always"` (on every post) exists so far.
    def subscribe(topic : String, address : String, cadence : String = "always")
      if Directory.topic?(topic)
        topic_log(topic)
        raise Error.new("cadence #{cadence.inspect} isn't implemented yet: only \"always\"") unless cadence == "always"
        raise Error.new("#{address} has no mailbox on the bus to notify: register it first") unless has_mailbox?(address)
      end
      @mutex.synchronize do
        (@subscriptions[topic] ||= Set(String).new) << address
      end
      @directory.try(&.touch(address))
      @events.try &.record(Events::Event.new(type: "subscription.added", subject: topic, object: address))
    end

    # Unsubscribe an address from a topic.
    def unsubscribe(topic : String, address : String)
      removed = @mutex.synchronize do
        set = @subscriptions[topic]?
        set && set.delete(address)
      end
      @events.try &.record(Events::Event.new(type: "subscription.removed", subject: topic, object: address)) if removed
    end

    # List topics an address is subscribed to.
    def subscriptions(address : String) : Array(String)
      @mutex.synchronize do
        @subscriptions.compact_map do |topic, addrs|
          topic if addrs.includes?(address)
        end
      end
    end

    # List subscribers for a topic.
    def subscribers(topic : String) : Array(String)
      @mutex.synchronize do
        @subscriptions[topic]?.try(&.to_a.sort) || [] of String
      end
    end

    # Publish an envelope to a topic.
    #
    # For a `#topic`, the post is stored once in the topic's log and its
    # number returned; each subscriber gets a short notification (see
    # `notify_subscribers`). Raises unless the topic is registered.
    #
    # For any other topic name, each subscriber gets a full copy, with
    # `to` set to its address, and nil is returned.
    def publish(topic : String, envelope : Envelope) : Int64?
      return publish_post(topic, envelope) if Directory.topic?(topic)
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      subs = @mutex.synchronize { @subscriptions[topic]?.try(&.dup) }
      return unless subs

      delivered_to = 0
      subs.each do |address|
        mb = @mutex.synchronize { @mailboxes[address]? }
        next unless mb
        msg = Envelope.new(
          from: envelope.from,
          to: address,
          subject: envelope.subject.empty? ? topic : envelope.subject,
          payload: envelope.payload,
          correlation_id: envelope.correlation_id,
          reply_to: envelope.reply_to,
        )
        mb.deliver(msg)
        delivered_to += 1
      end
      @events.try &.record(Events::Event.new(
        type: "topic.published",
        subject: topic,
        object: (envelope.from.empty? ? nil : envelope.from),
        correlation_id: envelope.correlation_id,
        metadata: {"subscribers" => JSON::Any.new(delivered_to.to_i64)} of String => JSON::Any,
      ))
      nil
    end

    private def publish_post(topic : String, envelope : Envelope) : Int64
      log = topic_log(topic)
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      post = Envelope.new(
        from: envelope.from,
        to: topic,
        subject: envelope.subject,
        payload: envelope.payload,
        correlation_id: envelope.correlation_id,
        reply_to: envelope.reply_to,
        timestamp: envelope.timestamp,
      )
      seq = log.append(post)
      notified = notify_subscribers(topic, post, seq)
      @events.try &.record(Events::Event.new(
        type: "topic.published",
        subject: topic,
        object: (post.from.empty? ? nil : post.from),
        correlation_id: post.correlation_id,
        metadata: {
          "seq"         => JSON::Any.new(seq),
          "subscribers" => JSON::Any.new(notified.to_i64),
        } of String => JSON::Any,
      ))
      seq
    end

    # Tell each subscriber of `topic` about a post, without the post's
    # payload: the notification comes from the topic (so `from` starts
    # with `#`), carries the post's subject, and its payload says where
    # to read the post: `{topic, seq, from, subject, correlation_id}`.
    # Best-effort: a subscriber whose mailbox is full misses the
    # notification, and can still read the post from the log. Returns
    # how many were notified.
    private def notify_subscribers(topic : String, post : Envelope, seq : Int64) : Int32
      subs = @mutex.synchronize { @subscriptions[topic]?.try(&.dup) }
      return 0 unless subs
      payload = JSON::Any.new({
        "topic"          => JSON::Any.new(topic),
        "seq"            => JSON::Any.new(seq),
        "from"           => JSON::Any.new(post.from),
        "subject"        => JSON::Any.new(post.subject),
        "correlation_id" => JSON::Any.new(post.correlation_id),
      } of String => JSON::Any)
      subject = post.subject.empty? ? "post #{seq}" : post.subject
      notified = 0
      subs.each do |address|
        mb = @mutex.synchronize { @mailboxes[address]? }
        next unless mb
        begin
          mb.deliver(Envelope.new(from: topic, to: address, subject: subject, payload: payload))
          notified += 1
        rescue MailboxFull
        end
      end
      notified
    end

    # -- Unified delivery --

    # Resolve ordering: syntactic — service addresses (colon) are sync,
    # agent addresses (no colon) are async.
    def resolve_ordering(envelope : Envelope) : Ordering
      return envelope.ordering unless envelope.ordering.auto?
      Directory.service?(envelope.to) ? Ordering::Sync : Ordering::Async
    end

    # Dispatch based on the envelope's ordering field (auto-resolved).
    # Returns {reply, resolved_ordering}. Reply is nil for async.
    def deliver(envelope : Envelope, timeout : Time::Span = 30.seconds) : {Envelope?, Ordering}
      resolved = resolve_ordering(envelope)
      case resolved
      when Ordering::Sync
        {request(envelope, timeout: timeout), Ordering::Sync}
      else
        send(envelope)
        {nil, Ordering::Async}
      end
    end

    # Like deliver, but silently drops if the target mailbox doesn't exist.
    def deliver?(envelope : Envelope, timeout : Time::Span = 30.seconds) : {Envelope?, Ordering}
      resolved = resolve_ordering(envelope)
      case resolved
      when Ordering::Sync
        {request(envelope, timeout: timeout), Ordering::Sync}
      else
        send?(envelope)
        {nil, Ordering::Async}
      end
    end

    # -- Request/Response --

    # Send an envelope and wait for a reply. Creates a temporary reply
    # mailbox, sets reply_to, and blocks until a response arrives or
    # the timeout expires. The reply mailbox is cleaned up automatically.
    def request(envelope : Envelope, timeout : Time::Span = 30.seconds) : Envelope?
      reply_address = "_reply:#{envelope.correlation_id}"
      reply_mb = mailbox(reply_address)

      msg = Envelope.new(
        from: envelope.from,
        to: envelope.to,
        subject: envelope.subject,
        payload: envelope.payload,
        correlation_id: envelope.correlation_id,
        reply_to: reply_address,
      )

      send(msg)
      result = reply_mb.receive(timeout)
      remove_mailbox(reply_address)
      result
    end
  end
end
