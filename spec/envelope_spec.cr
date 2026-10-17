require "./spec_helper"

describe Arcana::Envelope do
  it "generates a unique correlation_id" do
    e1 = Arcana::Envelope.new(from: "a", to: "b")
    e2 = Arcana::Envelope.new(from: "a", to: "b")
    e1.correlation_id.should_not eq(e2.correlation_id)
  end

  it "sets timestamp to now by default" do
    before = Time.utc
    e = Arcana::Envelope.new(from: "a")
    after = Time.utc
    e.timestamp.should be >= before
    e.timestamp.should be <= after
  end

  it "defaults ordering to auto" do
    e = Arcana::Envelope.new(from: "a")
    e.ordering.should eq(Arcana::Ordering::Auto)
  end

  it "accepts ordering parameter" do
    e = Arcana::Envelope.new(from: "a", ordering: Arcana::Ordering::Sync)
    e.ordering.should eq(Arcana::Ordering::Sync)
  end

  describe "id and re" do
    it "takes ids of 8 or more hex digits, and a message's id or a topic post as re" do
      env = Arcana::Envelope.new(from: "@a", id: "8325487c", re: "ab12cd34ef56ab78")
      {env.id, env.re}.should eq({"8325487c", "ab12cd34ef56ab78"})
      Arcana::Envelope.new(from: "@a", re: "#news:12").re.should eq("#news:12")
    end

    it "drops anything else, so nothing can ride into a mail file's headers" do
      env = Arcana::Envelope.new(from: "@a", id: "8325487c\nFrom: @mallory", re: "abc")
      {env.id, env.re}.should eq({nil, nil})
      Arcana::Envelope.new(from: "@a", re: "#news").re.should be_nil
      Arcana::Envelope.new(from: "@a", re: "#news:3\nVia: x").re.should be_nil
      Arcana::Envelope.from_json(%({"from":"@a","id":"xyz","re":42})).id.should be_nil
    end
  end

  describe "#reply" do
    it "creates a reply addressed to reply_to" do
      original = Arcana::Envelope.new(
        from: "alice", to: "bob",
        subject: "question",
        reply_to: "alice:inbox",
        correlation_id: "corr-123",
      )

      reply = original.reply(from: "bob", payload: JSON::Any.new("answer"))
      reply.to.should eq("alice:inbox")
      reply.from.should eq("bob")
      reply.correlation_id.should eq("corr-123")
      reply.subject.should eq("question")
    end

    it "falls back to original sender when no reply_to" do
      original = Arcana::Envelope.new(from: "alice", to: "bob")
      reply = original.reply(from: "bob", payload: JSON::Any.new("hi"))
      reply.to.should eq("alice")
    end

    it "allows overriding subject" do
      original = Arcana::Envelope.new(from: "a", subject: "old")
      reply = original.reply(from: "b", payload: JSON::Any.new(nil), subject: "new")
      reply.subject.should eq("new")
    end
  end
end
