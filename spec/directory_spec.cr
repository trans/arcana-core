require "./spec_helper"

describe Arcana::Directory do
  it "registers and looks up listings" do
    dir = Arcana::Directory.new
    listing = Arcana::Directory::Listing.new(
      address: "resizer",
      name: "Image Resizer",
      description: "Resizes images",
      kind: Arcana::Directory::Kind::Service,
    )
    dir.register(listing)
    dir.lookup("resizer").should_not be_nil
    dir.lookup("resizer").not_nil!.name.should eq("Image Resizer")
  end

  it "unregisters listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "tmp", name: "Tmp", description: "temp",
      kind: Arcana::Directory::Kind::Service,
    ))
    dir.unregister("tmp")
    dir.lookup("tmp").should be_nil
  end

  it "lists all listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "a", name: "A", description: "a",
      kind: Arcana::Directory::Kind::Agent,
    ))
    dir.register(Arcana::Directory::Listing.new(
      address: "b", name: "B", description: "b",
      kind: Arcana::Directory::Kind::Service,
    ))
    dir.list.size.should eq(2)
  end

  describe "#by_kind" do
    it "filters by agent or service" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "agent1", name: "Agent", description: "smart",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "svc1", name: "Service", description: "dumb",
        kind: Arcana::Directory::Kind::Service,
      ))

      dir.by_kind(Arcana::Directory::Kind::Agent).size.should eq(1)
      dir.by_kind(Arcana::Directory::Kind::Service).size.should eq(1)
    end
  end

  describe "#by_tag" do
    it "filters by tag" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service, tags: ["image", "resize"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "b", name: "B", description: "b",
        kind: Arcana::Directory::Kind::Service, tags: ["audio"],
      ))

      dir.by_tag("image").size.should eq(1)
      dir.by_tag("audio").size.should eq(1)
      dir.by_tag("video").size.should eq(0)
    end
  end

  describe "#search" do
    it "matches on name, description, and tags" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "Image Generator", description: "Creates images from prompts",
        kind: Arcana::Directory::Kind::Agent, tags: ["ai", "creative"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "b", name: "File Converter", description: "Converts file formats",
        kind: Arcana::Directory::Kind::Service,
      ))

      dir.search("image").size.should eq(1)
      dir.search("image").first.address.should eq("a:agent")
      dir.search("convert").size.should eq(1)
      dir.search("creative").size.should eq(1)
      dir.search("nonexistent").size.should eq(0)
    end

    it "is case-insensitive" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "Image Generator", description: "...",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.search("IMAGE").size.should eq(1)
    end
  end

  describe "#busy?" do
    it "defaults to not busy" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.busy?("a").should be_false
    end

    it "tracks busy state" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      dir.busy?("a").should be_true
      dir.set_busy("a", false)
      dir.busy?("a").should be_false
    end

    it "clears busy on unregister" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      dir.unregister("a")
      dir.busy?("a").should be_false
    end

    it "raises when setting busy on address without listing" do
      dir = Arcana::Directory.new
      expect_raises(Exception, "Address not found: ghost") do
        dir.set_busy("ghost", true)
      end
    end

    it "includes busy in JSON output" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_busy("a", true)
      parsed = JSON.parse(dir.to_json)
      parsed[0]["busy"].as_bool.should be_true
    end
  end

  describe "#to_json" do
    it "serializes all listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "does A",
        kind: Arcana::Directory::Kind::Agent, tags: ["tag1"],
      ))

      parsed = JSON.parse(dir.to_json)
      parsed.as_a.size.should eq(1)
      parsed[0]["address"].as_s.should eq("a:agent")
      parsed[0]["kind"].as_s.should eq("agent")
      parsed[0]["tags"].as_a.map(&.as_s).should eq(["tag1"])
    end
  end

  describe "save/load" do
    it "saves and loads listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "agent1", name: "Agent One", description: "does stuff",
        kind: Arcana::Directory::Kind::Agent, tags: ["ai", "test"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "svc1", name: "Service One", description: "serves",
        kind: Arcana::Directory::Kind::Service,
        guide: "Send anything",
      ))

      path = File.tempname("arcana-dir", ".json")
      begin
        dir.save(path)

        dir2 = Arcana::Directory.new
        count = dir2.load(path)
        count.should eq(2)
        dir2.list.size.should eq(2)

        agent = dir2.lookup("agent1")
        agent.should_not be_nil
        agent.not_nil!.name.should eq("Agent One")
        agent.not_nil!.kind.should eq(Arcana::Directory::Kind::Agent)
        agent.not_nil!.tags.should eq(["ai", "test"])

        svc = dir2.lookup("svc1")
        svc.should_not be_nil
        svc.not_nil!.kind.should eq(Arcana::Directory::Kind::Service)
        svc.not_nil!.guide.should eq("Send anything")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "skips addresses already registered" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "builtin", name: "Built-in", description: "original",
        kind: Arcana::Directory::Kind::Service,
      ))

      # Save a file with a conflicting address (same kind → same qualified name)
      dir2 = Arcana::Directory.new
      dir2.register(Arcana::Directory::Listing.new(
        address: "builtin", name: "Persisted", description: "should be skipped",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir2.register(Arcana::Directory::Listing.new(
        address: "external", name: "External", description: "should load",
        kind: Arcana::Directory::Kind::Agent,
      ))

      path = File.tempname("arcana-dir", ".json")
      begin
        dir2.save(path)

        count = dir.load(path)
        count.should eq(1) # only "external" loaded
        dir.list.size.should eq(2)

        # Built-in should keep original values
        dir.lookup("builtin").not_nil!.name.should eq("Built-in")
        dir.lookup("builtin").not_nil!.kind.should eq(Arcana::Directory::Kind::Service)

        # External should be loaded
        dir.lookup("external").not_nil!.name.should eq("External")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "returns 0 when file doesn't exist" do
      dir = Arcana::Directory.new
      dir.load("/nonexistent/path.json").should eq(0)
    end
  end

  describe "stale pruning" do
    it "touches last_seen on registration" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.last_seen("a:agent").should_not be_nil
    end

    it "prunes agent listings older than TTL" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "old", name: "Old", description: "old agent",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "new", name: "New", description: "fresh agent",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.set_last_seen("old:agent", Time.utc - 2.hours)

      pruned = dir.prune_stale_agents(1.hour)
      pruned.should contain("old:agent")
      pruned.should_not contain("new:agent")
      dir.lookup("old:agent").should be_nil
      dir.lookup("new:agent").should_not be_nil
    end

    it "never prunes service listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "svc", name: "Svc", description: "a service",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_last_seen("svc:service", Time.utc - 30.days)
      pruned = dir.prune_stale_agents(1.hour)
      pruned.should be_empty
      dir.lookup("svc:service").should_not be_nil
    end

    it "refreshes last_seen via touch" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.set_last_seen("a:agent", Time.utc - 1.day)
      dir.touch("a:agent")
      (Time.utc - dir.last_seen("a:agent").not_nil!).should be < 1.second
    end
  end
end
