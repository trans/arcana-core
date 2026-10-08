require "json"

module Arcana
  # Registry of agent and service capabilities.
  #
  # Address format:
  #   - A routing label — any single token matching `[a-z][a-z0-9-]*`, or an
  #     `owner:capability`-style two-token form (both halves matching the
  #     same pattern). Colons in the address are just a naming convention
  #     now, not a type marker.
  #   - Kind (agent vs service) and capability (chat/image/tts/...) are
  #     explicit fields on the listing. Legacy callers that don't set them
  #     get the old behavior: kind is derived from the address (colon =
  #     service), and capability is the substring after the colon.
  #   - Internal ephemeral mailboxes (`_reply:<id>`) are carved out by a
  #     leading underscore and are neither agents nor services.
  class Directory
    # Token body: what an address (or each half of a colon-form address)
    # must match after any leading sigil is stripped.
    NAME_PATTERN = /\A[a-z][a-z0-9-]*\z/

    # Agent handles use the leading `@` sigil so a process representing
    # a conversational identity ("@mj", "@arcana") doesn't collide with
    # a same-project tool service registered at the bare name ("mj",
    # "arcana"). Enforced at `register` time: kind=agent addresses MUST
    # start with `@`, and kind=service addresses MUST NOT. The bus
    # still routes purely on the address string — the sigil is a naming
    # convention that the registration path enforces so senders can
    # tell at a glance who's an agent.
    AGENT_HANDLE_PATTERN = /\A@[a-z][a-z0-9-]*\z/

    enum Kind
      Agent
      Service

      # Best-guess kind from address shape. Used as a fallback when the
      # caller doesn't pass an explicit `kind:`. Precedence:
      #   @foo   → Agent
      #   foo:x  → Service
      #   foo    → Service (bare non-colon defaults to service — a bare
      #           token is a Toolset or single-purpose service; agents
      #           require the `@` sigil).
      def self.from_address(address : String) : self
        return Agent if address.starts_with?('@')
        Service
      end
    end

    struct Listing
      property address : String
      property name : String
      property description : String
      property kind : Kind
      property schema : JSON::Any?
      property guide : String?
      property tags : Array(String)

      # In-memory only. `true` = registered by code inside the daemon
      # (Service.new / Toolset.new); these should NOT be persisted to
      # snapshot, because the code re-registers them on every startup.
      # `false` = registered by a remote client (WS join or POST
      # /register); these ARE persisted so the listing survives a
      # restart until the TTL prunes it. Not serialized to JSON.
      property ephemeral : Bool

      def initialize(
        @address : String,
        @name : String,
        @description : String,
        kind : Kind? = nil,
        @schema : JSON::Any? = nil,
        @guide : String? = nil,
        @tags : Array(String) = [] of String,
        @ephemeral : Bool = false,
      )
        @kind = kind || Kind.from_address(@address)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "address", @address
          json.field "name", @name
          json.field "description", @description
          json.field "kind", @kind.to_s.downcase
          json.field "schema", @schema if @schema
          json.field "guide", @guide if @guide
          json.field "tags", @tags unless @tags.empty?
        end
      end
    end

    @listings = {} of String => Listing
    @busy = {} of String => Bool
    @last_seen = {} of String => Time
    @owner_tokens = {} of String => String
    @offline = Set(String).new
    @mutex = Mutex.new

    # How long an agent listing lives without activity before
    # `prune_stale_agents` drops it. When set, agent listings report
    # `expires_at` (last seen + TTL). The pruner still takes its TTL as
    # an argument; set both to the same value.
    property agent_ttl : Time::Span?

    # Optional event recorder. When set, material directory actions
    # (register, unregister, busy changes, prune) emit events.
    property events : Events::Backend?

    # Is this address a service? (Contains `:` and is not an internal ephemeral.)
    def self.service?(address : String) : Bool
      return false if address.starts_with?('_')
      address.includes?(':')
    end

    # Is this address an agent? (Plain name, no colon.)
    def self.agent?(address : String) : Bool
      return false if address.starts_with?('_')
      !address.includes?(':')
    end

    # Return the owner half of a service address, or nil if not a service.
    def self.owner(address : String) : String?
      return nil unless service?(address)
      address.partition(':').first
    end

    # Validate address format. Raises if malformed. Accepts:
    #   - `foo` — bare single token
    #   - `@foo` — agent-handle single token (leading `@` sigil)
    #   - `owner:capability` — two-token colon form (`@` not allowed here)
    #   - `_reply:<hex>` — internal ephemeral, exempt from validation
    def self.validate_address(address : String) : Nil
      return if address.starts_with?("_reply:") # internal ephemeral

      if address.includes?(':')
        raise Error.new("invalid address #{address.inspect}: `@` sigil is for single-token agent handles, not colon-form service addresses") if address.starts_with?('@')
        parts = address.split(':', 2)
        raise Error.new("invalid address #{address.inspect}: colon-form must be two tokens") unless parts.size == 2
        raise Error.new("invalid first token in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[0] =~ NAME_PATTERN
        raise Error.new("invalid second token in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[1] =~ NAME_PATTERN
      elsif address.starts_with?('@')
        body = address[1..]
        raise Error.new("invalid agent handle #{address.inspect}: `@` must be followed by #{NAME_PATTERN.source}") unless body =~ NAME_PATTERN
      else
        raise Error.new("invalid address #{address.inspect}: must match #{NAME_PATTERN.source}") unless address =~ NAME_PATTERN
      end
    end

    # Does this address use the `@` agent-handle sigil?
    def self.handle?(address : String) : Bool
      address.starts_with?('@')
    end

    # Enforce the sigil convention: agent addresses must use `@`,
    # service addresses must not. Internal `_reply:` mailboxes are
    # never routed through this path.
    private def validate_kind_and_sigil!(address : String, kind : Kind) : Nil
      case kind
      when Kind::Agent
        unless address.starts_with?('@')
          raise Error.new(
            "agent addresses must use the `@` sigil — got #{address.inspect}. " \
            "Register as `@#{address}` instead, or set kind: \"service\" if this is a tool provider."
          )
        end
      when Kind::Service
        if address.starts_with?('@')
          raise Error.new(
            "service addresses must not use the `@` sigil — got #{address.inspect}. " \
            "The `@` prefix is reserved for agent handles. Drop the prefix, or set kind: \"agent\" if this is a conversational identity."
          )
        end
      end
    end

    # Register a listing. Raises if the address is malformed, already
    # taken, or its sigil doesn't match its kind.
    def register(listing : Listing)
      Directory.validate_address(listing.address)
      validate_kind_and_sigil!(listing.address, listing.kind)
      @mutex.synchronize do
        if @listings.has_key?(listing.address)
          raise Error.new("Address already registered: #{listing.address}")
        end
        @listings[listing.address] = listing
        @last_seen[listing.address] = Time.utc
      end
      @events.try &.record(Events::Event.new(
        type: "listing.registered",
        subject: listing.address,
        metadata: {
          "kind" => JSON::Any.new(listing.kind.to_s.downcase),
          "name" => JSON::Any.new(listing.name),
        } of String => JSON::Any,
      ))
    end

    # Raised by `claim` and `check_owner!` when an address is held under
    # an owner token the caller didn't present.
    class HeldError < Error
      getter address : String

      def initialize(@address : String, message : String)
        super(message)
      end
    end

    # What `claim` did.
    enum Claim
      Registered # the address was free
      Yours      # already held under this owner token; listing refreshed
      Claimed    # held without an owner token; now held under this one
    end

    # Register `listing`, or refresh it when `owner_token` shows the
    # caller already holds the address. This is how an agent that
    # forgot it registered (or whose session hook registered for it)
    # tells "that's me" from "someone else has it".
    #
    # - Free address: registered, under `owner_token` if one is given.
    # - Held under the same owner token: the listing is refreshed from
    #   `listing` (fields it leaves out keep their values), marked
    #   online, and its last-seen time updated.
    # - Held without an owner token: taken over under `owner_token`. An
    #   unowned listing protects nothing, so taking it gives nothing away.
    # - Otherwise raises: `HeldError` when another owner token holds it,
    #   `Error` ("Address already registered") when neither side has one.
    def claim(listing : Listing, owner_token : String? = nil) : Claim
      token = owner_token.try(&.presence)
      address = listing.address
      Directory.validate_address(address)
      validate_kind_and_sigil!(address, listing.kind)
      result = @mutex.synchronize do
        outcome = Claim::Registered
        if existing = @listings[address]?
          held = @owner_tokens[address]?
          if held && token == held
            outcome = Claim::Yours
          elsif held
            raise HeldError.new(address, held_message(address, token))
          elsif token
            outcome = Claim::Claimed
          else
            raise Error.new("Address already registered: #{address} (it has no owner token, so the bus can't tell whether it's you)")
          end
          listing = refreshed(existing, listing)
        end
        @listings[address] = listing
        @owner_tokens[address] = token if token
        @last_seen[address] = Time.utc
        @offline.delete(address)
        outcome
      end
      event_type = case result
                   when .yours?   then "listing.refreshed"
                   when .claimed? then "listing.claimed"
                   else                "listing.registered"
                   end
      @events.try &.record(Events::Event.new(
        type: event_type,
        subject: address,
        metadata: {
          "kind" => JSON::Any.new(listing.kind.to_s.downcase),
          "name" => JSON::Any.new(listing.name),
        } of String => JSON::Any,
      ))
      result
    end

    # Raises `HeldError` unless `owner_token` matches the owner token the
    # address is held under. Addresses held without one accept anything.
    def check_owner!(address : String, owner_token : String?) : Nil
      held = @mutex.synchronize { @owner_tokens[address]? }
      return unless held
      return if owner_token == held
      raise HeldError.new(address, held_message(address, owner_token.try(&.presence)))
    end

    # A re-registration refreshes the listing: fields it gives replace
    # the old ones; fields it leaves out (empty description, no schema,
    # guide or tags, name defaulted to the address) keep their values.
    private def refreshed(old : Listing, new : Listing) : Listing
      Listing.new(
        address: new.address,
        name: new.name == new.address ? old.name : new.name,
        description: new.description.empty? ? old.description : new.description,
        kind: new.kind,
        schema: new.schema || old.schema,
        guide: new.guide || old.guide,
        tags: new.tags.empty? ? old.tags : new.tags,
        ephemeral: new.ephemeral,
      )
    end

    private def held_message(address : String, given : String?) : String
      if given
        "#{address} is held by another owner: the owner token doesn't match"
      else
        "#{address} is held by another owner: changing it needs the owner token it was registered with"
      end
    end

    # Owner tokens by address (for snapshot save). Never serialized in
    # directory listings.
    def owner_tokens : Hash(String, String)
      @mutex.synchronize { @owner_tokens.dup }
    end

    # Restore an owner token (for snapshot load).
    def set_owner_token(address : String, token : String) : Nil
      @mutex.synchronize { @owner_tokens[address] = token }
    end

    # Mark a listing online or offline. Offline means no session is
    # running for it; its mailbox keeps collecting mail. `claim` marks
    # it online again.
    def set_online(address : String, online : Bool) : Nil
      changed = @mutex.synchronize do
        raise Error.new("no directory listing for '#{address}'") unless @listings.has_key?(address)
        was_offline = @offline.includes?(address)
        online ? @offline.delete(address) : @offline.add(address)
        was_offline == online
      end
      return unless changed
      @events.try &.record(Events::Event.new(
        type: "listing.online_changed",
        subject: address,
        metadata: {"online" => JSON::Any.new(online)} of String => JSON::Any,
      ))
    end

    def online?(address : String) : Bool
      @mutex.synchronize { !@offline.includes?(address) }
    end

    # Addresses currently marked offline (for snapshot save).
    def offline_addresses : Array(String)
      @mutex.synchronize { @offline.to_a }
    end

    # Replace the tags on an existing listing. No-op if unregistered.
    # Toolset uses this at start time to union user-provided tags with
    # the names of its registered tools.
    def retag(address : String, tags : Array(String)) : Nil
      @mutex.synchronize do
        if listing = @listings[address]?
          listing.tags = tags
          @listings[address] = listing
        end
      end
    end

    # Refresh the last-seen timestamp for an address. No-op if unregistered.
    def touch(address : String)
      @mutex.synchronize do
        @last_seen[address] = Time.utc if @listings.has_key?(address)
      end
    end

    # Get the last-seen timestamp for an address.
    def last_seen(address : String) : Time?
      @mutex.synchronize { @last_seen[address]? }
    end

    # Set the last-seen timestamp directly (used by snapshot restore).
    def set_last_seen(address : String, time : Time)
      @mutex.synchronize { @last_seen[address] = time }
    end

    # Remove agent listings older than `ttl`. Services are never pruned
    # (they get re-registered from code on each startup anyway).
    # Returns the list of pruned addresses.
    #
    # The walk collects candidates under the mutex, releases it, then
    # re-acquires briefly per-address for each delete. Each delete
    # re-verifies staleness — a re-registration between the walk and
    # the delete is respected. Keeps every mutex acquisition O(1),
    # so registration/lookup can slip through even during a large
    # prune sweep.
    def prune_stale_agents(ttl : Time::Span) : Array(String)
      cutoff = Time.utc - ttl

      candidates = @mutex.synchronize do
        result = [] of String
        @listings.each_key do |addr|
          next unless Directory.agent?(addr)
          ts = @last_seen[addr]? || Time.utc
          result << addr if ts < cutoff
        end
        result
      end

      pruned = [] of String
      candidates.each do |addr|
        removed = @mutex.synchronize do
          # Re-verify — a register may have happened between walk and delete.
          ts = @last_seen[addr]?
          if ts && ts < cutoff && Directory.agent?(addr) && @listings.has_key?(addr)
            @listings.delete(addr)
            @busy.delete(addr)
            @last_seen.delete(addr)
            @owner_tokens.delete(addr)
            @offline.delete(addr)
            true
          else
            false
          end
        end
        pruned << addr if removed
      end

      if (recorder = @events) && !pruned.empty?
        pruned.each do |addr|
          recorder.record(Events::Event.new(type: "listing.pruned", subject: addr))
        end
      end
      pruned
    end

    # Remove a listing by address. Idempotent — does nothing if unregistered.
    def unregister(address : String)
      removed = @mutex.synchronize do
        r = @listings.delete(address)
        @busy.delete(address)
        @last_seen.delete(address)
        @owner_tokens.delete(address)
        @offline.delete(address)
        r
      end
      @events.try &.record(Events::Event.new(type: "listing.unregistered", subject: address)) if removed
    end

    # Mark an address as busy or idle.
    def set_busy(address : String, busy : Bool = true)
      prev = @mutex.synchronize do
        raise Error.new("no directory listing for '#{address}'") unless @listings.has_key?(address)
        p = @busy[address]? || false
        @busy[address] = busy
        p
      end
      return if prev == busy
      @events.try &.record(Events::Event.new(
        type: "listing.busy_changed",
        subject: address,
        metadata: {"busy" => JSON::Any.new(busy)} of String => JSON::Any,
      ))
    end

    # Check if an address is currently busy.
    def busy?(address : String) : Bool
      @mutex.synchronize { @busy[address]? || false }
    end

    # Look up a listing by address. Returns nil if not found.
    def lookup(address : String) : Listing?
      @mutex.synchronize { @listings[address]? }
    end

    # List all registered listings.
    def list : Array(Listing)
      @mutex.synchronize { @listings.values }
    end

    # Filter listings by kind.
    def by_kind(kind : Kind) : Array(Listing)
      @mutex.synchronize { @listings.values.select { |l| l.kind == kind } }
    end

    # Filter listings by tag.
    def by_tag(tag : String) : Array(Listing)
      @mutex.synchronize { @listings.values.select { |l| l.tags.includes?(tag) } }
    end


    # Listings provided by a given owner (service address prefix).
    def by_owner(owner : String) : Array(Listing)
      @mutex.synchronize do
        @listings.values.select { |l| Directory.owner(l.address) == owner }
      end
    end

    # Search listings by substring match on name, description, or tags.
    def search(query : String) : Array(Listing)
      q = query.downcase
      @mutex.synchronize do
        @listings.values.select do |l|
          l.name.downcase.includes?(q) ||
            l.description.downcase.includes?(q) ||
            l.tags.any?(&.downcase.includes?(q))
        end
      end
    end

    # Summarize the directory as JSON — useful for injecting into agent prompts.
    def to_json : String
      JSON.build do |json|
        json.array do
          @mutex.synchronize do
            @listings.each_value { |l| listing_to_json(l, json) }
          end
        end
      end
    end

    # Serialize a list of listings with busy status.
    def to_json(listings : Array(Listing)) : String
      JSON.build do |json|
        json.array do
          @mutex.synchronize do
            listings.each { |l| listing_to_json(l, json) }
          end
        end
      end
    end

    # Serialize a single listing with busy status.
    def to_json(listing : Listing) : String
      JSON.build do |json|
        @mutex.synchronize { listing_to_json(listing, json) }
      end
    end

    # Save all listings to a JSON file.
    def save(path : String)
      data = @mutex.synchronize do
        JSON.build do |json|
          json.array do
            @listings.each_value { |l| l.to_json(json) }
          end
        end
      end
      File.write(path, data)
    end

    # Load listings from a JSON file. Skips addresses already registered
    # (so built-in services registered in code take precedence).
    # Tolerates pre-0.14 address formats and rewrites them in-place.
    def load(path : String) : Int32
      return 0 unless File.exists?(path)
      parsed = JSON.parse(File.read(path))
      count = 0
      @mutex.synchronize do
        parsed.as_a.each do |entry|
          original = entry["address"].as_s
          address = Directory.migrate_legacy_address(original)
          unless address
            STDERR.puts "Directory: dropping unmappable legacy address #{original.inspect} (re-register with owner:capability)"
            next
          end
          next if @listings.has_key?(address)
          kind_str = entry["kind"]?.try(&.as_s?)
          kind = case kind_str
                 when "service" then Kind::Service
                 when "agent"   then Kind::Agent
                 end
          # Legacy snapshots may still carry a `capability` field; we ignore
          # it — capability is no longer a first-class Listing field.
          @listings[address] = Listing.new(
            address: address,
            name: entry["name"]?.try(&.as_s?) || address,
            description: entry["description"]?.try(&.as_s?) || "",
            kind: kind,
            schema: entry["schema"]?,
            guide: entry["guide"]?.try(&.as_s?),
            tags: entry["tags"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
          )
          count += 1
        end
      end
      count
    end

    # Migrate a pre-0.14 address to the new format. Returns nil for
    # addresses that can't be sensibly mapped — callers should skip
    # them with a warning rather than fabricate a bogus owner.
    #
    #   "memo:agent"          → "memo"
    #   "chat:openai:service" → "openai:chat"    (owner-first reorder)
    #   "memo:service"        → nil              (no owner in old form — drop)
    #   "owner:cap" / "foo"   → unchanged
    #
    # The owner-less ":service" form was a degenerate case from the
    # original two-token convention. Rewriting it to "<name>:legacy"
    # (as 0.14.0 originally did) preserved the entry but introduced a
    # made-up owner that misleads readers; cleaner to drop and let the
    # registrant re-register with a proper owner:capability.
    #
    # TODO: remove this whole helper in 0.16 once no downstream
    # consumers carry pre-0.14 snapshots.
    def self.migrate_legacy_address(address : String) : String?
      if address.ends_with?(":agent")
        address.rchop(":agent")
      elsif address.ends_with?(":service")
        base = address.rchop(":service")
        if base.includes?(':')
          capability, _, owner = base.partition(':')
          "#{owner}:#{capability}"
        else
          nil # unmappable: no owner in old form
        end
      else
        address
      end
    end

    private def listing_to_json(l : Listing, json : JSON::Builder) : Nil
      json.object do
        json.field "address", l.address
        json.field "name", l.name
        json.field "description", l.description
        json.field "kind", l.kind.to_s.downcase
        json.field "busy", @busy[l.address]? || false
        if l.kind.agent?
          json.field "online", !@offline.includes?(l.address)
          if seen = @last_seen[l.address]?
            json.field "last_seen", seen.to_rfc3339
            if ttl = @agent_ttl
              json.field "expires_at", (seen + ttl).to_rfc3339
            end
          end
        end
        json.field "schema", l.schema if l.schema
        json.field "guide", l.guide if l.guide
        json.field "tags", l.tags unless l.tags.empty?
      end
    end
  end
end
