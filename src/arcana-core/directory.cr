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
    NAME_PATTERN = /\A[a-z][a-z0-9-]*\z/

    enum Kind
      Agent
      Service

      def self.from_address(address : String) : self
        Directory.service?(address) ? Service : Agent
      end
    end

    struct Listing
      property address : String
      property name : String
      property description : String
      property kind : Kind
      property capability : String?
      property schema : JSON::Any?
      property guide : String?
      property tags : Array(String)

      def initialize(
        @address : String,
        @name : String,
        @description : String,
        kind : Kind? = nil,
        capability : String? = nil,
        @schema : JSON::Any? = nil,
        @guide : String? = nil,
        @tags : Array(String) = [] of String,
      )
        @kind = kind || Kind.from_address(@address)
        @capability = capability || Directory.capability(@address)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "address", @address
          json.field "name", @name
          json.field "description", @description
          json.field "kind", @kind.to_s.downcase
          json.field "capability", @capability if @capability
          json.field "schema", @schema if @schema
          json.field "guide", @guide if @guide
          json.field "tags", @tags unless @tags.empty?
        end
      end
    end

    @listings = {} of String => Listing
    @busy = {} of String => Bool
    @last_seen = {} of String => Time
    @mutex = Mutex.new

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

    # Return the capability half of a service address, or nil if not a service.
    def self.capability(address : String) : String?
      return nil unless service?(address)
      address.partition(':').last
    end

    # Validate address format. Raises if malformed. Accepts either a single
    # token or an `owner:capability`-style two-token form; kind is no longer
    # inferred here, so a colon in the address is just a naming convention.
    def self.validate_address(address : String) : Nil
      return if address.starts_with?("_reply:") # internal ephemeral

      if address.includes?(':')
        parts = address.split(':', 2)
        raise Error.new("invalid address #{address.inspect}: colon-form must be two tokens") unless parts.size == 2
        raise Error.new("invalid first token in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[0] =~ NAME_PATTERN
        raise Error.new("invalid second token in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[1] =~ NAME_PATTERN
      else
        raise Error.new("invalid address #{address.inspect}: must match #{NAME_PATTERN.source}") unless address =~ NAME_PATTERN
      end
    end

    # Register a listing. Raises if the address is malformed or already taken.
    def register(listing : Listing)
      Directory.validate_address(listing.address)
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
    def prune_stale_agents(ttl : Time::Span) : Array(String)
      cutoff = Time.utc - ttl
      pruned = [] of String
      @mutex.synchronize do
        @listings.each do |addr, _|
          next unless Directory.agent?(addr)
          ts = @last_seen[addr]? || Time.utc
          pruned << addr if ts < cutoff
        end
        pruned.each do |addr|
          @listings.delete(addr)
          @busy.delete(addr)
          @last_seen.delete(addr)
        end
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

    # Listings providing a given capability (service address suffix).
    def by_capability(capability : String) : Array(Listing)
      @mutex.synchronize do
        @listings.values.select { |l| Directory.capability(l.address) == capability }
      end
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
          @listings[address] = Listing.new(
            address: address,
            name: entry["name"]?.try(&.as_s?) || address,
            description: entry["description"]?.try(&.as_s?) || "",
            kind: kind,
            capability: entry["capability"]?.try(&.as_s?),
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
        json.field "capability", l.capability if l.capability
        json.field "busy", @busy[l.address]? || false
        json.field "schema", l.schema if l.schema
        json.field "guide", l.guide if l.guide
        json.field "tags", l.tags unless l.tags.empty?
      end
    end
  end
end
