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
    it "extracts string values" do
      data.str?("name").should eq("Alice")
      data.str("name").should eq("Alice")
    end

    it "returns nil for missing keys" do
      data.str?("missing").should be_nil
    end

    it "returns nil for wrong types" do
      data.str?("age").should be_nil
    end

    it "returns default when missing" do
      data.str?("missing", "fallback").should eq("fallback")
    end

    it "raises for missing key" do
      expect_raises(Arcana::Error, /missing or non-string/) { data.str("missing") }
    end

    it "raises for wrong type" do
      expect_raises(Arcana::Error, /missing or non-string/) { data.str("age") }
    end
  end

  describe "int? / int" do
    it "extracts int values" do
      data.int("age").should eq(30)
      data.int?("age").should eq(30)
    end

    it "returns default when missing" do
      data.int?("missing", 42).should eq(42)
    end

    it "handles int64 values that fit in int32" do
      short = JSON.parse(%({"n": 5}))
      short.int("n").should eq(5)
    end

    it "raises for wrong type" do
      expect_raises(Arcana::Error) { data.int("name") }
    end
  end

  describe "i64? / i64" do
    it "extracts int64 values" do
      data.i64("count64").should eq(9999999999_i64)
    end

    it "returns default when missing" do
      data.i64?("missing", 100_i64).should eq(100_i64)
    end
  end

  describe "float? / float" do
    it "extracts float values" do
      data.float("score").should eq(3.14)
    end

    it "coerces ints to floats" do
      data.float("age").should eq(30.0)
    end

    it "returns default when missing" do
      data.float?("missing", 1.0).should eq(1.0)
    end
  end

  describe "bool? / bool" do
    it "extracts bool values" do
      data.bool("active").should be_true
      data.bool?("active").should be_true
    end

    it "returns nil for missing keys" do
      data.bool?("missing").should be_nil
    end

    it "returns default when missing" do
      data.bool?("missing", false).should be_false
    end

    it "distinguishes explicit false from missing" do
      d = JSON.parse(%({"flag": false}))
      d.bool?("flag", true).should be_false
    end
  end

  describe "arr? / arr" do
    it "extracts array values" do
      data.arr("tags").size.should eq(3)
    end

    it "returns nil for missing keys" do
      data.arr?("missing").should be_nil
    end
  end

  describe "obj? / obj" do
    it "extracts hash values" do
      data.obj("nested")["k"].as_s.should eq("v")
    end

    it "returns nil for missing keys" do
      data.obj?("missing").should be_nil
    end
  end

  describe "str_arr? / str_arr" do
    it "extracts array of strings" do
      data.str_arr("tags").should eq(["a", "b", "c"])
    end

    it "skips non-string entries" do
      data.str_arr?("mixed_tags").should eq(["a", "b"])
    end

    it "returns default when missing" do
      data.str_arr?("missing", ["x"]).should eq(["x"])
    end
  end
end
