require "base64"
require "openssl"
require "./error"

# The few libcrypto calls Ed25519 needs. Crystal's OpenSSL bindings
# don't cover raw keys or one-shot signing; OpenSSL has had both since
# 1.1.1. Digest contexts come from the stdlib's `LibCrypto`, which
# already binds them.
@[Link("crypto")]
lib LibArcanaCrypto
  alias EVP_PKEY = Void*
  alias EVP_MD_CTX = LibCrypto::EVP_MD_CTX

  NID_ED25519 = 1087

  fun pkey_new_raw_private = EVP_PKEY_new_raw_private_key(type : LibC::Int, e : Void*, priv : UInt8*, len : LibC::SizeT) : EVP_PKEY
  fun pkey_new_raw_public = EVP_PKEY_new_raw_public_key(type : LibC::Int, e : Void*, pub : UInt8*, len : LibC::SizeT) : EVP_PKEY
  fun pkey_get_raw_public = EVP_PKEY_get_raw_public_key(pkey : EVP_PKEY, pub : UInt8*, len : LibC::SizeT*) : LibC::Int
  fun pkey_free = EVP_PKEY_free(pkey : EVP_PKEY)
  fun digest_sign_init = EVP_DigestSignInit(ctx : EVP_MD_CTX, pctx : Void**, type : Void*, e : Void*, pkey : EVP_PKEY) : LibC::Int
  fun digest_sign = EVP_DigestSign(ctx : EVP_MD_CTX, sig : UInt8*, siglen : LibC::SizeT*, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
  fun digest_verify_init = EVP_DigestVerifyInit(ctx : EVP_MD_CTX, pctx : Void**, type : Void*, e : Void*, pkey : EVP_PKEY) : LibC::Int
  fun digest_verify = EVP_DigestVerify(ctx : EVP_MD_CTX, sig : UInt8*, siglen : LibC::SizeT, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
  fun err_clear = ERR_clear_error : Void
end

module Arcana
  # An Ed25519 key pair: what a project proves its addresses with (see
  # `Signing`). The bus holds only the public half.
  #
  #   key = Arcana::Key.load_or_create(".ai/arcana.key")
  #   key.public_key        # => "ed25519:3q2+7w..."
  #   sig = key.sign("data")
  #   Arcana::Key.verify(key.public_key, sig, "data") # => true
  #
  # The private key is kept as PKCS#8 PEM, as `openssl genpkey
  # -algorithm ed25519` writes it, so other languages' libraries read
  # it as they are. A public key is written `ed25519:` and the raw 32
  # bytes in base64; a signature is the raw 64 bytes in base64.
  class Key
    PREFIX = "ed25519:"

    # The DER of an Ed25519 PKCS#8 private key, up to the 32-byte seed
    # that follows it.
    PKCS8_HEADER = Bytes[0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
      0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]

    getter public_key : String

    @pkey : LibArcanaCrypto::EVP_PKEY
    @seed : Bytes

    def self.generate : Key
      new(Random::Secure.random_bytes(32))
    end

    # A key from its 32-byte seed (the private key itself).
    def initialize(seed : Bytes)
      raise Error.new("an Ed25519 private key is 32 bytes, not #{seed.size}") unless seed.size == 32
      @seed = seed.dup
      @pkey = LibArcanaCrypto.pkey_new_raw_private(LibArcanaCrypto::NID_ED25519, nil, @seed, 32)
      Key.fail("OpenSSL refused the key") if @pkey.null?
      raw = Bytes.new(32)
      len = LibC::SizeT.new(32)
      Key.fail("OpenSSL couldn't give the public key") unless LibArcanaCrypto.pkey_get_raw_public(@pkey, raw, pointerof(len)) == 1
      @public_key = PREFIX + Base64.strict_encode(raw)
    end

    def finalize
      LibArcanaCrypto.pkey_free(@pkey)
    end

    # Read a PKCS#8 PEM Ed25519 private key.
    def self.from_pem(pem : String) : Key
      raise Error.new("not a PEM private key") unless pem.includes?("-----BEGIN PRIVATE KEY-----")
      body = pem.lines.reject(&.starts_with?("-----")).join.strip
      der = Base64.decode(body)
      unless der.size == 48 && der[0, 16] == PKCS8_HEADER
        raise Error.new("not an Ed25519 private key")
      end
      new(der[16, 32])
    rescue ex : Base64::Error
      raise Error.new("not a PEM private key: #{ex.message}")
    end

    def to_pem : String
      der = Bytes.new(48)
      PKCS8_HEADER.copy_to(der)
      @seed.copy_to(der + 16)
      "-----BEGIN PRIVATE KEY-----\n#{Base64.strict_encode(der)}\n-----END PRIVATE KEY-----\n"
    end

    def self.load(path : String | Path) : Key
      from_pem(File.read(path))
    end

    # Write the key to `path`, readable only by its owner. Fails if
    # `path` exists: a key is never overwritten.
    def save(path : String | Path) : Nil
      tmp = "#{path}.#{Random::Secure.hex(4)}.tmp"
      File.open(tmp, "w", perm: 0o600) { |f| f.print to_pem }
      begin
        File.link(tmp, path)
      ensure
        File.delete?(tmp)
      end
    end

    # The key at `path`, made first if there is none. Two processes
    # making it at once end up with the same key: the second finds the
    # first's.
    def self.load_or_create(path : String | Path) : Key
      return load(path) if File.exists?(path)
      key = generate
      begin
        key.save(path)
        key
      rescue File::AlreadyExistsError
        load(path)
      end
    end

    # The variable naming the key file of a process that runs apart from
    # its project's `.ai/`, such as a sandboxed or deployed service. Such
    # a process has a key of its own, kept with its state, which holds
    # only its own addresses.
    FILE_ENV = "ARCANA_KEY_FILE"

    # The key in the file `ARCANA_KEY_FILE` names, made there on first
    # use; nil when the variable isn't set.
    #
    #   # ARCANA_KEY_FILE=/var/lib/mj/arcana.key
    #   client = Arcana::Client.new(..., key: Arcana::Key.from_env)
    def self.from_env : Key?
      path = ENV[FILE_ENV]?.presence || return nil
      load_or_create(path)
    end

    # Sign `data`, returning the signature in base64.
    def sign(data : String | Bytes) : String
      bytes = data.to_slice
      ctx = LibCrypto.evp_md_ctx_new
      begin
        Key.fail("OpenSSL couldn't start signing") unless LibArcanaCrypto.digest_sign_init(ctx, nil, nil, nil, @pkey) == 1
        sig = Bytes.new(64)
        len = LibC::SizeT.new(64)
        Key.fail("OpenSSL couldn't sign") unless LibArcanaCrypto.digest_sign(ctx, sig, pointerof(len), bytes, bytes.size) == 1
        Base64.strict_encode(sig[0, len])
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
      end
    end

    # Is `signature` (base64) `public_key`'s signature of `data`? False
    # for anything malformed, never raises.
    def self.verify(public_key : String, signature : String, data : String | Bytes) : Bool
      raw = decode_public(public_key)
      sig = Base64.decode(signature) rescue nil
      return false unless raw && sig && sig.size == 64
      bytes = data.to_slice
      pkey = LibArcanaCrypto.pkey_new_raw_public(LibArcanaCrypto::NID_ED25519, nil, raw, 32)
      if pkey.null?
        LibArcanaCrypto.err_clear
        return false
      end
      ctx = LibCrypto.evp_md_ctx_new
      begin
        ok = LibArcanaCrypto.digest_verify_init(ctx, nil, nil, nil, pkey) == 1 &&
             LibArcanaCrypto.digest_verify(ctx, sig, sig.size, bytes, bytes.size) == 1
        LibArcanaCrypto.err_clear unless ok
        ok
      ensure
        LibCrypto.evp_md_ctx_free(ctx)
        LibArcanaCrypto.pkey_free(pkey)
      end
    end

    # Is `public_key` written as a public key should be?
    def self.valid_public_key?(public_key : String) : Bool
      !decode_public(public_key).nil?
    end

    private def self.decode_public(public_key : String) : Bytes?
      return nil unless public_key.starts_with?(PREFIX)
      raw = Base64.decode(public_key[PREFIX.size..]) rescue nil
      raw if raw && raw.size == 32
    end

    # :nodoc:
    def self.fail(message : String) : NoReturn
      LibArcanaCrypto.err_clear
      raise Error.new(message)
    end

    def inspect(io : IO) : Nil
      io << "#<Arcana::Key " << @public_key << '>'
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end
  end
end
