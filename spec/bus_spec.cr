require "./spec_helper"

describe Arcana::Bus do
  it "creates and retrieves mailboxes" do
    bus = Arcana::Bus.new
    mb = bus.mailbox("agent:writer")
    mb.address.should eq("agent:writer")
    bus.has_mailbox?("agent:writer").should be_true
    bus.has_mailbox?("nobody").should be_false
  end

  it "returns the same mailbox for the same address" do
    bus = Arcana::Bus.new
    mb1 = bus.mailbox("agent:a")
    mb2 = bus.mailbox("agent:a")
    mb1.should be(mb2)
  end

  it "lists addresses" do
    bus = Arcana::Bus.new
    bus.mailbox("beta")
    bus.mailbox("alpha")
    bus.addresses.should eq(["alpha", "beta"])
  end

  it "removes mailboxes" do
    bus = Arcana::Bus.new
    bus.mailbox("temp")
    bus.remove_mailbox("temp")
    bus.has_mailbox?("temp").should be_false
  end

  it "uses custom mailbox factory" do
    custom_called = false
    bus = Arcana::Bus.new
    bus.mailbox_factory = ->(address : String) do
      custom_called = true
      Arcana::Mailbox.new(address).as(Arcana::Mailbox)
    end

    bus.mailbox("test")
    custom_called.should be_true
  end

  it "custom factory mailboxes work for send/receive" do
    bus = Arcana::Bus.new
    bus.mailbox_factory = ->(address : String) { Arcana::Mailbox.new(address).as(Arcana::Mailbox) }

    receiver = bus.mailbox("bob")
    bus.send(Arcana::Envelope.new(from: "alice", to: "bob", subject: "hi"))
    receiver.try_receive.not_nil!.subject.should eq("hi")
  end

  describe "#send" do
    it "delivers to the target mailbox" do
      bus = Arcana::Bus.new
      receiver = bus.mailbox("bob")
      env = Arcana::Envelope.new(from: "alice", to: "bob", subject: "hi")
      bus.send(env)

      msg = receiver.try_receive
      msg.should_not be_nil
      msg.not_nil!.from.should eq("alice")
    end

    it "raises when target mailbox doesn't exist" do
      bus = Arcana::Bus.new
      env = Arcana::Envelope.new(from: "alice", to: "nobody")
      expect_raises(Arcana::Error, /No mailbox/) do
        bus.send(env)
      end
    end
  end

  describe "#send?" do
    it "returns false when target doesn't exist" do
      bus = Arcana::Bus.new
      env = Arcana::Envelope.new(from: "alice", to: "nobody")
      bus.send?(env).should be_false
    end

    it "returns true and delivers when target exists" do
      bus = Arcana::Bus.new
      bus.mailbox("bob")
      env = Arcana::Envelope.new(from: "alice", to: "bob")
      bus.send?(env).should be_true
    end
  end

  describe "pub/sub" do
    it "subscribes and publishes to topics" do
      bus = Arcana::Bus.new
      writer = bus.mailbox("writer")
      editor = bus.mailbox("editor")

      bus.subscribe("draft:ready", "writer")
      bus.subscribe("draft:ready", "editor")

      bus.publish("draft:ready", Arcana::Envelope.new(
        from: "author",
        subject: "draft:ready",
        payload: JSON::Any.new("chapter 1"),
      ))

      writer.try_receive.not_nil!.payload.as_s.should eq("chapter 1")
      editor.try_receive.not_nil!.payload.as_s.should eq("chapter 1")
    end

    it "sets 'to' to each subscriber's address" do
      bus = Arcana::Bus.new
      a = bus.mailbox("a")
      b = bus.mailbox("b")
      bus.subscribe("topic", "a")
      bus.subscribe("topic", "b")

      bus.publish("topic", Arcana::Envelope.new(from: "src"))

      a.try_receive.not_nil!.to.should eq("a")
      b.try_receive.not_nil!.to.should eq("b")
    end

    it "uses topic as subject when subject is empty" do
      bus = Arcana::Bus.new
      mb = bus.mailbox("listener")
      bus.subscribe("events:new", "listener")

      bus.publish("events:new", Arcana::Envelope.new(from: "src"))
      mb.try_receive.not_nil!.subject.should eq("events:new")
    end

    it "unsubscribe stops delivery" do
      bus = Arcana::Bus.new
      mb = bus.mailbox("listener")
      bus.subscribe("topic", "listener")
      bus.unsubscribe("topic", "listener")

      bus.publish("topic", Arcana::Envelope.new(from: "src"))
      mb.try_receive.should be_nil
    end

    it "lists subscribers for a topic" do
      bus = Arcana::Bus.new
      bus.mailbox("a")
      bus.mailbox("b")
      bus.subscribe("topic", "b")
      bus.subscribe("topic", "a")
      bus.subscribers("topic").should eq(["a", "b"])
    end

    it "lists subscriptions for an address" do
      bus = Arcana::Bus.new
      bus.mailbox("agent")
      bus.subscribe("topic1", "agent")
      bus.subscribe("topic2", "agent")
      bus.subscriptions("agent").should contain("topic1")
      bus.subscriptions("agent").should contain("topic2")
    end
  end

  describe "#request" do
    it "sends and waits for a reply" do
      bus = Arcana::Bus.new
      bus.mailbox("client")
      server = bus.mailbox("server")

      # Simulate a server responding in a fiber
      spawn do
        msg = server.receive
        reply = msg.reply(from: "server", payload: JSON::Any.new("pong"))
        bus.send(reply)
      end

      result = bus.request(
        Arcana::Envelope.new(from: "client", to: "server", subject: "ping"),
        timeout: 1.second,
      )

      result.should_not be_nil
      result.not_nil!.payload.as_s.should eq("pong")
    end

    it "returns nil on timeout" do
      bus = Arcana::Bus.new
      bus.mailbox("client")
      bus.mailbox("server")  # server never replies

      result = bus.request(
        Arcana::Envelope.new(from: "client", to: "server"),
        timeout: 10.milliseconds,
      )

      result.should be_nil
    end

    it "cleans up reply mailbox after completion" do
      bus = Arcana::Bus.new
      bus.mailbox("client")
      bus.mailbox("server")

      env = Arcana::Envelope.new(from: "client", to: "server")
      bus.request(env, timeout: 10.milliseconds)

      # Reply mailbox should be cleaned up
      bus.has_mailbox?("_reply:#{env.correlation_id}").should be_false
    end
  end

  describe "stale pruning" do
    it "prunes stale agent listings but keeps services" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "stale", name: "Stale", description: "stale agent",
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "arcana:svc", name: "Svc", description: "service",
      ))
      dir.set_last_seen("stale", Time.utc - 2.days)
      dir.set_last_seen("arcana:svc", Time.utc - 30.days)

      listings, _mailboxes = bus.prune_stale(1.day, 7.days)
      listings.should contain("stale")
      listings.should_not contain("arcana:svc")
      dir.lookup("arcana:svc").should_not be_nil
    end

    it "prunes mailboxes after listing is gone and mailbox TTL exceeded" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      mb = bus.mailbox("orphan")
      mb.last_activity = Time.utc - 4.days

      _listings, mailboxes = bus.prune_stale(1.day, 3.days)
      mailboxes.should contain("orphan")
      bus.has_mailbox?("orphan").should be_false
    end

    it "keeps mailboxes while their listing is still registered" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "active", name: "Active", description: "live agent",
      ))
      mb = bus.mailbox("active")
      mb.last_activity = Time.utc - 30.days # old, but listing is fresh

      _listings, mailboxes = bus.prune_stale(1.day, 3.days)
      mailboxes.should_not contain("active")
    end

    it "refreshes last_seen on send from an address" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "sender", name: "S", description: "s",
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "receiver", name: "R", description: "r",
      ))
      bus.mailbox("receiver")
      dir.set_last_seen("sender", Time.utc - 2.days)

      bus.send(Arcana::Envelope.new(from: "sender", to: "receiver"))
      (Time.utc - dir.last_seen("sender").not_nil!).should be < 1.second
    end

    it "refreshes last_seen on mailbox receive" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
      ))
      mb = bus.mailbox("a")
      dir.set_last_seen("a", Time.utc - 2.days)

      mb.try_receive # empty, but proves liveness
      (Time.utc - dir.last_seen("a").not_nil!).should be < 1.second
    end
  end

  describe "system_topics (sys.message.sent firehose)" do
    it "is off by default — no fanout" do
      bus = Arcana::Bus.new
      bus.mailbox("alice")
      bus.mailbox("bob")
      bus.mailbox("aix")
      bus.subscribe("sys.message.sent", "aix")

      bus.send(Arcana::Envelope.new(from: "alice", to: "bob", correlation_id: "c1"))
      # aix's mailbox stays empty — firehose disabled
      bus.mailbox("aix").pending.should eq(0)
      # bob got the real message
      bus.mailbox("bob").pending.should eq(1)
    end

    it "broadcasts a metadata envelope to sys.message.sent subscribers when enabled" do
      bus = Arcana::Bus.new
      bus.system_topics = true
      bus.mailbox("alice")
      bus.mailbox("bob")
      bus.mailbox("aix")
      bus.subscribe("sys.message.sent", "aix")

      env = Arcana::Envelope.new(
        from: "alice", to: "bob", subject: "hi bob",
        payload: JSON::Any.new({"msg" => JSON::Any.new("hello")}),
        correlation_id: "c1",
      )
      bus.send(env)

      # Real message reached bob
      bus.mailbox("bob").pending.should eq(1)

      # Firehose copy reached aix
      bus.mailbox("aix").pending.should eq(1)
      copy = bus.mailbox("aix").try_receive.not_nil!
      copy.subject.should eq("sys.message.sent")
      copy.correlation_id.should eq("c1")

      data = copy.payload
      data["recipient"].as_s.should eq("bob")
      data["sender"].as_s.should eq("alice")
      data["subject"].as_s.should eq("hi bob")
      data["correlation_id"].as_s.should eq("c1")
      data["ordering"].as_s.should_not be_empty
      data["timestamp"].as_s.should_not be_empty
    end

    it "does not recurse: sys.* deliveries are not themselves broadcast" do
      bus = Arcana::Bus.new
      bus.system_topics = true
      bus.mailbox("alice")
      bus.mailbox("bob")
      bus.mailbox("aix")
      bus.subscribe("sys.message.sent", "aix")

      bus.send(Arcana::Envelope.new(from: "alice", to: "bob", correlation_id: "c1"))

      # aix got exactly ONE firehose copy (not one + one-about-the-copy...).
      bus.mailbox("aix").pending.should eq(1)
    end

    it "supports multiple subscribers to the firehose" do
      bus = Arcana::Bus.new
      bus.system_topics = true
      bus.mailbox("alice")
      bus.mailbox("bob")
      bus.mailbox("watcher1")
      bus.mailbox("watcher2")
      bus.subscribe("sys.message.sent", "watcher1")
      bus.subscribe("sys.message.sent", "watcher2")

      bus.send(Arcana::Envelope.new(from: "alice", to: "bob", correlation_id: "c1"))
      bus.mailbox("watcher1").pending.should eq(1)
      bus.mailbox("watcher2").pending.should eq(1)
    end
  end
end
