require "json"

module Arcana
  # Registry of agent and service capabilities.
  #
  # Address format:
  #   - Agent: a single token, `[a-z][a-z0-9-]*` (e.g. "alice", "memo", "wow").
  #   - Service: "owner:capability", both halves matching the agent-name pattern.
  #     Reads possessively — "arcana:echo" means "arcana's echo service."
  #
  # The colon in a service address is the ground truth for service vs. agent.
  # Internal ephemeral mailboxes (`_reply:<id>`) are carved out by a leading
  # underscore and are neither agents nor services.
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
      property schema : JSON::Any?
      property guide : String?
      property tags : Array(String)

      def initialize(
        @address : String,
        @name : String,
        @description : String,
        @schema : JSON::Any? = nil,
        @guide : String? = nil,
        @tags : Array(String) = [] of String,
      )
      end

      # Derived from the address. Service if address contains a colon.
      def kind : Kind
        Kind.from_address(@address)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "address", @address
          json.field "name", @name
          json.field "description", @description
          json.field "kind", kind.to_s.downcase
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

    # Validate address format. Raises if malformed.
    def self.validate_address(address : String) : Nil
      return if address.starts_with?("_reply:") # internal ephemeral

      if address.includes?(':')
        parts = address.split(':', 2)
        raise Error.new("invalid service address #{address.inspect}: expected owner:capability") unless parts.size == 2
        raise Error.new("invalid owner in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[0] =~ NAME_PATTERN
        raise Error.new("invalid capability in #{address.inspect}: must match #{NAME_PATTERN.source}") unless parts[1] =~ NAME_PATTERN
      else
        raise Error.new("invalid agent address #{address.inspect}: must match #{NAME_PATTERN.source}") unless address =~ NAME_PATTERN
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
      pruned
    end

    # Remove a listing by address. Idempotent — does nothing if unregistered.
    def unregister(address : String)
      @mutex.synchronize do
        @listings.delete(address)
        @busy.delete(address)
        @last_seen.delete(address)
      end
    end

    # Mark an address as busy or idle.
    def set_busy(address : String, busy : Bool = true)
      @mutex.synchronize do
        raise Error.new("no directory listing for '#{address}'") unless @listings.has_key?(address)
        @busy[address] = busy
      end
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
          address = Directory.migrate_legacy_address(entry["address"].as_s)
          next if @listings.has_key?(address)
          @listings[address] = Listing.new(
            address: address,
            name: entry["name"]?.try(&.as_s?) || address,
            description: entry["description"]?.try(&.as_s?) || "",
            schema: entry["schema"]?,
            guide: entry["guide"]?.try(&.as_s?),
            tags: entry["tags"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String,
          )
          count += 1
        end
      end
      count
    end

    # Migrate a pre-0.14 address to the new format.
    #   "memo:agent"         → "memo"
    #   "chat:openai:service" → "openai:chat"    (owner-first reorder)
    #   "memo:service"        → "memo:legacy"   (no owner in old form — re-register to fix)
    #   "owner:cap" / "foo"   → unchanged
    # TODO: remove in 0.15 once downstream consumers have migrated.
    def self.migrate_legacy_address(address : String) : String
      if address.ends_with?(":agent")
        address.rchop(":agent")
      elsif address.ends_with?(":service")
        base = address.rchop(":service")
        if base.includes?(':')
          capability, _, owner = base.partition(':')
          "#{owner}:#{capability}"
        else
          STDERR.puts "  migration: #{address} → #{base}:legacy (re-register with a proper owner)"
          "#{base}:legacy"
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
        json.field "schema", l.schema if l.schema
        json.field "guide", l.guide if l.guide
        json.field "tags", l.tags unless l.tags.empty?
      end
    end
  end
end
