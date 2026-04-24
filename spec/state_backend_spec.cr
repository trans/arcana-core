require "./spec_helper"

describe Arcana::LocalFileBackend do
  it "save / load round-trip" do
    path = File.tempname("arcana-state", ".json")
    backend = Arcana::LocalFileBackend.new(path)
    begin
      backend.exists?.should be_false
      backend.load.should be_nil

      backend.save(%({"hello":"world"}))

      backend.exists?.should be_true
      backend.load.should eq(%({"hello":"world"}))
    ensure
      File.delete(path) if File.exists?(path)
      File.delete("#{path}.tmp") if File.exists?("#{path}.tmp")
    end
  end

  it "writes atomically — no .tmp file remains after save" do
    path = File.tempname("arcana-state", ".json")
    backend = Arcana::LocalFileBackend.new(path)
    begin
      backend.save("first")
      backend.save("second")
      File.exists?(path).should be_true
      File.exists?("#{path}.tmp").should be_false
      backend.load.should eq("second")
    ensure
      File.delete(path) if File.exists?(path)
      File.delete("#{path}.tmp") if File.exists?("#{path}.tmp")
    end
  end

  it "exposes the path" do
    backend = Arcana::LocalFileBackend.new("/tmp/foo.json")
    backend.path.should eq("/tmp/foo.json")
  end
end
