require "json"
require "./error"

module Arcana
  # JSON in one exact form, so a signature made over it in one program
  # checks in another: RFC 8785, the JSON Canonicalization Scheme (JCS),
  # which libraries in other languages implement too.
  #
  # - No whitespace.
  # - Object keys sorted by their UTF-16 code units.
  # - Strings escape only `"`, `\` and control characters, as `\b`,
  #   `\t`, `\n`, `\f`, `\r` or `\u00xx`; everything else is written as
  #   is, in UTF-8.
  # - Numbers as JavaScript writes them: the shortest digits that read
  #   back as the same double, in exponent form below 1e-6 and from
  #   1e21 up (`1e+21`, `5e-324`), `0` for -0. An integer beyond 2^53
  #   is written as the double nearest it, as JavaScript would.
  module Canonical
    def self.json(value : JSON::Any) : String
      String.build { |io| write(io, value) }
    end

    def self.json(value : Hash(String, JSON::Any)) : String
      json(JSON::Any.new(value))
    end

    private def self.write(io : IO, value : JSON::Any) : Nil
      case raw = value.raw
      when Nil
        io << "null"
      when Bool
        io << raw
      when String
        write_string(io, raw)
      when Int64
        if raw.abs <= 9_007_199_254_740_992_i64
          io << raw
        else
          write_number(io, raw.to_f64)
        end
      when Float64
        write_number(io, raw)
      when Array(JSON::Any)
        io << '['
        raw.each_with_index do |item, i|
          io << ',' if i > 0
          write(io, item)
        end
        io << ']'
      when Hash(String, JSON::Any)
        io << '{'
        raw.keys.sort_by(&.to_utf16.to_a).each_with_index do |key, i|
          io << ',' if i > 0
          write_string(io, key)
          io << ':'
          write(io, raw[key])
        end
        io << '}'
      end
    end

    private def self.write_string(io : IO, s : String) : Nil
      io << '"'
      s.each_char do |c|
        case c
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\b' then io << "\\b"
        when '\t' then io << "\\t"
        when '\n' then io << "\\n"
        when '\f' then io << "\\f"
        when '\r' then io << "\\r"
        else
          if c.ord < 0x20
            io << "\\u00" << c.ord.to_s(16).rjust(2, '0')
          else
            io << c
          end
        end
      end
      io << '"'
    end

    private def self.write_number(io : IO, f : Float64) : Nil
      raise Error.new("JSON has no #{f}") if f.nan? || f.infinite?
      return io << '0' if f == 0
      io << '-' if f < 0
      digits, point = shortest(f.abs)
      size = digits.size
      if size <= point <= 21
        io << digits << "0" * (point - size)
      elsif 0 < point <= 21
        io << digits[0, point] << '.' << digits[point..]
      elsif -6 < point <= 0
        io << "0." << "0" * -point << digits
      else
        exponent = point - 1
        io << digits[0]
        io << '.' << digits[1..] if size > 1
        io << 'e' << (exponent < 0 ? '-' : '+') << exponent.abs
      end
    end

    # The shortest digits that read back as `f` (positive), without
    # leading or trailing zeros, and where the decimal point goes:
    # `f` = 0.digits × 10^point. Crystal's `Float64#to_s` already gives
    # the shortest digits; only its layout differs from JavaScript's.
    private def self.shortest(f : Float64) : {String, Int32}
      mantissa, _, exponent = f.to_s.partition('e')
      whole, _, fraction = mantissa.partition('.')
      digits = whole + fraction
      point = whole.size + (exponent.empty? ? 0 : exponent.to_i)
      stripped = digits.lstrip('0')
      point -= digits.size - stripped.size
      {stripped.rstrip('0'), point}
    end
  end
end
