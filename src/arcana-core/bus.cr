module Arcana
  # Central message router for agent-to-agent communication.
  #
  # Supports direct delivery (send) and fan-out (publish/subscribe).
  # Addresses are resolved through the directory when available —
  # bare names like "memo" resolve to "memo:agent" or "memo:service"
  # if unambiguous.
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
    @mutex = Mutex.new
    property directory : Directory?
    property mailbox_factory : MailboxFactory = ->(address : String) { Mailbox.new(address).as(Mailbox) }

    # Resolve an address. Strategy:
    # 1. Try directory resolution (handles bare → qualified)
    # 2. If raw address has a mailbox, use it
    # 3. If a qualified form has a mailbox, use it (raises if ambiguous)
    # 4. Fall back to raw address
    def resolve_address(address : String) : String
      if dir = @directory
        if resolved = dir.resolve?(address)
          return resolved
        end
      end

      @mutex.synchronize do
        return address if @mailboxes.has_key?(address)
        return address if Directory.qualified?(address)

        agent_key = "#{address}:agent"
        service_key = "#{address}:service"
        has_agent = @mailboxes.has_key?(agent_key)
        has_service = @mailboxes.has_key?(service_key)

        if has_agent && has_service
          raise Error.new("Ambiguous address '#{address}' — use '#{agent_key}' or '#{service_key}'")
        elsif has_agent
          agent_key
        elsif has_service
          service_key
        else
          address
        end
      end
    end

    # Get or create a mailbox for an address.
    def mailbox(address : String) : Mailbox
      @mutex.synchronize do
        mb = @mailboxes[address] ||= @mailbox_factory.call(address)
        if mb.on_activity.nil?
          mb.on_activity = ->(addr : String) {
            @directory.try(&.touch(addr))
            nil
          }
        end
        mb
      end
    end

    # Does a mailbox exist for this address?
    def has_mailbox?(address : String) : Bool
      resolved = resolve_address(address)
      @mutex.synchronize { @mailboxes.has_key?(resolved) }
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
      resolved = resolve_address(address)
      mb = @mutex.synchronize { @mailboxes[resolved]? }
      mb.try(&.pending) || 0
    end

    # -- Direct delivery --

    # Send an envelope to its `to` address.
    def send(envelope : Envelope)
      resolved = resolve_address(envelope.to)
      mb = @mutex.synchronize { @mailboxes[resolved]? }
      raise Error.new("No mailbox for address: #{envelope.to}") unless mb
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      mb.deliver(envelope)
    end

    # Send, but silently drop if the target mailbox doesn't exist.
    def send?(envelope : Envelope) : Bool
      resolved = resolve_address(envelope.to)
      mb = @mutex.synchronize { @mailboxes[resolved]? }
      return false unless mb
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      mb.deliver(envelope)
      true
    end

    # Send an envelope and register an expectation for a reply on the sender's mailbox.
    # Returns the correlation_id for tracking.
    def send_expecting(envelope : Envelope) : String
      if !envelope.from.empty?
        from_resolved = resolve_address(envelope.from)
        from_mb = mailbox(from_resolved)
        from_mb.expect(envelope.correlation_id)
      end
      send(envelope)
      envelope.correlation_id
    end

    # -- Pub/Sub --

    # Subscribe an address to a topic.
    def subscribe(topic : String, address : String)
      @mutex.synchronize do
        (@subscriptions[topic] ||= Set(String).new) << address
      end
      @directory.try(&.touch(address))
    end

    # Unsubscribe an address from a topic.
    def unsubscribe(topic : String, address : String)
      @mutex.synchronize do
        @subscriptions[topic]?.try(&.delete(address))
      end
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

    # Publish an envelope to all subscribers of a topic.
    # The envelope's `to` is set to each subscriber's address on delivery.
    def publish(topic : String, envelope : Envelope)
      @directory.try(&.touch(envelope.from)) unless envelope.from.empty?
      subs = @mutex.synchronize { @subscriptions[topic]?.try(&.dup) }
      return unless subs

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
      end
    end

    # -- Unified delivery --

    # Resolve ordering: Auto looks up target kind in the directory.
    # Service → Sync, Agent (or unknown) → Async.
    def resolve_ordering(envelope : Envelope) : Ordering
      return envelope.ordering unless envelope.ordering.auto?
      if dir = @directory
        resolved = dir.resolve?(envelope.to)
        if resolved && (listing = dir.lookup(resolved))
          return listing.kind.service? ? Ordering::Sync : Ordering::Async
        end
      end
      Ordering::Async
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
