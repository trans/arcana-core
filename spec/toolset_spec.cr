require "./spec_helper"
require "http/server"

private def receive_within(channel : Channel(T), timeout = 5.seconds) : T forall T
  select
  when value = channel.receive
    value
  when timeout(timeout)
    raise "nothing received within #{timeout}"
  end
end

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

  it "marks its listing as ephemeral (code-registered)" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    ts = Arcana::Toolset.new(
      bus: bus, directory: dir,
      address: "eph", name: "Eph", description: "s",
    )
    ts.tool("noop", "no-op") { |_| JSON::Any.new("ok") }
    dir.lookup("eph").not_nil!.ephemeral.should be_true
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

    it "run joins the bus and serves requests" do
      frames = Channel(JSON::Any).new(10)
      sockets = Channel(HTTP::WebSocket).new(1)
      server = HTTP::Server.new([HTTP::WebSocketHandler.new do |ws, _ctx|
        ws.on_message { |msg| frames.send(JSON.parse(msg)) }
        sockets.send(ws)
      end])
      address = server.bind_unused_port("127.0.0.1")
      spawn { server.listen }

      client = Arcana::Client.new(
        url: "ws://127.0.0.1:#{address.port}/bus",
        address: "mj",
        kind: Arcana::Directory::Kind::Service,
      )
      ts = Arcana::Toolset.new(client: client)
      ts.tool("ping", "replies pong") { |_| JSON::Any.new("pong") }

      begin
        spawn { ts.run }

        join = receive_within(frames)
        join["type"].should eq("join")
        join["address"].should eq("mj")

        receive_within(sockets).send(Arcana::Envelope.new(
          from: "caller", to: "mj", payload: JSON.parse(%({"tool":"ping"}))).to_json)

        reply = receive_within(frames)
        reply["type"].should eq("send")
        reply["envelope"]["to"].should eq("caller")
        reply["envelope"]["payload"].to_json.should contain("pong")
      ensure
        client.close
        server.close
      end
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
describe "concurrency" do
    slow_toolset = ->(bus : Arcana::Bus, dir : Arcana::Directory, cap : Int32?) {
      ts = Arcana::Toolset.new(bus: bus, directory: dir, address: "slow", name: "Slow",
        description: "sleeps", max_concurrent: cap)
      ts.tool("nap", "sleeps 200 ms") { |_| sleep 200.milliseconds; JSON::Any.new("ok") }
      ts.start
      ts
    }

    # Sends `n` requests at once; returns how long until every reply was in.
    time_requests = ->(bus : Arcana::Bus, n : Int32) {
      done = Channel(Bool).new(n)
      t0 = Time.instant
      n.times do |i|
        spawn do
          reply = bus.request(Arcana::Envelope.new(from: "c#{i}", to: "slow",
            payload: JSON::Any.new({"tool" => JSON::Any.new("nap")})), timeout: 5.seconds)
          done.send(!reply.nil? && Arcana::Protocol.result?(reply.payload))
        end
      end
      results = Array.new(n) { done.receive }
      results.all?.should be_true
      Time.instant - t0
    }

    it "handles requests at the same time" do
      bus = Arcana::Bus.new
      slow_toolset.call(bus, Arcana::Directory.new, nil)
      time_requests.call(bus, 4).should be < 600.milliseconds # serial: 800
    end

    it "is serial again with max_concurrent: 1" do
      bus = Arcana::Bus.new
      ts = slow_toolset.call(bus, Arcana::Directory.new, 1)
      ts.max_concurrent.should eq(1)
      time_requests.call(bus, 4).should be >= 750.milliseconds
    end

    it "defaults to a cap of 8" do
      bus = Arcana::Bus.new
      slow_toolset.call(bus, Arcana::Directory.new, Arcana::Dispatcher::DEFAULT_MAX_CONCURRENT)
        .max_concurrent.should eq(8)
    end

    it "stays busy until the last overlapping request ends" do
      bus = Arcana::Bus.new
      dir = Arcana::Directory.new
      slow_toolset.call(bus, dir, nil)
      2.times do |i|
        spawn do
          bus.request(Arcana::Envelope.new(from: "c#{i}", to: "slow",
            payload: JSON::Any.new({"tool" => JSON::Any.new("nap")})), timeout: 5.seconds)
        end
        sleep 100.milliseconds
      end
      # Requests started at ~0 and ~100 ms; now ~200 ms. At ~250 ms the
      # first is done and the second runs until ~300 ms.
      sleep 50.milliseconds
      dir.busy?("slow").should be_true
      sleep 150.milliseconds
      dir.busy?("slow").should be_false
    end

    it "over a Client, keeps reading while handlers run" do
      frames = Channel(JSON::Any).new(10)
      sockets = Channel(HTTP::WebSocket).new(1)
      server = HTTP::Server.new([HTTP::WebSocketHandler.new do |ws, _ctx|
        ws.on_message { |msg| frames.send(JSON.parse(msg)) }
        sockets.send(ws)
      end])
      address = server.bind_unused_port("127.0.0.1")
      spawn { server.listen }
      client = Arcana::Client.new(url: "ws://127.0.0.1:#{address.port}/bus", address: "slow",
        kind: Arcana::Directory::Kind::Service)
      ts = Arcana::Toolset.new(client: client)
      ts.tool("nap", "sleeps 200 ms") { |_| sleep 200.milliseconds; JSON::Any.new("ok") }
      begin
        spawn { ts.run }
        receive_within(frames)["type"].should eq("join")
        ws = receive_within(sockets)
        t0 = Time.instant
        3.times do |i|
          ws.send(Arcana::Envelope.new(from: "c#{i}", to: "slow",
            payload: JSON.parse(%({"tool":"nap"}))).to_json)
        end
        3.times { receive_within(frames)["type"].should eq("send") }
        (Time.instant - t0).should be < 500.milliseconds # serial: 600
      ensure
        client.close
        server.close
      end
    end
  end
end
