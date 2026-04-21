require "./spec_helper"

describe Arcana::Mailbox do
  it "stores its address" do
    mb = Arcana::Mailbox.new("agent:writer")
    mb.address.should eq("agent:writer")
  end

  it "delivers and receives an envelope" do
    mb = Arcana::Mailbox.new("test")
    env = Arcana::Envelope.new(from: "sender", to: "test", subject: "hello")
    mb.deliver(env)

    received = mb.try_receive
    received.should_not be_nil
    received.not_nil!.subject.should eq("hello")
  end

  it "try_receive returns nil when empty" do
    mb = Arcana::Mailbox.new("test")
    mb.try_receive.should be_nil
  end

  it "receives multiple envelopes in order" do
    mb = Arcana::Mailbox.new("test")
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "first"))
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "second"))

    mb.try_receive.not_nil!.subject.should eq("first")
    mb.try_receive.not_nil!.subject.should eq("second")
    mb.try_receive.should be_nil
  end

  it "receive with timeout returns nil on expiry" do
    mb = Arcana::Mailbox.new("test")
    result = mb.receive(10.milliseconds)
    result.should be_nil
  end

  it "receive with timeout returns envelope if available" do
    mb = Arcana::Mailbox.new("test")
    mb.deliver(Arcana::Envelope.new(from: "a", subject: "quick"))
    result = mb.receive(1.second)
    result.should_not be_nil
    result.not_nil!.subject.should eq("quick")
  end

  describe "#inbox" do
    it "returns empty array when no messages" do
      mb = Arcana::Mailbox.new("test")
      mb.inbox.should be_empty
    end

    it "returns metadata for pending messages without consuming them" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "alice", subject: "greet", correlation_id: "id-1"))
      mb.deliver(Arcana::Envelope.new(from: "bob", subject: "ask", correlation_id: "id-2"))

      listing = mb.inbox
      listing.size.should eq(2)
      listing[0][:from].should eq("alice")
      listing[0][:subject].should eq("greet")
      listing[0][:correlation_id].should eq("id-1")
      listing[1][:from].should eq("bob")
      listing[1][:correlation_id].should eq("id-2")

      # Messages should still be there
      mb.pending.should eq(2)
    end
  end

  describe "#receive(id)" do
    it "selectively receives a message by correlation_id" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", subject: "first", correlation_id: "id-1"))
      mb.deliver(Arcana::Envelope.new(from: "b", subject: "second", correlation_id: "id-2"))
      mb.deliver(Arcana::Envelope.new(from: "c", subject: "third", correlation_id: "id-3"))

      # Receive the middle one
      msg = mb.receive("id-2")
      msg.should_not be_nil
      msg.not_nil!.subject.should eq("second")

      # Other messages still there, in order
      mb.pending.should eq(2)
      mb.try_receive.not_nil!.subject.should eq("first")
      mb.try_receive.not_nil!.subject.should eq("third")
    end

    it "returns nil when id not found" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "id-1"))

      mb.receive("nonexistent").should be_nil
      mb.pending.should eq(1)
    end
  end

  describe "#receive(id, timeout)" do
    it "returns immediately if message already present" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", subject: "waiting", correlation_id: "id-1"))

      msg = mb.receive("id-1", 1.second)
      msg.should_not be_nil
      msg.not_nil!.subject.should eq("waiting")
      mb.pending.should eq(0)
    end

    it "returns nil on timeout when message never arrives" do
      mb = Arcana::Mailbox.new("test")
      msg = mb.receive("id-1", 10.milliseconds)
      msg.should be_nil
    end

    it "blocks until specific message arrives" do
      mb = Arcana::Mailbox.new("test")

      spawn do
        sleep 5.milliseconds
        # Deliver a different message first
        mb.deliver(Arcana::Envelope.new(from: "a", subject: "other", correlation_id: "id-other"))
        sleep 5.milliseconds
        # Then deliver the one we're waiting for
        mb.deliver(Arcana::Envelope.new(from: "b", subject: "target", correlation_id: "id-target"))
      end

      msg = mb.receive("id-target", 1.second)
      msg.should_not be_nil
      msg.not_nil!.subject.should eq("target")
      # The other message should still be in the queue
      mb.pending.should eq(1)
      mb.try_receive.not_nil!.subject.should eq("other")
    end
  end

  describe "expected response tracking" do
    it "starts with zero outstanding" do
      mb = Arcana::Mailbox.new("test")
      mb.outstanding.should eq(0)
    end

    it "tracks expectations" do
      mb = Arcana::Mailbox.new("test")
      mb.expect("corr-1")
      mb.expect("corr-2")
      mb.outstanding.should eq(2)
    end

    it "auto-fulfills on deliver" do
      mb = Arcana::Mailbox.new("test")
      mb.expect("corr-1")
      mb.outstanding.should eq(1)

      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "corr-1"))
      mb.outstanding.should eq(0)
    end

    it "fulfill returns false for unknown correlation_id" do
      mb = Arcana::Mailbox.new("test")
      mb.fulfill("nonexistent").should be_false
    end

    it "await_outstanding returns true when no expectations" do
      mb = Arcana::Mailbox.new("test")
      mb.await_outstanding(10.milliseconds).should be_true
    end

    it "await_outstanding returns false on timeout" do
      mb = Arcana::Mailbox.new("test")
      mb.expect("corr-1")
      mb.await_outstanding(10.milliseconds).should be_false
    end

    it "await_outstanding returns true when fulfilled" do
      mb = Arcana::Mailbox.new("test")
      mb.expect("corr-1")

      spawn do
        sleep 5.milliseconds
        mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "corr-1"))
      end

      mb.await_outstanding(1.second).should be_true
    end
  end

  describe "freeze/thaw" do
    it "freezes a message by correlation_id" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", subject: "hello", correlation_id: "id-1"))
      mb.pending.should eq(1)

      mb.freeze("id-1", "supervisor").should be_true
      mb.pending.should eq(0)
      mb.frozen_count.should eq(1)
    end

    it "frozen messages don't appear in receive" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "id-1"))
      mb.freeze("id-1", "test")

      mb.try_receive.should be_nil
    end

    it "frozen messages don't appear in inbox" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "id-1"))
      mb.freeze("id-1", "test")

      mb.inbox.should be_empty
    end

    it "thaw returns message to deque" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", subject: "hello", correlation_id: "id-1"))
      mb.freeze("id-1", "test")

      env = mb.thaw("id-1")
      env.should_not be_nil
      env.not_nil!.subject.should eq("hello")
      mb.pending.should eq(1)
      mb.frozen_count.should eq(0)
    end

    it "thaw_all returns all frozen messages" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "a", correlation_id: "id-1"))
      mb.deliver(Arcana::Envelope.new(from: "b", correlation_id: "id-2"))
      mb.freeze("id-1", "test")
      mb.freeze("id-2", "test")
      mb.pending.should eq(0)

      mb.thaw_all.should eq(2)
      mb.pending.should eq(2)
      mb.frozen_count.should eq(0)
    end

    it "freeze returns false for unknown id" do
      mb = Arcana::Mailbox.new("test")
      mb.freeze("nonexistent", "test").should be_false
    end

    it "thaw returns nil for unknown id" do
      mb = Arcana::Mailbox.new("test")
      mb.thaw("nonexistent").should be_nil
    end

    it "lists frozen message metadata" do
      mb = Arcana::Mailbox.new("test")
      mb.deliver(Arcana::Envelope.new(from: "alice", subject: "hold", correlation_id: "id-1"))
      mb.freeze("id-1", "supervisor")

      listing = mb.frozen
      listing.size.should eq(1)
      listing[0][:correlation_id].should eq("id-1")
      listing[0][:from].should eq("alice")
      listing[0][:frozen_by].should eq("supervisor")
    end
  end
end
