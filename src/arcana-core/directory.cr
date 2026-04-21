require "json"

module Arcana
  # Registry of agent and service capabilities.
  #
  # Addresses are qualified by kind: "name:agent" or "name:service".
  # Registration always produces a qualified address. Lookups accept
  # either qualified or bare names — bare names resolve if unambiguous.
  class Directory
    enum Kind
      Agent
      Service
    end

    struct Listing
      property address : String
      property name : String
      property description : String
      property kind : Kind
      property schema : JSON::Any?    # input schema (services) or hints (agents)
      property guide : String?        # how-to guide (natural language)
      property tags : Array(String)

      def initialize(
        @address : String,
        @name : String,
        @description : String,
        @kind : Kind,
        @schema : JSON::Any? = nil,
        @guide : String? = nil,
        @tags : Array(String) = [] of String,
      )
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
    @mutex = Mutex.new

    # Build a qualified address from a bare name and kind.
    def self.qualify(name : String, kind : Kind) : String
      bare = bare_name(name)
      "#{bare}:#{kind.to_s.downcase}"
    end

    # Extract the bare name from an address (qualified or not).
    def self.bare_name(address : String) : String
      if address.ends_with?(":agent") || address.ends_with?(":service")
        address.rpartition(':').first
      else
        address
      end
    end

    # Check if an address is already qualified.
    def self.qualified?(address : String) : Bool
      address.ends_with?(":agent") || address.ends_with?(":service")
    end

    # Register a listing. The address is auto-qualified by kind.
    # Raises if the qualified address is already taken.
    def register(listing : Listing)
      qualified = Directory.qualify(listing.address, listing.kind)
      @mutex.synchronize do
        if @listings.has_key?(qualified)
          raise Error.new("Address already registered: #{qualified}")
        end
        entry = Listing.new(
          address: qualified,
          name: listing.name,
          description: listing.description,
          kind: listing.kind,
          schema: listing.schema,
          guide: listing.guide,
          tags: listing.tags,
        )
        @listings[qualified] = entry
        @last_seen[qualified] = Time.utc
      end
    end

    # Refresh the last-seen timestamp for an address. No-op if unregistered.
    def touch(address : String)
      resolved = resolve?(address)
      return unless resolved
      @mutex.synchronize { @last_seen[resolved] = Time.utc }
    end

    # Get the last-seen timestamp for an address.
    def last_seen(address : String) : Time?
      resolved = resolve?(address) || address
      @mutex.synchronize { @last_seen[resolved]? }
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
        @listings.each do |addr, listing|
          next unless listing.kind.agent?
          ts = @last_seen[addr]? || Time.utc
          if ts < cutoff
            pruned << addr
          end
        end
        pruned.each do |addr|
          @listings.delete(addr)
          @busy.delete(addr)
          @last_seen.delete(addr)
        end
      end
      pruned
    end

    # Remove a listing by address (qualified or bare).
    # Idempotent — does nothing if the address isn't registered.
    # Raises only if a bare name is ambiguous.
    def unregister(address : String)
      resolved = resolve?(address)
      return unless resolved
      @mutex.synchronize do
        @listings.delete(resolved)
        @busy.delete(resolved)
        @last_seen.delete(resolved)
      end
    end

    # Mark an address as busy or idle.
    def set_busy(address : String, busy : Bool = true)
      resolved = resolve(address)
      @mutex.synchronize do
        raise "no directory listing for '#{resolved}'" unless @listings.has_key?(resolved)
        @busy[resolved] = busy
      end
    end

    # Check if an address is currently busy.
    def busy?(address : String) : Bool
      resolved = resolve?(address) || address
      @mutex.synchronize { @busy[resolved]? || false }
    end

    # Look up a listing by address (qualified or bare).
    # Bare names are resolved; returns nil if not found, raises if ambiguous.
    def lookup(address : String) : Listing?
      resolved = resolve?(address)
      return nil unless resolved
      @mutex.synchronize { @listings[resolved]? }
    end

    # Resolve a bare or qualified address to its qualified form.
    # Returns nil if not found. Raises if bare name is ambiguous.
    def resolve?(address : String) : String?
      @mutex.synchronize do
        # Try exact match first (already qualified, or legacy)
        return address if @listings.has_key?(address)

        # If already qualified, not found
        return nil if Directory.qualified?(address)

        # Bare name — look for matches
        agent_key = "#{address}:agent"
        service_key = "#{address}:service"
        has_agent = @listings.has_key?(agent_key)
        has_service = @listings.has_key?(service_key)

        if has_agent && has_service
          raise Error.new("Ambiguous address '#{address}' — use '#{agent_key}' or '#{service_key}'")
        elsif has_agent
          agent_key
        elsif has_service
          service_key
        else
          nil
        end
      end
    end

    # Resolve a bare or qualified address. Raises if not found or ambiguous.
    def resolve(address : String) : String
      resolve?(address) || raise Error.new("Address not found: #{address}")
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
            @listings.each_value do |l|
              listing_to_json(l, json)
            end
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
    def load(path : String) : Int32
      return 0 unless File.exists?(path)
      parsed = JSON.parse(File.read(path))
      count = 0
      @mutex.synchronize do
        parsed.as_a.each do |entry|
          raw_address = entry["address"].as_s
          kind = entry["kind"]?.try(&.as_s?) == "service" ? Kind::Service : Kind::Agent
          qualified = Directory.qualify(raw_address, kind)
          next if @listings.has_key?(qualified)
          @listings[qualified] = Listing.new(
            address: qualified,
            name: entry["name"]?.try(&.as_s?) || Directory.bare_name(raw_address),
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
