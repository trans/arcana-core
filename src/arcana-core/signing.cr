require "digest/sha256"
require "http/headers"
require "./canonical"
require "./key"

module Arcana
  # What a project's `Key` signs to prove an address is its own, and how
  # a signature is checked. Each thing signed is a JSON object, written
  # in `Canonical` form and tagged with what it is (`v`), so a signature
  # made for one purpose can't pass for another.
  #
  # - **Joining** over the WebSocket: a client whose `join` frame carries
  #   its public key (`key`) gets back `{"type":"challenge","challenge":C}`
  #   and answers `{"type":"prove","signature":S}`, signing `join_proof`.
  #   That proof names the bus it was meant for (the `Host` the client
  #   sent), so another bus can't pass it on.
  # - **REST**: each request carries `Arcana-Key`, `Arcana-Time` (Unix
  #   seconds), `Arcana-Nonce` and `Arcana-Signature`, signing
  #   `request_proof`. A bus refuses a time more than `WINDOW` off, or a
  #   nonce it has seen (`Nonces`).
  # - **Envelopes** carry their sender's signature to the receiver
  #   (`Envelope#signed`), so it can check the sender itself, without
  #   trusting any bus in between (`Envelope#signer`).
  module Signing
    JOIN     = "arcana-join-1"
    REQUEST  = "arcana-request-1"
    ENVELOPE = "arcana-envelope-1"

    # How far a signed request's time may be from the bus's clock.
    WINDOW = 60.seconds

    KEY_HEADER       = "Arcana-Key"
    TIME_HEADER      = "Arcana-Time"
    NONCE_HEADER     = "Arcana-Nonce"
    SIGNATURE_HEADER = "Arcana-Signature"

    # What a client signs to join as `address`: the bus's `challenge`,
    # and `bus`, the `Host` header it sent (`host:port`).
    def self.join_proof(bus : String, address : String, challenge : String) : String
      Canonical.json({
        "v"         => JSON::Any.new(JOIN),
        "bus"       => JSON::Any.new(bus),
        "address"   => JSON::Any.new(address),
        "challenge" => JSON::Any.new(challenge),
      })
    end

    # A fresh challenge for a joining client: 32 random bytes, base64.
    def self.challenge : String
      Base64.strict_encode(Random::Secure.random_bytes(32))
    end

    # What a client signs for a REST request: its method, the bus (its
    # `Host` header), its path with any query, its time and nonce, and
    # its body's SHA-256 (hex).
    def self.request_proof(method : String, bus : String, path : String, time : Int64, nonce : String, body : String | Bytes) : String
      Canonical.json({
        "v"      => JSON::Any.new(REQUEST),
        "method" => JSON::Any.new(method.upcase),
        "bus"    => JSON::Any.new(bus),
        "path"   => JSON::Any.new(path),
        "time"   => JSON::Any.new(time),
        "nonce"  => JSON::Any.new(nonce),
        "body"   => JSON::Any.new(Digest::SHA256.hexdigest(body.to_slice)),
      })
    end

    # The headers that sign a REST request with `key`. They include
    # `Host`, set to `bus`, so the header sent is the one signed.
    def self.sign_request(key : Key, method : String, bus : String, path : String, body : String | Bytes, time : Time = Time.utc) : HTTP::Headers
      seconds = time.to_unix
      nonce = Random::Secure.hex(16)
      HTTP::Headers{
        "Host"           => bus,
        KEY_HEADER       => key.public_key,
        TIME_HEADER      => seconds.to_s,
        NONCE_HEADER     => nonce,
        SIGNATURE_HEADER => key.sign(request_proof(method, bus, path, seconds, nonce, body)),
      }
    end

    # Who signed a request, as `signed_request` found it.
    record SignedRequest, key : String, time : Int64, nonce : String

    # A signed request's key, time and nonce, once its signature checks
    # and its time is within `window` of `now`; nil when it isn't signed,
    # and raises `Error` saying why when it's signed wrongly. The nonce
    # is the caller's to check (`Nonces#fresh?`).
    def self.signed_request(headers : HTTP::Headers, method : String, bus : String, path : String, body : String | Bytes,
                            now : Time = Time.utc, window : Time::Span = WINDOW) : SignedRequest?
      signature = headers[SIGNATURE_HEADER]?
      return nil unless signature
      key = headers[KEY_HEADER]? || raise Error.new("a signed request needs #{KEY_HEADER}")
      nonce = headers[NONCE_HEADER]?.presence || raise Error.new("a signed request needs #{NONCE_HEADER}")
      time = headers[TIME_HEADER]?.try(&.to_i64?) || raise Error.new("a signed request needs #{TIME_HEADER}, in Unix seconds")
      if (now.to_unix - time).abs > window.total_seconds
        raise Error.new("the request's time is more than #{window.total_seconds.to_i} s from the bus's clock")
      end
      unless Key.verify(key, signature, request_proof(method, bus, path, time, nonce, body))
        raise Error.new("the request's signature doesn't match its key")
      end
      SignedRequest.new(key, time, nonce)
    end

    # What a sender signs for an envelope: everything a bus carries
    # unchanged. Not `reply_to`, which a bus sets for a request it waits
    # on, nor `ordering`, which it resolves. The time is in whole Unix
    # seconds, so it reads the same however a timestamp is written.
    def self.envelope_proof(envelope : Envelope) : String
      Canonical.json({
        "v"              => JSON::Any.new(ENVELOPE),
        "from"           => JSON::Any.new(envelope.from),
        "to"             => JSON::Any.new(envelope.to),
        "subject"        => JSON::Any.new(envelope.subject),
        "payload"        => envelope.payload,
        "correlation_id" => JSON::Any.new(envelope.correlation_id),
        "time"           => JSON::Any.new(envelope.timestamp.to_unix),
        "id"             => JSON::Any.new(envelope.id),
        "re"             => JSON::Any.new(envelope.re),
      })
    end

    # Nonces of signed requests seen within the window, so none is
    # accepted twice. Kept twice the window, which covers a request
    # timed up to a window either side of the bus's clock.
    class Nonces
      def initialize(@window : Time::Span = WINDOW)
        @seen = {} of String => Time
        @mutex = Mutex.new
      end

      # True the first time `nonce` is shown, false after.
      def fresh?(nonce : String, now : Time = Time.utc) : Bool
        @mutex.synchronize do
          cutoff = now - @window * 2
          @seen.reject! { |_, at| at < cutoff } if @seen.size > 1024
          return false if (at = @seen[nonce]?) && at >= cutoff
          @seen[nonce] = now
          true
        end
      end
    end
  end
end
