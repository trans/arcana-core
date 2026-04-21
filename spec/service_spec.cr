require "./spec_helper"

describe Arcana::Service do
  it "registers itself in the directory" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "echo",
      name: "Echo",
      description: "Echoes input back",
    ) { |data| data }

    listing = dir.lookup("echo")
    listing.should_not be_nil
    listing.not_nil!.kind.should eq(Arcana::Directory::Kind::Service)
  end

  it "handles requests and returns results" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "doubler",
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
      Arcana::Envelope.new(from: "client", to: "doubler", payload: payload),
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
      address: "greeter",
      name: "Greeter",
      description: "Greets by name and age",
      schema: schema,
    ) do |data|
      JSON::Any.new("Hello #{data["name"]}")
    end
    svc.start

    # Send request missing "age"
    payload = Arcana::Protocol.request(
      JSON::Any.new({"name" => JSON::Any.new("Alice")}),
    )

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "greeter", payload: payload),
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
      address: "echo",
      name: "Echo",
      description: "Echoes back",
    ) { |data| data }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "echo",
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
      address: "crasher",
      name: "Crasher",
      description: "Always fails",
    ) { |_| raise "boom" }
    svc.start

    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "crasher", payload: JSON::Any.new(nil)),
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
      address: "imager",
      name: "Image Generator",
      description: "Generates images",
      schema: schema,
      guide: "Send a prompt to generate an image. Width defaults to 1024. Use short, descriptive prompts for best results.",
    ) { |data| JSON::Any.new("ok") }
    svc.start

    # Ask for help
    payload = Arcana::Protocol.request(JSON::Any.new(nil), intent: "help")
    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "imager", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.help?(result.not_nil!.payload).should be_true
    Arcana::Protocol.guide(result.not_nil!.payload).should eq("Send a prompt to generate an image. Width defaults to 1024. Use short, descriptive prompts for best results.")
    # Schema is included too
    result.not_nil!.payload["schema"]["required"].as_a.map(&.as_s).should eq(["prompt"])
  end

  it "falls back to description when no guide is set" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "simple",
      name: "Simple",
      description: "A simple service",
    ) { |data| data }
    svc.start

    payload = Arcana::Protocol.request(JSON::Any.new(nil), intent: "help")
    result = bus.request(
      Arcana::Envelope.new(from: "client", to: "simple", payload: payload),
      timeout: 1.second,
    )

    result.should_not be_nil
    Arcana::Protocol.guide(result.not_nil!.payload).should eq("A simple service")
  end

  it "includes guide in directory listing" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "guided",
      name: "Guided",
      description: "Has a guide",
      guide: "Here's how to use me.",
    ) { |data| data }

    listing = dir.lookup("guided")
    listing.should_not be_nil
    listing.not_nil!.guide.should eq("Here's how to use me.")

    # JSON output includes guide
    json = JSON.parse(listing.not_nil!.to_json)
    json["guide"].as_s.should eq("Here's how to use me.")
  end

  it "unregisters from directory on stop" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    svc = Arcana::Service.new(
      bus: bus, directory: dir,
      address: "tmp",
      name: "Tmp",
      description: "Temporary",
    ) { |d| d }
    svc.start
    svc.stop

    dir.lookup("tmp").should be_nil
  end
end
