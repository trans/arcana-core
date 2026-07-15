require "./spec_helper"

describe Arcana::Toolset do
  it "registers as a service in the directory" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj",
      name: "Minanime",
      description: "Image generation studio",
      tags: ["image"],
    )
    ts.tool("pixelize", "pixel-art stylize") { |_| JSON::Any.new("ok") }

    listing = dir.lookup("mj").not_nil!
    listing.kind.should eq(Arcana::Directory::Kind::Service)
    listing.tags.should contain("image")
  end

  it "unions user-provided tags with registered tool names on start" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "openai",
      name: "OpenAI",
      description: "provider",
      tags: ["llm", "openai"],
    )
    ts.tool("chat", "chat completion") { |_| JSON::Any.new("ok") }
    ts.tool("embed", "text embeddings") { |_| JSON::Any.new("ok") }
    ts.tool("tts", "text-to-speech") { |_| JSON::Any.new("ok") }
    ts.start

    listing = dir.lookup("openai").not_nil!
    listing.tags.sort.should eq(["chat", "embed", "llm", "openai", "tts"])
  end

  it "responds to {\"tool\":\"help\"} with a tools manifest" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj",
      name: "Minanime",
      description: "studio",
    )
    ts.tool("pixelize", "Pixel-art stylize",
      input_schema: JSON.parse(%({"type":"object","required":["prompt"]}))) { |_| JSON::Any.new("ok") }
    ts.tool("prop", "Generate a prop") { |_| JSON::Any.new("prop") }
    ts.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new({"tool" => JSON::Any.new("help")}),
      ),
      timeout: 1.second,
    )
    result.should_not be_nil
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true

    manifest = Arcana::Protocol.data(result.not_nil!.payload).not_nil!
    manifest["name"].as_s.should eq("Minanime")

    tool_names = manifest["tools"].as_a.map { |t| t["name"].as_s }
    tool_names.sort.should eq(["pixelize", "prop"])

    pixelize = manifest["tools"].as_a.find! { |t| t["name"].as_s == "pixelize" }
    pixelize["description"].as_s.should eq("Pixel-art stylize")
    pixelize["inputSchema"]["required"].as_a.map(&.as_s).should eq(["prompt"])
  end

  it "dispatches on the tool field" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj",
      name: "Minanime",
      description: "studio",
    )
    ts.tool("pixelize", "stylize") do |data|
      JSON::Any.new({"echo" => JSON::Any.new(data.str("prompt"))})
    end
    ts.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new({
          "tool"   => JSON::Any.new("pixelize"),
          "prompt" => JSON::Any.new("a shard"),
        }),
      ),
      timeout: 1.second,
    )
    Arcana::Protocol.result?(result.not_nil!.payload).should be_true
    Arcana::Protocol.data(result.not_nil!.payload).not_nil!["echo"].as_s.should eq("a shard")
  end

  it "returns an error for unknown tools" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj", name: "Minanime", description: "s",
    )
    ts.tool("pixelize", "s") { |_| JSON::Any.new("ok") }
    ts.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new({"tool" => JSON::Any.new("nonexistent")}),
      ),
      timeout: 1.second,
    )
    Arcana::Protocol.error?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).not_nil!.should contain("nonexistent")
    Arcana::Protocol.message(result.not_nil!.payload).not_nil!.should contain("pixelize")
  end

  it "returns an error when the payload lacks a tool field" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj", name: "Minanime", description: "s",
    )
    ts.tool("pixelize", "s") { |_| JSON::Any.new("ok") }
    ts.start

    result = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new({"prompt" => JSON::Any.new("no tool")}),
      ),
      timeout: 1.second,
    )
    Arcana::Protocol.error?(result.not_nil!.payload).should be_true
    Arcana::Protocol.message(result.not_nil!.payload).not_nil!.should contain("tool")
  end

  it "refuses to let a user register a 'help' tool" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj", name: "Minanime", description: "s",
    )
    expect_raises(Arcana::Error, /reserved/) do
      ts.tool("help", "not allowed") { |_| JSON::Any.new("ok") }
    end
  end

  describe "over a Client transport" do
    it "wraps a Client and exposes the same tool API" do
      # Build a fake mailbox-like bus we won't actually use — we just
      # want to construct the Client with an address and hand it to
      # Toolset.new(client:). Since Client only exposes getters (no
      # networking until .connect), we can verify identity + tool API
      # without a live WebSocket.
      client = Arcana::Client.new(
        url: "ws://localhost:19118/bus",
        address: "mj",
        name: "Minanime",
        description: "Image generation studio",
        kind: Arcana::Directory::Kind::Service,
        tags: ["image"],
      )
      ts = Arcana::Toolset.new(client: client)
      ts.tool("pixelize", "Pixel-art stylize") { |_| JSON::Any.new("ok") }

      ts.address.should eq("mj")

      manifest = ts.manifest
      manifest["name"].as_s.should eq("Minanime")
      manifest["description"].as_s.should eq("Image generation studio")
      manifest["tools"].as_a.size.should eq(1)
      manifest["tools"].as_a[0]["name"].as_s.should eq("pixelize")
    end

    it "manifest name/description override client's" do
      client = Arcana::Client.new(
        url: "ws://localhost:19118/bus",
        address: "mj",
        name: "Minanime",
        description: "studio",
      )
      ts = Arcana::Toolset.new(client: client, name: "Custom", description: "override")
      ts.tool("noop", "no-op") { |_| JSON::Any.new("ok") }

      manifest = ts.manifest
      manifest["name"].as_s.should eq("Custom")
      manifest["description"].as_s.should eq("override")
    end
  end

  it "survives a poison-pill payload (non-hash) without killing the fiber" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "mj", name: "Minanime", description: "s",
    )
    ts.tool("noop", "s") { |_| JSON::Any.new("ok") }
    ts.start

    # A raw-string payload: no tool field extractable.
    poison = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new("just a string"),
      ),
      timeout: 1.second,
    )
    Arcana::Protocol.error?(poison.not_nil!.payload).should be_true

    # And the worker keeps consuming: the next legit call still works.
    ok = bus.request(
      Arcana::Envelope.new(
        from: "client", to: "mj",
        payload: JSON::Any.new({"tool" => JSON::Any.new("noop")}),
      ),
      timeout: 1.second,
    )
    Arcana::Protocol.result?(ok.not_nil!.payload).should be_true
  end
end
