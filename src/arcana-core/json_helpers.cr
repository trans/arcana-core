require "json"

# Ergonomic getters on `JSON::Any` for common extraction patterns.
#
# The Crystal idiom `payload["field"]?.try(&.as_s?) || default` shows up
# hundreds of times across arcana + arcana-core when unwrapping JSON
# payloads that came off the wire. These helpers reduce it to
# `payload.str?("field", default)` (or the raising variant
# `payload.str("field")` when the field is required).
#
# **Pattern:**
# - `str/int/float/bool/arr/obj(key)` — raises `Arcana::Error` if the
#   key is missing or the value has the wrong type.
# - `str?/int?/float?/bool?/arr?/obj?(key)` — returns nil if missing or
#   wrong type.
# - `str?/int?/float?/bool?(key, default)` — returns default if missing
#   or wrong type. (Overload of the two-arg form.)
#
# **Not stdlib.** These extend `JSON::Any` globally the moment
# arcana-core is required. If Crystal upstream lands methods with the
# same names later, we'll rename.
struct JSON::Any
  # --- nil-tolerant getters ---

  def str?(key : String) : String?
    self[key]?.try(&.as_s?)
  end

  def str?(key : String, default : String) : String
    str?(key) || default
  end

  def int?(key : String) : Int32?
    v = self[key]?
    return nil if v.nil?
    v.as_i? || v.as_i64?.try(&.to_i32)
  end

  def int?(key : String, default : Int32) : Int32
    int?(key) || default
  end

  def i64?(key : String) : Int64?
    v = self[key]?
    return nil if v.nil?
    v.as_i64? || v.as_i?.try(&.to_i64)
  end

  def i64?(key : String, default : Int64) : Int64
    i64?(key) || default
  end

  def float?(key : String) : Float64?
    v = self[key]?
    return nil if v.nil?
    v.as_f? || v.as_i?.try(&.to_f64)
  end

  def float?(key : String, default : Float64) : Float64
    float?(key) || default
  end

  def bool?(key : String) : Bool?
    self[key]?.try(&.as_bool?)
  end

  def bool?(key : String, default : Bool) : Bool
    v = bool?(key)
    v.nil? ? default : v
  end

  def arr?(key : String) : Array(JSON::Any)?
    self[key]?.try(&.as_a?)
  end

  def obj?(key : String) : Hash(String, JSON::Any)?
    self[key]?.try(&.as_h?)
  end

  # Convenience: return an Array(String), skipping non-string entries.
  # Returns nil when the field is missing or not an array.
  def str_arr?(key : String) : Array(String)?
    arr?(key).try(&.compact_map(&.as_s?))
  end

  def str_arr?(key : String, default : Array(String)) : Array(String)
    str_arr?(key) || default
  end

  # --- raising getters ---

  def str(key : String) : String
    str?(key) || raise Arcana::Error.new("missing or non-string field #{key.inspect}")
  end

  def int(key : String) : Int32
    int?(key) || raise Arcana::Error.new("missing or non-integer field #{key.inspect}")
  end

  def i64(key : String) : Int64
    i64?(key) || raise Arcana::Error.new("missing or non-integer field #{key.inspect}")
  end

  def float(key : String) : Float64
    float?(key) || raise Arcana::Error.new("missing or non-numeric field #{key.inspect}")
  end

  def bool(key : String) : Bool
    v = bool?(key)
    v.nil? ? raise(Arcana::Error.new("missing or non-boolean field #{key.inspect}")) : v
  end

  def arr(key : String) : Array(JSON::Any)
    arr?(key) || raise Arcana::Error.new("missing or non-array field #{key.inspect}")
  end

  def obj(key : String) : Hash(String, JSON::Any)
    obj?(key) || raise Arcana::Error.new("missing or non-object field #{key.inspect}")
  end

  def str_arr(key : String) : Array(String)
    str_arr?(key) || raise Arcana::Error.new("missing or non-array field #{key.inspect}")
  end
end
