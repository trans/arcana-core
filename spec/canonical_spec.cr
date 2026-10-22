require "./spec_helper"

private def number(bits : UInt64) : String
  Arcana::Canonical.json(JSON::Any.new(bits.unsafe_as(Float64)))
end

# Test vectors from RFC 8785 (JSON Canonicalization Scheme).
describe Arcana::Canonical do
  it "writes the RFC's example" do
    input = JSON.parse("{\"numbers\": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001], \"string\": \"\\u20ac$\\u000F\\u000aA'\\u0042\\u0022\\u005c\\\\\\\"\\/\", \"literals\": [null, true, false]}")
    Arcana::Canonical.json(input).should eq("{\"literals\":[null,true,false],\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],\"string\":\"€$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"}")
  end

  it "sorts keys by UTF-16 code units, which puts an emoji before U+FB33" do
    input = JSON.parse("{\"\\u20ac\": \"Euro Sign\", \"\\r\": \"Carriage Return\", \"\\ufb33\": \"Hebrew Letter Dalet With Dagesh\", \"1\": \"One\", \"\\ud83d\\ude00\": \"Emoji: Grinning Face\", \"\\u0080\": \"Control\", \"\\u00f6\": \"Latin Small Letter O With Diaeresis\"}")
    keys = JSON.parse(Arcana::Canonical.json(input)).as_h.keys
    keys.should eq(["\u{d}", "1", "\u{80}", "\u{f6}", "\u{20ac}", "\u{1f600}", "\u{fb33}"])
  end

  it "writes numbers as JavaScript does" do
    {
      0x0000000000000000_u64 => "0",
      0x8000000000000000_u64 => "0",
      0x0000000000000001_u64 => "5e-324",
      0x8000000000000001_u64 => "-5e-324",
      0x7fefffffffffffff_u64 => "1.7976931348623157e+308",
      0x4340000000000000_u64 => "9007199254740992",
      0xc340000000000000_u64 => "-9007199254740992",
      0x4430000000000000_u64 => "295147905179352830000",
      0x44b52d02c7e14af5_u64 => "9.999999999999997e+22",
      0x44b52d02c7e14af6_u64 => "1e+23",
      0x44b52d02c7e14af7_u64 => "1.0000000000000001e+23",
      0x444b1ae4d6e2ef4e_u64 => "999999999999999700000",
      0x444b1ae4d6e2ef4f_u64 => "999999999999999900000",
      0x444b1ae4d6e2ef50_u64 => "1e+21",
      0x3eb0c6f7a0b5ed8c_u64 => "9.999999999999997e-7",
      0x3eb0c6f7a0b5ed8d_u64 => "0.000001",
      0x41b3de4355555553_u64 => "333333333.3333332",
      0x41b3de4355555554_u64 => "333333333.33333325",
      0x41b3de4355555555_u64 => "333333333.3333333",
      0x41b3de4355555556_u64 => "333333333.3333334",
      0x41b3de4355555557_u64 => "333333333.33333343",
      0xbecbf647612f3696_u64 => "-0.0000033333333333333333",
      0x43143ff3c1cb0959_u64 => "1424953923781206.2",
    }.each do |bits, expected|
      number(bits).should eq(expected)
    end
  end

  it "writes integers exactly up to 2^53, and beyond it as the nearest double" do
    Arcana::Canonical.json(JSON.parse("[1, -42, 1.0, 100, 9007199254740993]")).should eq("[1,-42,1,100,9007199254740992]")
  end

  it "escapes only quotes, backslashes and control characters" do
    Arcana::Canonical.json(JSON::Any.new("a\u{1}\u{1f}\u{7f} é\u{2028}")).should eq("\"a\\u0001\\u001f\u{7f} é\u{2028}\"")
  end

  it "refuses what JSON can't hold" do
    expect_raises(Arcana::Error) { Arcana::Canonical.json(JSON::Any.new(Float64::NAN)) }
  end
end
