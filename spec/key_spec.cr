require "./spec_helper"
require "file_utils"

private def openssl(*args : String) : Bool
  Process.run("openssl", args.to_a, error: Process::Redirect::Close).success?
rescue File::NotFoundError | IO::Error
  false
end

describe Arcana::Key do
  it "signs, and its public key checks the signature" do
    key = Arcana::Key.generate
    sig = key.sign("hello")
    Base64.decode(sig).size.should eq(64)
    Arcana::Key.verify(key.public_key, sig, "hello").should be_true
    Arcana::Key.verify(key.public_key, sig, "hellO").should be_false
    Arcana::Key.verify(Arcana::Key.generate.public_key, sig, "hello").should be_false
  end

  it "writes its public key as ed25519: and 32 bytes in base64" do
    key = Arcana::Key.generate
    key.public_key.should start_with("ed25519:")
    Base64.decode(key.public_key.lchop("ed25519:")).size.should eq(32)
    Arcana::Key.valid_public_key?(key.public_key).should be_true
    Arcana::Key.valid_public_key?("ed25519:abc").should be_false
    Arcana::Key.valid_public_key?(key.public_key.lchop("ed25519:")).should be_false
  end

  it "is false, never raising, for anything malformed" do
    key = Arcana::Key.generate
    Arcana::Key.verify("nonsense", key.sign("x"), "x").should be_false
    Arcana::Key.verify(key.public_key, "not base64!", "x").should be_false
    Arcana::Key.verify(key.public_key, Base64.strict_encode(Bytes.new(10)), "x").should be_false
  end

  it "signs the same way from the same seed" do
    seed = Random::Secure.random_bytes(32)
    a = Arcana::Key.new(seed)
    b = Arcana::Key.new(seed)
    a.public_key.should eq(b.public_key)
    a.sign("x").should eq(b.sign("x")) # Ed25519 signatures are deterministic
  end

  it "round-trips through PEM" do
    key = Arcana::Key.generate
    pem = key.to_pem
    pem.should start_with("-----BEGIN PRIVATE KEY-----\n")
    Arcana::Key.from_pem(pem).public_key.should eq(key.public_key)
    expect_raises(Arcana::Error) { Arcana::Key.from_pem("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n") }
    expect_raises(Arcana::Error) { Arcana::Key.from_pem("hello") }
  end

  it "saves readable by its owner only, never overwrites, and load_or_create keeps the first" do
    dir = File.tempname("arcana-key")
    Dir.mkdir(dir)
    path = File.join(dir, "arcana.key")
    begin
      key = Arcana::Key.load_or_create(path)
      (File.info(path).permissions.value & 0o077).should eq(0)
      Arcana::Key.load_or_create(path).public_key.should eq(key.public_key)
      expect_raises(File::AlreadyExistsError) { Arcana::Key.generate.save(path) }
      Arcana::Key.load(path).public_key.should eq(key.public_key)
      Dir.children(dir).should eq(["arcana.key"])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "is made where ARCANA_KEY_FILE says, and is nil without it" do
    dir = File.tempname("arcana-key-env")
    Dir.mkdir(dir)
    saved = ENV["ARCANA_KEY_FILE"]?
    begin
      ENV.delete("ARCANA_KEY_FILE")
      Arcana::Key.from_env.should be_nil
      ENV["ARCANA_KEY_FILE"] = File.join(dir, "arcana.key")
      key = Arcana::Key.from_env.not_nil!
      Arcana::Key.load(File.join(dir, "arcana.key")).public_key.should eq(key.public_key)
      Arcana::Key.from_env.not_nil!.public_key.should eq(key.public_key)
    ensure
      saved ? (ENV["ARCANA_KEY_FILE"] = saved) : ENV.delete("ARCANA_KEY_FILE")
      FileUtils.rm_rf(dir)
    end
  end

  it "reads a key openssl made, and openssl checks what it signs, and the other way round" do
    dir = File.tempname("arcana-key-openssl")
    Dir.mkdir(dir)
    begin
      pem = File.join(dir, "key.pem")
      pub = File.join(dir, "pub.pem")
      data = File.join(dir, "data")
      sig = File.join(dir, "sig")
      unless openssl("genpkey", "-algorithm", "ed25519", "-out", pem) && openssl("pkey", "-in", pem, "-pubout", "-out", pub)
        pending!("no openssl command")
      end
      File.write(data, "the bus")
      key = Arcana::Key.load(pem)

      der = File.join(dir, "pub.der")
      openssl("pkey", "-in", pem, "-pubout", "-outform", "DER", "-out", der).should be_true
      raw = File.open(der, &.getb_to_end)
      key.public_key.should eq("ed25519:" + Base64.strict_encode(raw[-32, 32]))

      File.write(sig, Base64.decode(key.sign("the bus")))
      openssl("pkeyutl", "-verify", "-pubin", "-inkey", pub, "-rawin", "-in", data, "-sigfile", sig).should be_true

      openssl("pkeyutl", "-sign", "-inkey", pem, "-rawin", "-in", data, "-out", sig).should be_true
      Arcana::Key.verify(key.public_key, Base64.strict_encode(File.open(sig, &.getb_to_end)), "the bus").should be_true

      File.write(File.join(dir, "ours.pem"), key.to_pem)
      openssl("pkey", "-in", File.join(dir, "ours.pem"), "-noout").should be_true
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
