require "json"

# Ergonomic getters on `JSON::Any` for common extraction patterns.
#
# The Crystal idiom `payload["field"]?.try(&.as_s?) || default` shows up
# hundreds of times across arcana + arcana-core when unwrapping JSON
# payloads that came off the wire.
#
# **Convention:** the `?` suffix means "returns nullable." The no-`?`
# variants always return a value, using a sensible default (empty
# string, zero, false, empty collection) when the field is missing or
# has the wrong type.
#
#   payload.str?("field")           # => String? (nil if missing)
#   payload.str("field")            # => "" if missing
#   payload.str("field", "custom")  # => "custom" if missing
#
# **Not stdlib.** These extend `JSON::Any` globally the moment
# arcana-core is required. If Crystal upstream lands methods with the
# same names later, we'll rename.
struct JSON::Any
  # --- nullable-return variants (?) ---
  #
  # If `self` isn't a JSON object (Hash), every helper returns nil.
  # That way callers can probe payloads without a defensive
  # `data.as_h? ||` guard at every site — a raw String or Nil payload
  # answers "no such field" for anything you ask for.

  def str?(key : String) : String?
    return nil unless as_h?
    self[key]?.try(&.as_s?)
  end

  def int?(key : String) : Int32?
    return nil unless as_h?
    v = self[key]?
    return nil if v.nil?
    v.as_i? || v.as_i64?.try(&.to_i32)
  end

  def i64?(key : String) : Int64?
    return nil unless as_h?
    v = self[key]?
    return nil if v.nil?
    v.as_i64? || v.as_i?.try(&.to_i64)
  end

  def float?(key : String) : Float64?
    return nil unless as_h?
    v = self[key]?
    return nil if v.nil?
    v.as_f? || v.as_i?.try(&.to_f64)
  end

  def bool?(key : String) : Bool?
    return nil unless as_h?
    self[key]?.try(&.as_bool?)
  end

  def arr?(key : String) : Array(JSON::Any)?
    return nil unless as_h?
    self[key]?.try(&.as_a?)
  end

  def obj?(key : String) : Hash(String, JSON::Any)?
    return nil unless as_h?
    self[key]?.try(&.as_h?)
  end

  # Return an Array(String), skipping non-string entries. Nil when
  # the field is missing, self isn't a hash, or the value isn't an array.
  def str_arr?(key : String) : Array(String)?
    arr?(key).try(&.compact_map(&.as_s?))
  end

  # --- always-return-a-value variants (default) ---

  def str(key : String, default : String = "") : String
    str?(key) || default
  end

  def int(key : String, default : Int32 = 0) : Int32
    int?(key) || default
  end

  def i64(key : String, default : Int64 = 0_i64) : Int64
    i64?(key) || default
  end

  def float(key : String, default : Float64 = 0.0) : Float64
    float?(key) || default
  end

  def bool(key : String, default : Bool = false) : Bool
    v = bool?(key)
    v.nil? ? default : v
  end

  def arr(key : String, default : Array(JSON::Any) = [] of JSON::Any) : Array(JSON::Any)
    arr?(key) || default
  end

  def obj(key : String, default : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
    obj?(key) || default
  end

  def str_arr(key : String, default : Array(String) = [] of String) : Array(String)
    str_arr?(key) || default
  end
end
