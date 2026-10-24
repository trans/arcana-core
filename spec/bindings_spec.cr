require "./spec_helper"

# Other shards' bindings of the same libcrypto calls, as they declare
# them. Crystal refuses a program that binds one C function two ways, so
# this file compiling at all is most of the check.

# azb (Azooka Bay's client), src/azb/ed25519.cr.
@[Link("crypto")]
lib LibAzbLike
  alias Pkey = Void*

  fun pkey_new_raw_private = EVP_PKEY_new_raw_private_key(type : LibC::Int, e : Void*, key : UInt8*, keylen : LibC::SizeT) : Pkey
  fun pkey_new_raw_public = EVP_PKEY_new_raw_public_key(type : LibC::Int, e : Void*, key : UInt8*, keylen : LibC::SizeT) : Pkey
  fun pkey_get_raw_public = EVP_PKEY_get_raw_public_key(pkey : Pkey, pub : UInt8*, len : LibC::SizeT*) : LibC::Int
  fun digest_sign_init = EVP_DigestSignInit(ctx : LibCrypto::EVP_MD_CTX, pctx : Void*, type : Void*, e : Void*, pkey : Pkey) : LibC::Int
  fun digest_sign = EVP_DigestSign(ctx : LibCrypto::EVP_MD_CTX, sig : UInt8*, siglen : LibC::SizeT*, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
  fun digest_verify_init = EVP_DigestVerifyInit(ctx : LibCrypto::EVP_MD_CTX, pctx : Void*, type : Void*, e : Void*, pkey : Pkey) : LibC::Int
  fun digest_verify = EVP_DigestVerify(ctx : LibCrypto::EVP_MD_CTX, sig : UInt8*, siglen : LibC::SizeT, tbs : UInt8*, tbslen : LibC::SizeT) : LibC::Int
end

# openssl_ext (which jwt depends on), src/openssl_ext/lib_crypto.cr.
lib LibCrypto
  struct EvpPKeyLike
    type : LibC::Int
  end

  fun evp_pkey_free_like = EVP_PKEY_free(pkey : EvpPKeyLike*)
end

describe "libcrypto bindings" do
  it "build beside azb's and openssl_ext's, and keys still sign and check" do
    LibAzbLike.digest_sign_init(LibCrypto.evp_md_ctx_new, nil, nil, nil, Pointer(Void).null).should eq(0)
    Arcana::Key.clear_errors
    LibCrypto.evp_pkey_free_like(Pointer(LibCrypto::EvpPKeyLike).null)

    key = Arcana::Key.generate
    Arcana::Key.verify(key.public_key, key.sign("x"), "x").should be_true
  end

  it "free the keys they make" do
    Arcana::Key::PKEY_FREE.should_not be_nil
    key = Arcana::Key.generate
    sig = key.sign("x")
    20_000.times { Arcana::Key.verify(key.public_key, sig, "x") }
    GC.collect
    before = File.read("/proc/self/statm").split[1].to_i64 rescue nil
    200_000.times { Arcana::Key.verify(key.public_key, sig, "x") }
    GC.collect
    after = File.read("/proc/self/statm").split[1].to_i64 rescue nil
    # A leaked EVP_PKEY is a few hundred bytes: 200,000 of them would
    # add tens of megabytes. Allow a little drift.
    if before && after
      ((after - before) * 4096).should be < 8_000_000
    end
  end
end
