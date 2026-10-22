require "./spec_helper"

private def signed_headers(key, body = %({"from":"@proj"}), time = Time.utc)
  Arcana::Signing.sign_request(key, "post", "127.0.0.1:19118", "/deliver", body, time)
end

describe Arcana::Signing do
  key = Arcana::Key.generate

  describe "join proofs" do
    it "are canonical JSON naming the bus, the address and the challenge" do
      Arcana::Signing.join_proof("127.0.0.1:19118", "@proj", "abc").should eq(
        %({"address":"@proj","bus":"127.0.0.1:19118","challenge":"abc","v":"arcana-join-1"}))
    end

    it "gives a fresh 32-byte challenge each time" do
      a = Arcana::Signing.challenge
      Base64.decode(a).size.should eq(32)
      a.should_not eq(Arcana::Signing.challenge)
    end
  end

  describe "requests" do
    it "checks a request signed for this bus, path and body" do
      headers = signed_headers(key)
      signed = Arcana::Signing.signed_request(headers, "POST", "127.0.0.1:19118", "/deliver", %({"from":"@proj"})).not_nil!
      signed.key.should eq(key.public_key)
      signed.nonce.size.should eq(32)
      headers["Host"].should eq("127.0.0.1:19118")
    end

    it "is nil for a request that isn't signed" do
      Arcana::Signing.signed_request(HTTP::Headers.new, "POST", "h", "/deliver", "").should be_nil
    end

    it "refuses a changed body, path, method or bus" do
      headers = signed_headers(key)
      {
        {"POST", "127.0.0.1:19118", "/deliver", %({"from":"@other"})},
        {"POST", "127.0.0.1:19118", "/receive", %({"from":"@proj"})},
        {"GET", "127.0.0.1:19118", "/deliver", %({"from":"@proj"})},
        {"POST", "evil.example:19118", "/deliver", %({"from":"@proj"})},
      }.each do |method, bus, path, body|
        expect_raises(Arcana::Error, /signature doesn't match/) do
          Arcana::Signing.signed_request(headers, method, bus, path, body)
        end
      end
    end

    it "refuses a time too far from the bus's clock" do
      headers = signed_headers(key, time: Time.utc - 2.minutes)
      expect_raises(Arcana::Error, /more than 60 s/) do
        Arcana::Signing.signed_request(headers, "POST", "127.0.0.1:19118", "/deliver", %({"from":"@proj"}))
      end
    end

    it "refuses a signature without its key, time or nonce" do
      {Arcana::Signing::KEY_HEADER, Arcana::Signing::TIME_HEADER, Arcana::Signing::NONCE_HEADER}.each do |name|
        headers = signed_headers(key)
        headers.delete(name)
        expect_raises(Arcana::Error, /needs #{name}/) do
          Arcana::Signing.signed_request(headers, "POST", "127.0.0.1:19118", "/deliver", %({"from":"@proj"}))
        end
      end
    end
  end

  describe Arcana::Signing::Nonces do
    it "takes a nonce once, and again only after twice the window" do
      nonces = Arcana::Signing::Nonces.new(1.second)
      now = Time.utc
      nonces.fresh?("n1", now).should be_true
      nonces.fresh?("n1", now + 1.second).should be_false
      nonces.fresh?("n2", now).should be_true
      nonces.fresh?("n1", now + 3.seconds).should be_true
    end
  end
end

describe "Arcana::Envelope signatures" do
  key = Arcana::Key.generate
  envelope = Arcana::Envelope.new(from: "@proj", to: "mj:voice", subject: "say",
    payload: JSON.parse(%({"text":"hello","speed":1.0})), id: "abcdef12")

  it "are checked by the receiver, through JSON" do
    signed = envelope.signed(key)
    signed.signer.should eq(key.public_key)
    received = Arcana::Envelope.from_json(signed.to_json)
    received.signature.not_nil!.key.should eq(key.public_key)
    received.signer.should eq(key.public_key)
  end

  it "don't match once a field they cover changes" do
    signed = envelope.signed(key)
    {
      ->(e : Arcana::Envelope) { e.from = "@other"; e },
      ->(e : Arcana::Envelope) { e.to = "mj:camera"; e },
      ->(e : Arcana::Envelope) { e.subject = "shout"; e },
      ->(e : Arcana::Envelope) { e.payload = JSON.parse(%({"text":"bye"})); e },
      ->(e : Arcana::Envelope) { e.timestamp = e.timestamp + 5.seconds; e },
    }.each { |change| change.call(signed).signer.should be_nil }
  end

  it "still match when a bus sets reply_to, or writes the time another way" do
    signed = envelope.signed(key)
    redirected = signed
    redirected.reply_to = "_reply:abc"
    redirected.signer.should eq(key.public_key)

    json = JSON.parse(signed.to_json).as_h
    json["timestamp"] = JSON::Any.new(signed.timestamp.to_s("%Y-%m-%dT%H:%M:%S.000+00:00"))
    json["payload"] = JSON.parse(%({ "speed" : 1.0 , "text" : "hello" }))
    Arcana::Envelope.from_json(json.to_json).signer.should eq(key.public_key)
  end

  it "carry the bus's verified stamp only when true, and ignore a malformed signature" do
    stamped = envelope
    stamped.verified = true
    Arcana::Envelope.from_json(stamped.to_json).verified.should be_true
    envelope.to_json.should_not contain("verified")
    raw = JSON.parse(envelope.to_json).as_h
    raw["signature"] = JSON::Any.new("nonsense")
    Arcana::Envelope.from_json(raw.to_json).signature.should be_nil
  end

  it "survive a request through the bus" do
    bus = Arcana::Bus.new
    service = bus.mailbox("mj:voice")
    spawn do
      if got = service.receive(2.seconds)
        got.signer.should eq(key.public_key)
        bus.send(got.reply(from: "mj:voice", payload: JSON::Any.new("ok")))
      end
    end
    bus.request(envelope.signed(key), timeout: 2.seconds).not_nil!.payload.as_s.should eq("ok")
  end
end
