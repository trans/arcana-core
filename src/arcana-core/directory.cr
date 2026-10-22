require "json"
require "./error"
require "./events"
require "./key"

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
  #   - Topics (`#news`, `#arcana.releases`) are shared logs: see
  #     `TopicLog` and `Bus#publish`. Their names may have dot-separated
  #     parts.
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

    # Topics use the leading `#` sigil, and their names may have
    # dot-separated parts: `#news`, `#arcana.releases`.
    TOPIC_PATTERN = /\A#[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)*\z/

    enum Kind
      Agent
      Service
      Topic

      # Best-guess kind from address shape. Used as a fallback when the
      # caller doesn't pass an explicit `kind:`. Precedence:
      #   @foo   → Agent
      #   #foo   → Topic
      #   foo:x  → Service
      #   foo    → Service (bare non-colon defaults to service — a bare
      #           token is a Toolset or single-purpose service; agents
      #           require the `@` sigil).
      def self.from_address(address : String) : self
        return Agent if address.starts_with?('@')
        return Topic if address.starts_with?('#')
        Service
      end

      # The kind named by `name` ("agent", "service", "topic"), or nil.
      def self.from_name?(name : String?) : self?
        case name
        when "agent"   then Agent
        when "service" then Service
        when "topic"   then Topic
        end
      end
    end

    # What a topic's listing shows beyond its registration: its newest
    # post's number and time, and how many subscribe. The bus that keeps
    # the topics supplies it (see `topic_status`).
    record TopicStatus, last_seq : Int64, last_published_at : Time?, subscribers : Int32

    struct Listing
      property address : String
      property name : String
      property description : String
      property kind : Kind
      property schema : JSON::Any?
      property guide : String?
      property tags : Array(String)

      # How many posts a topic keeps (`TopicLog::DEFAULT_RETENTION` when
      # nil). Topics only.
      property retention : Int32?

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
        @retention : Int32? = nil,
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
          json.field "retention", @retention if @retention
        end
      end
    end

    @listings = {} of String => Listing
    @busy = {} of String => Bool
    @last_seen = {} of String => Time
    @owner_tokens = {} of String => String
    @keys = {} of String => String
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

    # Supplies a topic's `TopicStatus` for its listing. `Bus#directory=`
    # sets it; without it, topic listings show only their registration.
    property topic_status : Proc(String, TopicStatus?)?

    # Is this address a service? (Contains `:` and is not an internal ephemeral.)
    def self.service?(address : String) : Bool
      return false if address.starts_with?('_')
      address.includes?(':')
    end

    # Is this address an agent? (Plain name, no colon.)
    def self.agent?(address : String) : Bool
      return false if address.starts_with?('_') || topic?(address)
      !address.includes?(':')
    end

    # Is this address a topic? (Leading `#` sigil.)
    def self.topic?(address : String) : Bool
      address.starts_with?('#')
    end

    # Return the owner half of a service address, or nil if not a service.
    def self.owner(address : String) : String?
      return nil unless service?(address)
      address.partition(':').first
    end

    # Validate address format. Raises if malformed. Accepts:
    #   - `foo` — bare single token
    #   - `@foo` — agent-handle single token (leading `@` sigil)
    #   - `#foo`, `#foo.bar` — topic (leading `#` sigil, dot-separated parts)
    #   - `owner:capability` — two-token colon form (`@` not allowed here)
    #   - `_reply:<hex>` — internal ephemeral, exempt from validation
    def self.validate_address(address : String) : Nil
      return if address.starts_with?("_reply:") # internal ephemeral

      if address.starts_with?('#')
        raise Error.new("invalid topic #{address.inspect}: `#` must be followed by names matching #{NAME_PATTERN.source}, separated by dots") unless address =~ TOPIC_PATTERN
      elsif address.includes?(':')
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

    # Enforce the sigil convention: agent addresses must use `@`, topic
    # addresses `#`, and service addresses neither. Internal `_reply:`
    # mailboxes are never routed through this path.
    private def validate_kind_and_sigil!(address : String, kind : Kind) : Nil
      case kind
      when Kind::Agent
        if Directory.topic?(address)
          raise Error.new(
            "agent addresses must use the `@` sigil — got #{address.inspect}. " \
            "The `#` prefix is reserved for topics: set kind: \"topic\" to register one."
          )
        end
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
        if Directory.topic?(address)
          raise Error.new(
            "service addresses must not use the `#` sigil — got #{address.inspect}. " \
            "The `#` prefix is reserved for topics: set kind: \"topic\" to register one."
          )
        end
      when Kind::Topic
        unless Directory.topic?(address)
          raise Error.new(
            "topic addresses must use the `#` sigil — got #{address.inspect}. Register as `##{address.lchop('@')}` instead."
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

    # Raised by `claim`, `check_holder!` and `check_owner!` when an
    # address is held under an owner token or a key the caller didn't
    # present.
    class HeldError < Error
      getter address : String

      def initialize(@address : String, message : String)
        super(message)
      end
    end

    # What `claim` did.
    enum Claim
      Registered # the address was free
      Yours      # already held under this owner token or key; listing refreshed
      Claimed    # held by neither; now held under the one given
      Moved      # held under the owner token shown; now held by the key too
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
    #
    # With `key`, a public key the caller has proved it holds (see
    # `Signing`), the address is held by that key instead:
    #
    # - Free, or held by neither a key nor a token: held by the key.
    # - Held by the same key: refreshed (`Yours`).
    # - Held under an owner token, shown here: held by the key too
    #   (`Moved`), so a project's address moves to its key once. Until
    #   owner tokens retire, the token still works for it.
    # - Held by another key, or under a token not shown: `HeldError`.
    #
    # An address held by a key and no token can't be claimed by a token.
    def claim(listing : Listing, owner_token : String? = nil, key : String? = nil) : Claim
      token = owner_token.try(&.presence)
      key = key.try(&.presence)
      raise Error.new("not a public key: #{key}") if key && !Key.valid_public_key?(key)
      address = listing.address
      Directory.validate_address(address)
      validate_kind_and_sigil!(address, listing.kind)
      result = @mutex.synchronize do
        outcome = Claim::Registered
        if existing = @listings[address]?
          outcome = claim_outcome(address, token, key)
          listing = refreshed(existing, listing)
        end
        @listings[address] = listing
        @owner_tokens[address] = token if token && !@owner_tokens.has_key?(address)
        @keys[address] = key if key
        @last_seen[address] = Time.utc
        @offline.delete(address)
        outcome
      end
      event_type = case result
                   when .yours?            then "listing.refreshed"
                   when .claimed?, .moved? then "listing.claimed"
                   else                         "listing.registered"
                   end
      metadata = {
        "kind" => JSON::Any.new(listing.kind.to_s.downcase),
        "name" => JSON::Any.new(listing.name),
      } of String => JSON::Any
      metadata["key"] = JSON::Any.new(key) if key
      @events.try &.record(Events::Event.new(type: event_type, subject: address, metadata: metadata))
      result
    end

    # How a claim of a listed address turns out, or why it can't.
    private def claim_outcome(address : String, token : String?, key : String?) : Claim
      held_token = @owner_tokens[address]?
      held_key = @keys[address]?
      if key
        if held_key
          return Claim::Yours if key == held_key
          raise HeldError.new(address, "#{address} is held by another key")
        end
        return Claim::Claimed unless held_token
        return Claim::Moved if token == held_token
        raise HeldError.new(address, "#{held_message(address, token)}; show it once to move the address to your key")
      end
      if held_key && !held_token
        raise HeldError.new(address, key_held_message(address))
      elsif held_token && token == held_token
        Claim::Yours
      elsif held_token
        raise HeldError.new(address, held_message(address, token))
      elsif token
        Claim::Claimed
      else
        raise Error.new("Address already registered: #{address} (it has no owner token, so the bus can't tell whether it's you)")
      end
    end

    # Is `address` held, under an owner token or by a key?
    def held?(address : String) : Bool
      @mutex.synchronize { @owner_tokens.has_key?(address) || @keys.has_key?(address) }
    end

    # The public key holding `address`, if a key holds it.
    def key_for(address : String) : String?
      @mutex.synchronize { @keys[address]? }
    end

    # Raises `HeldError` unless the caller shows what `address` is held
    # under: its owner token, or the key holding it (one the caller has
    # proved it holds). Addresses held by neither accept anything.
    def check_holder!(address : String, owner_token : String? = nil, key : String? = nil) : Nil
      held_token, held_key = @mutex.synchronize { {@owner_tokens[address]?, @keys[address]?} }
      return unless held_token || held_key
      return if key && key == held_key
      return if owner_token && owner_token == held_token
      message = held_token ? held_message(address, owner_token.try(&.presence)) : key_held_message(address)
      raise HeldError.new(address, message)
    end

    # Raises `HeldError` unless `owner_token` matches the owner token the
    # address is held under. Addresses held by neither a token nor a key
    # accept anything; one held by a key alone needs `check_holder!`.
    def check_owner!(address : String, owner_token : String?) : Nil
      check_holder!(address, owner_token: owner_token)
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
        retention: new.retention || old.retention,
      )
    end

    private def key_held_message(address : String) : String
      "#{address} is held by a key: changing it needs that key's signature"
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

    # Public keys by address (for snapshot save). Listings show them too:
    # a public key is no secret.
    def keys : Hash(String, String)
      @mutex.synchronize { @keys.dup }
    end

    # Restore the key holding an address (for snapshot load).
    def set_key(address : String, key : String) : Nil
      @mutex.synchronize { @keys[address] = key }
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
            @keys.delete(addr)
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
        @keys.delete(address)
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
      to_json(list)
    end

    # Serialize a list of listings with busy status.
    def to_json(listings : Array(Listing)) : String
      statuses = topic_statuses(listings)
      JSON.build do |json|
        json.array do
          @mutex.synchronize do
            listings.each { |l| listing_to_json(l, json, statuses[l.address]?) }
          end
        end
      end
    end

    # Serialize a single listing with busy status.
    def to_json(listing : Listing) : String
      status = topic_statuses([listing])[listing.address]?
      JSON.build do |json|
        @mutex.synchronize { listing_to_json(listing, json, status) }
      end
    end

    # The topics' statuses, fetched before taking the directory's lock:
    # the bus that supplies them takes its own.
    private def topic_statuses(listings : Array(Listing)) : Hash(String, TopicStatus)
      statuses = {} of String => TopicStatus
      if fetch = @topic_status
        listings.each do |l|
          next unless l.kind.topic?
          if status = fetch.call(l.address)
            statuses[l.address] = status
          end
        end
      end
      statuses
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
          kind = Kind.from_name?(entry["kind"]?.try(&.as_s?))
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
            retention: entry["retention"]?.try(&.as_i?),
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

    private def listing_to_json(l : Listing, json : JSON::Builder, status : TopicStatus? = nil) : Nil
      json.object do
        json.field "address", l.address
        json.field "name", l.name
        json.field "description", l.description
        json.field "kind", l.kind.to_s.downcase
        json.field "key", @keys[l.address] if @keys.has_key?(l.address)
        json.field "busy", @busy[l.address]? || false unless l.kind.topic?
        if l.kind.topic?
          # `last_seq` lets a reader see a new post without subscribing:
          # read with `after:` the last number it saw.
          json.field "retention", l.retention || TopicLog::DEFAULT_RETENTION
          json.field "last_seq", status.try(&.last_seq) || 0_i64
          if at = status.try(&.last_published_at)
            json.field "last_published_at", at.to_rfc3339
          end
          json.field "subscribers", status.try(&.subscribers) || 0
        end
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
