require "./spec_helper"

describe Arcana::Protocol do
  describe ".request" do
    it "wraps data with protocol metadata" do
      payload = Arcana::Protocol.request(JSON::Any.new("hello"), intent: "greet")
      Arcana::Protocol.proto?(payload).should be_true
      Arcana::Protocol.request?(payload).should be_true
      Arcana::Protocol.data(payload).not_nil!.as_s.should eq("hello")
      Arcana::Protocol.intent(payload).should eq("greet")
    end
  end

  describe ".result" do
    it "wraps data as a result" do
      payload = Arcana::Protocol.result(JSON::Any.new(42))
      Arcana::Protocol.proto?(payload).should be_true
      Arcana::Protocol.result?(payload).should be_true
      Arcana::Protocol.data(payload).not_nil!.as_i.should eq(42)
    end
  end

  describe ".need" do
    it "includes schema when provided" do
      schema = JSON.parse(%({"type":"object","required":["name"]}))
      payload = Arcana::Protocol.need(schema: schema, message: "Missing name")
      Arcana::Protocol.need?(payload).should be_true
      payload["schema"]["required"].as_a.map(&.as_s).should eq(["name"])
      Arcana::Protocol.message(payload).should eq("Missing name")
    end

    it "includes questions when provided" do
      payload = Arcana::Protocol.need(questions: ["What format?", "What size?"])
      payload["questions"].as_a.size.should eq(2)
    end
  end

  describe ".error" do
    it "wraps an error message" do
      payload = Arcana::Protocol.error("something broke", code: "INVALID")
      Arcana::Protocol.error?(payload).should be_true
      Arcana::Protocol.message(payload).should eq("something broke")
      payload["_code"].as_s.should eq("INVALID")
    end
  end

  describe "readers" do
    it "proto? returns false for non-protocol payloads" do
      Arcana::Protocol.proto?(JSON::Any.new("just a string")).should be_false
      Arcana::Protocol.proto?(JSON::Any.new(42)).should be_false
    end

    it "status returns nil for non-protocol payloads" do
      Arcana::Protocol.status(JSON::Any.new("x")).should be_nil
    end
  end
end
