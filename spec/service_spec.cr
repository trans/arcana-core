require "./spec_helper"

describe Arcana::Service do
  it "registers itself in the directory" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:echo",
      name: "Echo",
      description: "Echoes input back",
    ) { |data| data }

    listing = dir.lookup("test:echo")
    listing.should_not be_nil
    listing.not_nil!.kind.should eq(Arcana::Directory::Kind::Service)
  end

  it "rejects bare (agent-style) addresses" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    expect_raises(Arcana::Error, /must be owner:capability/) do
      Arcana::Service.new(
        bus: bus, directory: dir,
        address: "bare",
        name: "Nope",
        description: "won't work",
      ) { |d| d }
    end
  end

  it "handles requests and returns results" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:doubler",
      name: "Doubler",
      description: "Doubles a number",
    ) do |data|
      n = data["n"].as_i
      JSON::Any.new({"result" => JSON::Any.new(n * 2)})
    end
    svc.start

    payload = Arcana::Protocol.request(
      JSON::Any.new({"n" => JSON::Any.new(21)}),
    )

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "test:doubler", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!["result"].as_i.should eq(42)
  end

  it "validates required fields and sends need response" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    schema = JSON.parse(%({"type":"object","required":["name","age"]}))

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:greeter",
      name: "Greeter",
      description: "Greets by name and age",
      schema: schema,
    ) do |data|
      JSON::Any.new("Hello #{data["name"]}")
    end
    svc.start

    payload = Arcana::Protocol.request(
      JSON::Any.new({"name" => JSON::Any.new("Alice")}),
    )

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "test:greeter", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.need?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).not_nil!.should contain("age")
  end

  it "handles raw (non-protocol) payloads" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:echo",
      name: "Echo",
      description: "Echoes back",
    ) { |data| data }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "test:echo",
        payload: JSON::Any.new("raw message"),
      ),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!.as_s.should eq("raw message")
  end

  it "returns error when handler raises" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:crasher",
      name: "Crasher",
      description: "Always fails",
    ) { |_| raise "boom" }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "test:crasher", payload: JSON::Any.new(nil)),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.error?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).should eq("boom")
  end

  it "responds to help intent with guide" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    schema = JSON.parse(%({"type":"object","required":["prompt"],"properties":{"prompt":{"type":"string"},"width":{"type":"integer"}}}))

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:imager",
      name: "Image Generator",
      description: "Generates images",
      schema: schema,
      guide: "Send a prompt to generate an image. Width defaults to 1024. Use short, descriptive prompts for best results.",
    ) { |_data| JSON::Any.new("ok") }
    svc.start

    payload = Arcana::Protocol.request(JSON::Any.new(nil), intent: "help")
    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "test:imager", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.help?(result.not_nil!.payload).should be_true
    Arcana::Protocol.guide(result.not_nil!.payload).should eq("Send a prompt to generate an image. Width defaults to 1024. Use short, descriptive prompts for best results.")
    result.not_nil!.payload["schema"]["required"].as_a.map(&.as_s).should eq(["prompt"])
  end

  it "falls back to description when no guide is set" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:simple",
      name: "Simple",
      description: "A simple service",
    ) { |data| data }
    svc.start

    payload = Arcana::Protocol.request(JSON::Any.new(nil), intent: "help")
    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "test:simple", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.guide(result.not_nil!.payload).should eq("A simple service")
  end

  it "includes guide in directory listing" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:guided",
      name: "Guided",
      description: "Has a guide",
      guide: "Here's how to use me.",
    ) { |data| data }

    listing = dir.lookup("test:guided")
    listing.should_not be_nil
    listing.not_nil!.guide.should eq("Here's how to use me.")

    json = JSON.parse(listing.not_nil!.to_json)
    json["guide"].as_s.should eq("Here's how to use me.")
  end

  it "unregisters from directory on stop" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "test:tmp",
      name: "Tmp",
      description: "Temporary",
    ) { |d| d }
    svc.start
    svc.stop

    dir.lookup("test:tmp").should be_nil
  end
end
