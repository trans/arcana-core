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
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "svc", name: "Svc", description: "service",
        kind: Arcana::Directory::Kind::Service,
      ))
      dir.set_last_seen("stale:agent", Time.utc - 2.days)
      dir.set_last_seen("svc:service", Time.utc - 30.days)

      listings, _mailboxes = bus.prune_stale(1.day, 7.days)
      listings.should contain("stale:agent")
      listings.should_not contain("svc:service")
      dir.lookup("svc:service").should_not be_nil
    end

    it "prunes mailboxes after listing is gone and mailbox TTL exceeded" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      mb = bus.mailbox("orphan:agent")
      mb.last_activity = Time.utc - 4.days

      _listings, mailboxes = bus.prune_stale(1.day, 3.days)
      mailboxes.should contain("orphan:agent")
      bus.has_mailbox?("orphan:agent").should be_false
    end

    it "keeps mailboxes while their listing is still registered" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "active", name: "Active", description: "live agent",
        kind: Arcana::Directory::Kind::Agent,
      ))
      mb = bus.mailbox("active:agent")
      mb.last_activity = Time.utc - 30.days # old, but listing is fresh

      _listings, mailboxes = bus.prune_stale(1.day, 3.days)
      mailboxes.should_not contain("active:agent")
    end

    it "refreshes last_seen on send from an address" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "sender", name: "S", description: "s",
        kind: Arcana::Directory::Kind::Agent,
      ))
      dir.register(Arcana::Directory::Listing.new(
        address: "receiver", name: "R", description: "r",
        kind: Arcana::Directory::Kind::Agent,
      ))
      bus.mailbox("receiver:agent")
      dir.set_last_seen("sender:agent", Time.utc - 2.days)

      bus.send(Arcana::Envelope.new(from: "sender:agent", to: "receiver:agent"))
      (Time.utc - dir.last_seen("sender:agent").not_nil!).should be < 1.second
    end

    it "refreshes last_seen on mailbox receive" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      bus.directory = dir

      dir.register(Arcana::Directory::Listing.new(
        address: "a", name: "A", description: "a",
        kind: Arcana::Directory::Kind::Agent,
      ))
      mb = bus.mailbox("a:agent")
      dir.set_last_seen("a:agent", Time.utc - 2.days)

      mb.try_receive # empty, but proves liveness
      (Time.utc - dir.last_seen("a:agent").not_nil!).should be < 1.second
    end
  end
end
