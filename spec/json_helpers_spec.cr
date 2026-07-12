require "./spec_helper"

describe "JSON::Any helpers" do
  data = JSON.parse(%({
    "name": "Alice",
    "age": 30,
    "score": 3.14,
    "active": true,
    "tags": ["a", "b", "c"],
    "nested": {"k": "v"},
    "count64": 9999999999,
    "mixed_tags": ["a", 1, "b"]
  }))

  describe "str? / str" do
    it "str? returns nullable value" do
      data.str?("name").should eq("Alice")
      data.str?("missing").should be_nil
      data.str?("age").should be_nil # wrong type
    end

    it "str returns \"\" by default when missing" do
      data.str("name").should eq("Alice")
      data.str("missing").should eq("")
      data.str("age").should eq("") # wrong type also uses default
    end

    it "str accepts an explicit default" do
      data.str("missing", "fallback").should eq("fallback")
    end
  end

  describe "int? / int" do
    it "int? returns nullable value" do
      data.int?("age").should eq(30)
      data.int?("missing").should be_nil
    end

    it "int returns 0 by default when missing" do
      data.int("age").should eq(30)
      data.int("missing").should eq(0)
    end

    it "int accepts an explicit default" do
      data.int("missing", 42).should eq(42)
    end

    it "handles int-valued numbers correctly" do
      short = JSON.parse(%({"n": 5}))
      short.int("n").should eq(5)
    end
  end

  describe "i64? / i64" do
    it "i64 handles int64 values" do
      data.i64("count64").should eq(9999999999_i64)
    end

    it "i64 default is 0_i64" do
      data.i64("missing").should eq(0_i64)
    end

    it "i64 accepts an explicit default" do
      data.i64("missing", 100_i64).should eq(100_i64)
    end
  end

  describe "float? / float" do
    it "float returns 0.0 by default" do
      data.float("score").should eq(3.14)
      data.float("missing").should eq(0.0)
    end

    it "float coerces ints" do
      data.float("age").should eq(30.0)
    end

    it "float accepts an explicit default" do
      data.float("missing", 1.5).should eq(1.5)
    end
  end

  describe "bool? / bool" do
    it "bool? returns nullable value" do
      data.bool?("active").should be_true
      data.bool?("missing").should be_nil
    end

    it "bool returns false by default" do
      data.bool("active").should be_true
      data.bool("missing").should be_false
    end

    it "bool preserves explicit false over default" do
      d = JSON.parse(%({"flag": false}))
      d.bool("flag", true).should be_false
    end
  end

  describe "arr? / arr" do
    it "arr? returns nullable" do
      data.arr("tags").size.should eq(3)
      data.arr?("missing").should be_nil
    end

    it "arr defaults to empty array" do
      data.arr("missing").should eq([] of JSON::Any)
    end
  end

  describe "obj? / obj" do
    it "obj? returns nullable" do
      data.obj?("nested").not_nil!["k"].as_s.should eq("v")
      data.obj?("missing").should be_nil
    end

    it "obj defaults to empty hash" do
      data.obj("missing").should eq({} of String => JSON::Any)
    end
  end

  describe "str_arr? / str_arr" do
    it "str_arr extracts array of strings" do
      data.str_arr("tags").should eq(["a", "b", "c"])
    end

    it "str_arr skips non-string entries" do
      data.str_arr("mixed_tags").should eq(["a", "b"])
    end

    it "str_arr defaults to empty" do
      data.str_arr("missing").should eq([] of String)
    end

    it "str_arr accepts an explicit default" do
      data.str_arr("missing", ["x"]).should eq(["x"])
    end
  end
end
