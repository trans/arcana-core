require "./spec_helper"

describe "Arcana::Envelope JSON serialization" do
  it "round-trips through to_json and from_json" do
    original = Arcana::Envelope.new(
      from: "alice",
      to: "bob",
      subject: "greet",
      payload: JSON::Any.new({"msg" => JSON::Any.new("hello")}),
      correlation_id: "abc123",
      reply_to: "alice:reply",
    )

    json = original.to_json
    restored = Arcana::Envelope.from_json(json)

    restored.from.should eq("alice")
    restored.to.should eq("bob")
    restored.subject.should eq("greet")
    restored.payload["msg"].as_s.should eq("hello")
    restored.correlation_id.should eq("abc123")
    restored.reply_to.should eq("alice:reply")
  end

  it "handles missing optional fields" do
    json = %({"from":"a","to":"b"})
    env = Arcana::Envelope.from_json(json)
    env.from.should eq("a")
    env.to.should eq("b")
    env.subject.should eq("")
    env.reply_to.should be_nil
  end

  it "serializes timestamp as RFC 3339" do
    env = Arcana::Envelope.new(from: "a")
    json = JSON.parse(env.to_json)
    json["timestamp"].as_s.should match(/\d{4}-\d{2}-\d{2}T/)
  end

  it "omits reply_to when nil" do
    env = Arcana::Envelope.new(from: "a")
    json = JSON.parse(env.to_json)
    json["reply_to"]?.should be_nil
  end

  it "omits ordering when async (default)" do
    env = Arcana::Envelope.new(from: "a")
    json = JSON.parse(env.to_json)
    json["ordering"]?.should be_nil
  end

  it "includes ordering when sync" do
    env = Arcana::Envelope.new(from: "a", ordering: Arcana::Ordering::Sync)
    json = JSON.parse(env.to_json)
    json["ordering"].as_s.should eq("sync")
  end

  it "round-trips ordering through JSON" do
    env = Arcana::Envelope.new(from: "a", ordering: Arcana::Ordering::Sync)
    restored = Arcana::Envelope.from_json(env.to_json)
    restored.ordering.should eq(Arcana::Ordering::Sync)
  end

  it "defaults ordering to auto when absent in JSON" do
    json = %({"from":"a"})
    env = Arcana::Envelope.from_json(json)
    env.ordering.should eq(Arcana::Ordering::Auto)
  end
end
