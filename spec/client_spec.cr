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
