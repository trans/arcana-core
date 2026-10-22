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

# The join frame a Client sends, as a bare WebSocket server sees it.
private def join_frame(**options) : JSON::Any
  frames = Channel(JSON::Any).new(10)
  server = HTTP::Server.new([HTTP::WebSocketHandler.new do |ws, _ctx|
    ws.on_message { |msg| frames.send(JSON.parse(msg)) }
  end])
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  client = Arcana::Client.new(**options, url: "ws://127.0.0.1:#{address.port}/bus")
  begin
    spawn { client.connect }
    receive_within(frames)
  ensure
    client.close
    server.close
  end
end

describe Arcana::Client do
  it "joins with its owner token when given one" do
    join = join_frame(address: "@proj", owner_token: "tok")
    join["type"].should eq("join")
    join["owner_token"].should eq("tok")
  end

  it "sends no owner token when it has none" do
    join_frame(address: "@proj")["owner_token"]?.should be_nil
  end
end

describe "Arcana::Client with a key" do
  it "offers its key at join, signs the bus's challenge, and signs what it sends" do
    key = Arcana::Key.generate
    frames = Channel(JSON::Any).new(10)
    sockets = Channel(HTTP::WebSocket).new(1)
    host = Channel(String).new(1)
    server = HTTP::Server.new([HTTP::WebSocketHandler.new do |ws, ctx|
      host.send(ctx.request.headers["Host"])
      ws.on_message { |msg| frames.send(JSON.parse(msg)) }
      sockets.send(ws)
    end])
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    client = Arcana::Client.new(url: "ws://127.0.0.1:#{address.port}/bus", address: "@proj",
      kind: Arcana::Directory::Kind::Agent, key: key)
    begin
      spawn { client.connect }
      bus = receive_within(host)
      ws = receive_within(sockets)
      join = receive_within(frames)
      join["key"].should eq(key.public_key)

      ws.send({type: "challenge", challenge: "c-123"}.to_json)
      prove = receive_within(frames)
      prove["type"].should eq("prove")
      Arcana::Key.verify(key.public_key, prove["signature"].as_s,
        Arcana::Signing.join_proof(bus, "@proj", "c-123")).should be_true

      client.verified?.should be_false
      ws.send({type: "joined", address: "@proj", verified: true}.to_json)
      sleep 50.milliseconds
      client.verified?.should be_true

      client.send(Arcana::Envelope.new(from: "@proj", to: "mj:voice", payload: JSON.parse(%({"text":"hi"}))))
      sent = Arcana::Envelope.from_json(receive_within(frames)["envelope"])
      sent.signer.should eq(key.public_key)

      client.publish("#news", Arcana::Envelope.new(from: "@proj", payload: JSON::Any.new("post")))
      post = Arcana::Envelope.from_json(receive_within(frames)["envelope"])
      post.to.should eq("#news")
      post.signer.should eq(key.public_key)
    ensure
      client.close
      server.close
    end
  end

  it "keeps the bus's error, such as a refused join, instead of taking it for an envelope" do
    sockets = Channel(HTTP::WebSocket).new(1)
    server = HTTP::Server.new([HTTP::WebSocketHandler.new { |ws, _ctx| sockets.send(ws) }])
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    received = [] of Arcana::Envelope
    client = Arcana::Client.new(url: "ws://127.0.0.1:#{address.port}/bus", address: "@proj")
    client.on_message { |env| received << env }
    begin
      spawn { client.connect }
      receive_within(sockets).send({error: "@proj is held by another key"}.to_json)
      sleep 50.milliseconds
      client.last_error.should eq("@proj is held by another key")
      received.should be_empty
    ensure
      client.close
      server.close
    end
  end
end
