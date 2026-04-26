require "./spec_helper"

describe Arcana::Directory do
  it "registers and looks up listings" do
    dir = Arcana::Directory.new
    listing = Arcana::Directory::Listing.new(
      address: "arcana:resizer",
      name: "Image Resizer",
      description: "Resizes images",
    )
    dir.register(listing)
    dir.lookup("arcana:resizer").should_not be_nil
    dir.lookup("arcana:resizer").not_nil!.name.should eq("Image Resizer")
  end

  it "unregisters listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "arcana:tmp", name: "Tmp", description: "temp",
    ))
    dir.unregister("arcana:tmp")
    dir.lookup("arcana:tmp").should be_nil
  end

  it "lists all listings" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new(
      address: "a", name: "A", description: "a",
    ))
    dir.register(Arcana::Directory::Listing.new(
      address: "arcana:b", name: "B", description: "b",
    ))
    dir.list.size.should eq(2)
  end

  describe "address helpers" do
    it "classifies services and agents by colon" do
      Arcana::Directory.service?("arcana:echo").should be_true
      Arcana::Directory.service?("alice").should be_false
      Arcana::Directory.agent?("alice").should be_true
      Arcana::Directory.agent?("arcana:echo").should be_false
    end

    it "excludes internal ephemerals from both kinds" do
      Arcana::Directory.service?("_reply:abc123").should be_false
      Arcana::Directory.agent?("_reply:abc123").should be_false
    end

    it "decomposes a service into owner and capability" do
      Arcana::Directory.owner("openai:chat").should eq("openai")
      Arcana::Directory.capability("openai:chat").should eq("chat")
      Arcana::Directory.owner("alice").should be_nil
      Arcana::Directory.capability("alice").should be_nil
    end

    it "validates addresses" do
      Arcana::Directory.validate_address("alice")
      Arcana::Directory.validate_address("arcana:echo")
      Arcana::Directory.validate_address("sre-team:monitoring")
      Arcana::Directory.validate_address("_reply:deadbeef")

      expect_raises(Arcana::Error, /invalid agent/) { Arcana::Directory.validate_address("Alice") }
      expect_raises(Arcana::Error, /invalid agent/) { Arcana::Directory.validate_address("123go") }
      expect_raises(Arcana::Error, /invalid capability/) { Arcana::Directory.validate_address("a:b:c") }
      expect_raises(Arcana::Error, /invalid capability/) { Arcana::Directory.validate_address("openai:CHAT") }
    end
  end

  describe "#by_kind" do
    it "filters by agent or service" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "agent1", name: "Agent", description: "smart",
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:svc1", name: "Service", description: "dumb",
      ))

      dir.by_kind(Arcana::Directory::Kind::Agent).size.should eq(1)
      dir.by_kind(Arcana::Directory::Kind::Service).size.should eq(1)
    end
  end

  describe "#by_owner / #by_capability" do
    it "filters services by owner and capability" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(address: "openai:chat", name: "OpenAI Chat", description: "chat"))
      dir.register(Arcana::Directory::Listing.new(address: "openai:tts", name: "OpenAI TTS", description: "tts"))
      dir.register(Arcana::Directory::Listing.new(address: "anthropic:chat", name: "Anthropic Chat", description: "chat"))

      dir.by_owner("openai").size.should eq(2)
      dir.by_capability("chat").size.should eq(2)
    end
  end

  describe "#by_tag" do
    it "filters by tag" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:a", name: "A", description: "a",
        tags: ["image", "resize"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:b", name: "B", description: "b",
        tags: ["audio"],
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
        tags: ["ai", "creative"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:b", name: "File Converter", description: "Converts file formats",
      ))

      dir.search("image").size.should eq(1)
      dir.search("image").first.address.should eq("a")
      dir.search("convert").size.should eq(1)
      dir.search("creative").size.should eq(1)
      dir.search("nonexistent").size.should eq(0)
    end

    it "is case-insensitive" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "Image Generator", description: "...",
      ))
      dir.search("IMAGE").size.should eq(1)
    end
  end

  describe "#busy?" do
    it "defaults to not busy" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:a", name: "A", description: "a",
      ))
      dir.busy?("arcana:a").should be_false
    end

    it "tracks busy state" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:a", name: "A", description: "a",
      ))
      dir.set_busy("arcana:a", true)
      dir.busy?("arcana:a").should be_true
      dir.set_busy("arcana:a", false)
      dir.busy?("arcana:a").should be_false
    end

    it "clears busy on unregister" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:a", name: "A", description: "a",
      ))
      dir.set_busy("arcana:a", true)
      dir.unregister("arcana:a")
      dir.busy?("arcana:a").should be_false
    end

    it "raises when setting busy on address without listing" do
      dir = Arcana::Directory.new
      expect_raises(Exception, /no directory listing/) do
        dir.set_busy("ghost", true)
      end
    end

    it "includes busy in JSON output" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:a", name: "A", description: "a",
      ))
      dir.set_busy("arcana:a", true)
      parsed = JSON.parse(dir.to_json)
      parsed[0]["busy"].as_bool.should be_true
    end
  end

  describe "#to_json" do
    it "serializes all listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "does A",
        tags: ["tag1"],
      ))

      parsed = JSON.parse(dir.to_json)
      parsed.as_a.size.should eq(1)
      parsed[0]["address"].as_s.should eq("a")
      parsed[0]["kind"].as_s.should eq("agent")
      parsed[0]["tags"].as_a.map(&.as_s).should eq(["tag1"])
    end
  end

  describe "save/load" do
    it "saves and loads listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "agent1", name: "Agent One", description: "does stuff",
        tags: ["ai", "test"],
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:svc1", name: "Service One", description: "serves",
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

        svc = dir2.lookup("arcana:svc1")
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
        address: "arcana:builtin", name: "Built-in", description: "original",
      ))

      dir2 = Arcana::Directory.new
      dir2.register(Arcana::Directory::Listing.new(
        address: "arcana:builtin", name: "Persisted", description: "should be skipped",
      ))
      dir2.register(Arcana::Directory::Listing.new(
        address: "external", name: "External", description: "should load",
      ))

      path = File.tempname("arcana-dir", ".json")
      begin
        dir2.save(path)

        count = dir.load(path)
        count.should eq(1)
        dir.list.size.should eq(2)

        dir.lookup("arcana:builtin").not_nil!.name.should eq("Built-in")
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
      ))
      dir.last_seen("a").should_not be_nil
    end

    it "prunes agent listings older than TTL" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "old", name: "Old", description: "old agent",
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "new", name: "New", description: "fresh agent",
      ))
      dir.set_last_seen("old", Time.utc - 2.hours)

      pruned = dir.prune_stale_agents(1.hour)
      pruned.should contain("old")
      pruned.should_not contain("new")
      dir.lookup("old").should be_nil
      dir.lookup("new").should_not be_nil
    end

    it "never prunes service listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:svc", name: "Svc", description: "a service",
      ))
      dir.set_last_seen("arcana:svc", Time.utc - 30.days)
      pruned = dir.prune_stale_agents(1.hour)
      pruned.should be_empty
      dir.lookup("arcana:svc").should_not be_nil
    end

    it "refreshes last_seen via touch" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
      ))
      dir.set_last_seen("a", Time.utc - 1.day)
      dir.touch("a")
      (Time.utc - dir.last_seen("a").not_nil!).should be < 1.second
    end
  end

  describe "legacy address migration" do
    it "migrates old forms during load" do
      Arcana::Directory.migrate_legacy_address("memo:agent").should eq("memo")
      Arcana::Directory.migrate_legacy_address("chat:openai:service").should eq("openai:chat")
      Arcana::Directory.migrate_legacy_address("openai:chat").should eq("openai:chat")
      Arcana::Directory.migrate_legacy_address("alice").should eq("alice")
    end

    it "returns nil for unmappable owner-less services" do
      Arcana::Directory.migrate_legacy_address("memo:service").should be_nil
      Arcana::Directory.migrate_legacy_address("wow:service").should be_nil
    end
  end
end
