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
      address: "@a", name: "A", description: "a",
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

    it "extracts the owner half of a service address" do
      Arcana::Directory.owner("openai:chat").should eq("openai")
      Arcana::Directory.owner("alice").should be_nil
    end

    it "validates addresses" do
      Arcana::Directory.validate_address("alice")
      Arcana::Directory.validate_address("arcana:echo")
      Arcana::Directory.validate_address("sre-team:monitoring")
      Arcana::Directory.validate_address("_reply:deadbeef")

      expect_raises(Arcana::Error, /invalid address/) { Arcana::Directory.validate_address("Alice") }
      expect_raises(Arcana::Error, /invalid address/) { Arcana::Directory.validate_address("123go") }
      expect_raises(Arcana::Error, /invalid.*token/) { Arcana::Directory.validate_address("a:b:c") }
      expect_raises(Arcana::Error, /invalid.*token/) { Arcana::Directory.validate_address("openai:CHAT") }
    end

    it "accepts @-prefixed agent handles" do
      Arcana::Directory.validate_address("@mj")
      Arcana::Directory.validate_address("@arcana")
      Arcana::Directory.validate_address("@sre-team")
    end

    it "rejects malformed @-handles" do
      expect_raises(Arcana::Error, /invalid agent handle/) { Arcana::Directory.validate_address("@") }
      expect_raises(Arcana::Error, /invalid agent handle/) { Arcana::Directory.validate_address("@Mj") }
      expect_raises(Arcana::Error, /invalid agent handle/) { Arcana::Directory.validate_address("@1mj") }
    end

    it "rejects @ in colon-form service addresses" do
      expect_raises(Arcana::Error, /sigil is for single-token/) do
        Arcana::Directory.validate_address("@openai:chat")
      end
    end

    it "handle? recognizes the @ sigil" do
      Arcana::Directory.handle?("@mj").should be_true
      Arcana::Directory.handle?("mj").should be_false
      Arcana::Directory.handle?("openai:chat").should be_false
    end
  end

  describe "sigil-vs-kind enforcement (post-0.30)" do
    it "rejects a kind=agent registration without the @ sigil" do
      dir = Arcana::Directory.new
      expect_raises(Arcana::Error, /must use the `@` sigil/) do
        dir.register(Arcana::Directory::Listing.new(
          address: "mj", name: "mj", description: "should have been @mj",
          kind: Arcana::Directory::Kind::Agent,
        ))
      end
    end

    it "suggests the @-prefixed alternative in the error message" do
      dir = Arcana::Directory.new
      begin
        dir.register(Arcana::Directory::Listing.new(
          address: "helper", name: "Helper", description: "s",
          kind: Arcana::Directory::Kind::Agent,
        ))
        fail "should have raised"
      rescue ex : Arcana::Error
        ex.message.not_nil!.should contain("@helper")
      end
    end

    it "rejects a kind=service registration WITH the @ sigil" do
      dir = Arcana::Directory.new
      expect_raises(Arcana::Error, /must not use the `@` sigil/) do
        dir.register(Arcana::Directory::Listing.new(
          address: "@openai", name: "OpenAI", description: "s",
          kind: Arcana::Directory::Kind::Service,
        ))
      end
    end

    it "accepts @foo as kind=agent" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "@mj", name: "mj", description: "agent",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.lookup("@mj").not_nil!.kind.should eq(Arcana::Directory::Kind::Agent)
    end

    it "accepts bare or colon-form as kind=service" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana", name: "Arcana", description: "toolset",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "openai:chat", name: "OpenAI Chat", description: "service",
        kind: Arcana::Directory::Kind::Service,
      ))
    end

    it "defaults bare non-colon addresses to kind=service (agents need explicit @)" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana", name: "Arcana", description: "toolset",
        # no kind passed — should default to Service now
      ))
      dir.lookup("arcana").not_nil!.kind.should eq(Arcana::Directory::Kind::Service)
    end
  end

  describe "#by_kind" do
    it "filters by agent or service" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "@agent1", name: "Agent", description: "smart",
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:svc1", name: "Service", description: "dumb",
      ))

      dir.by_kind(Arcana::Directory::Kind::Agent).size.should eq(1)
      dir.by_kind(Arcana::Directory::Kind::Service).size.should eq(1)
    end
  end

  describe "#by_owner" do
    it "filters services by owner (address prefix before colon)" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(address: "openai:chat", name: "OpenAI Chat", description: "chat"))
      dir.register(Arcana::Directory::Listing.new(address: "openai:tts", name: "OpenAI TTS", description: "tts"))
      dir.register(Arcana::Directory::Listing.new(address: "anthropic:chat", name: "Anthropic Chat", description: "chat"))

      dir.by_owner("openai").size.should eq(2)
      dir.by_owner("anthropic").size.should eq(1)
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
        address: "@a", name: "A", description: "does A",
        tags: ["tag1"],
      ))

      parsed = JSON.parse(dir.to_json)
      parsed.as_a.size.should eq(1)
      parsed[0]["address"].as_s.should eq("@a")
      parsed[0]["kind"].as_s.should eq("agent")
      parsed[0]["tags"].as_a.map(&.as_s).should eq(["tag1"])
    end

    it "serializes an explicit-kind service listing" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "openai-chat", name: "OpenAI Chat", description: "chats",
        kind: Arcana::Directory::Kind::Service,
      ))

      parsed = JSON.parse(dir.to_json)
      parsed[0]["kind"].as_s.should eq("service")
      parsed[0]["capability"]?.should be_nil
    end

    it "does not serialize the ephemeral flag (in-memory only)" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "code-svc", name: "Code Service", description: "s",
        kind: Arcana::Directory::Kind::Service,
        ephemeral: true,
      ))

      parsed = JSON.parse(dir.to_json)
      parsed[0]["ephemeral"]?.should be_nil
    end

    it "agent listings have no capability field" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "@cattacula", name: "cattacula", description: "an agent",
      ))

      parsed = JSON.parse(dir.to_json)
      parsed[0]["kind"].as_s.should eq("agent")
      parsed[0]["capability"]?.should be_nil
    end
  end

  describe "save/load" do
    it "saves and loads listings" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(
        address: "@agent1", name: "Agent One", description: "does stuff",
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

        agent = dir2.lookup("@agent1")
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

  describe "claim (owner tokens)" do
    agent = ->(desc : String) {
      Arcana::Directory::Listing.new(address: "@proj", name: "@proj", description: desc)
    }

    it "registers a free address" do
      dir = Arcana::Directory.new
      dir.claim(agent.call("first"), "tok").should eq(Arcana::Directory::Claim::Registered)
      dir.lookup("@proj").not_nil!.description.should eq("first")
      dir.online?("@proj").should be_true
    end

    it "recognizes the same owner token as yours and refreshes the listing" do
      dir = Arcana::Directory.new
      dir.claim(agent.call("first"), "tok")
      dir.set_online("@proj", false)
      dir.claim(agent.call("second"), "tok").should eq(Arcana::Directory::Claim::Yours)
      dir.lookup("@proj").not_nil!.description.should eq("second")
      dir.online?("@proj").should be_true
    end

    it "keeps fields a refresh leaves out" do
      dir = Arcana::Directory.new
      dir.claim(Arcana::Directory::Listing.new(address: "@proj", name: "Proj", description: "full",
        guide: "how", tags: ["x"]), "tok")
      dir.claim(Arcana::Directory::Listing.new(address: "@proj", name: "@proj", description: ""), "tok")
      l = dir.lookup("@proj").not_nil!
      {l.name, l.description, l.guide, l.tags}.should eq({"Proj", "full", "how", ["x"]})
    end

    it "refuses a different owner token, or none" do
      dir = Arcana::Directory.new
      dir.claim(agent.call("first"), "tok")
      expect_raises(Arcana::Directory::HeldError, /owner token doesn't match/) do
        dir.claim(agent.call("intruder"), "other")
      end
      expect_raises(Arcana::Directory::HeldError, /needs the owner token/) do
        dir.claim(agent.call("intruder"), nil)
      end
      dir.lookup("@proj").not_nil!.description.should eq("first")
    end

    it "takes over a listing held without an owner token" do
      dir = Arcana::Directory.new
      dir.register(agent.call("legacy"))
      dir.claim(agent.call("mine"), "tok").should eq(Arcana::Directory::Claim::Claimed)
      expect_raises(Arcana::Directory::HeldError) { dir.claim(agent.call("x"), "other") }
    end

    it "still refuses a tokenless claim on a tokenless listing" do
      dir = Arcana::Directory.new
      dir.register(agent.call("legacy"))
      expect_raises(Arcana::Error, /already registered.*can't tell whether it's you/) do
        dir.claim(agent.call("again"), "")
      end
    end

    it "check_owner! accepts the owner token and unowned listings" do
      dir = Arcana::Directory.new
      dir.claim(agent.call("first"), "tok")
      dir.check_owner!("@proj", "tok")
      expect_raises(Arcana::Directory::HeldError) { dir.check_owner!("@proj", "nope") }
      dir.register(Arcana::Directory::Listing.new(address: "@free", name: "f", description: "f"))
      dir.check_owner!("@free", nil)
    end

    it "forgets the owner token on unregister and prune" do
      dir = Arcana::Directory.new
      dir.claim(agent.call("first"), "tok")
      dir.unregister("@proj")
      dir.claim(agent.call("new"), "other").should eq(Arcana::Directory::Claim::Registered)

      dir.set_last_seen("@proj", Time.utc - 2.hours)
      dir.prune_stale_agents(1.hour).should eq(["@proj"])
      dir.claim(agent.call("newer"), "third").should eq(Arcana::Directory::Claim::Registered)
      dir.owner_tokens.should eq({"@proj" => "third"})
    end
  end

  describe "presence and expiry in listings" do
    it "reports online, last_seen and expires_at for agents" do
      dir = Arcana::Directory.new
      dir.agent_ttl = 1.day
      dir.claim(Arcana::Directory::Listing.new(address: "@proj", name: "p", description: "p"), "tok")
      dir.set_online("@proj", false)

      json = JSON.parse(dir.to_json(dir.lookup("@proj").not_nil!))
      json["online"].as_bool.should be_false
      seen = Time.parse_rfc3339(json["last_seen"].as_s)
      Time.parse_rfc3339(json["expires_at"].as_s).should eq(seen + 1.day)
      json.as_h.has_key?("owner_token").should be_false
    end

    it "omits presence for services and expiry without a TTL" do
      dir = Arcana::Directory.new
      dir.register(Arcana::Directory::Listing.new(address: "svc", name: "s", description: "s"))
      dir.register(Arcana::Directory::Listing.new(address: "@a", name: "a", description: "a"))
      JSON.parse(dir.to_json(dir.lookup("svc").not_nil!)).as_h.has_key?("online").should be_false
      a = JSON.parse(dir.to_json(dir.lookup("@a").not_nil!))
      a["online"].as_bool.should be_true
      a.as_h.has_key?("expires_at").should be_false
    end

    it "raises when setting presence on an unknown address" do
      expect_raises(Arcana::Error, /no directory listing/) do
        Arcana::Directory.new.set_online("@ghost", false)
      end
    end
  end
end
