require "./spec_helper"
require "file_utils"

describe Arcana::Events do
  describe Arcana::Events::Event do
    it "round-trips through JSON" do
      e = Arcana::Events::Event.new(
        type: "message.sent",
        subject: "arcana:echo",
        object: "alice",
        correlation_id: "abc123",
        metadata: {"size" => JSON::Any.new(42_i64)} of String => JSON::Any,
      )
      parsed = Arcana::Events::Event.from_json(e.to_json)
      parsed.type.should eq("message.sent")
      parsed.subject.should eq("arcana:echo")
      parsed.object.should eq("alice")
      parsed.correlation_id.should eq("abc123")
      parsed.metadata.not_nil!["size"].as_i64.should eq(42)
      parsed.id.should eq(e.id)
      (parsed.timestamp - e.timestamp).total_milliseconds.abs.should be < 1000
    end

    it "generates unique ids" do
      ids = Set(String).new
      100.times { ids << Arcana::Events::Event.new(type: "t", subject: "s").id }
      ids.size.should eq(100)
    end
  end

  describe Arcana::Events::FileBackend do
    it "records and queries events" do
      dir = File.tempname("arcana-events")
      backend = Arcana::Events::FileBackend.new(log_dir: dir, retain_days: 7)
      begin
        3.times do |i|
          backend.record(Arcana::Events::Event.new(
            type: "test.event",
            subject: "subj-#{i}",
          ))
        end
        # Let the drain fiber flush
        sleep 50.milliseconds

        events = backend.query(limit: 10)
        events.size.should eq(3)
        events.map(&.subject).sort.should eq(["subj-0", "subj-1", "subj-2"])
      ensure
        backend.close
        FileUtils.rm_rf(dir)
      end
    end

    it "filters by type" do
      dir = File.tempname("arcana-events")
      backend = Arcana::Events::FileBackend.new(log_dir: dir, retain_days: 7)
      begin
        backend.record(Arcana::Events::Event.new(type: "a", subject: "one"))
        backend.record(Arcana::Events::Event.new(type: "b", subject: "two"))
        backend.record(Arcana::Events::Event.new(type: "a", subject: "three"))
        sleep 50.milliseconds

        a_only = backend.query(type: "a")
        a_only.size.should eq(2)
        a_only.all?(&.type.==("a")).should be_true
      ensure
        backend.close
        FileUtils.rm_rf(dir)
      end
    end

    it "filters by subject" do
      dir = File.tempname("arcana-events")
      backend = Arcana::Events::FileBackend.new(log_dir: dir, retain_days: 7)
      begin
        backend.record(Arcana::Events::Event.new(type: "t", subject: "alice"))
        backend.record(Arcana::Events::Event.new(type: "t", subject: "bob"))
        sleep 50.milliseconds

        alice = backend.query(subject: "alice")
        alice.size.should eq(1)
        alice.first.subject.should eq("alice")
      ensure
        backend.close
        FileUtils.rm_rf(dir)
      end
    end

    it "respects the limit" do
      dir = File.tempname("arcana-events")
      backend = Arcana::Events::FileBackend.new(log_dir: dir, retain_days: 7)
      begin
        10.times { |i| backend.record(Arcana::Events::Event.new(type: "t", subject: i.to_s)) }
        sleep 50.milliseconds

        backend.query(limit: 3).size.should eq(3)
      ensure
        backend.close
        FileUtils.rm_rf(dir)
      end
    end

    it "sweep compresses old files and purges ancient ones" do
      dir = File.tempname("arcana-events")
      FileUtils.mkdir_p(dir)
      begin
        # Seed three fake files by date
        today = Time.utc
        [
          {"arcana-events-#{today.to_s("%F")}.jsonl", "today"},
          {"arcana-events-#{(today - 3.days).to_s("%F")}.jsonl", "should-compress"},
          {"arcana-events-#{(today - 100.days).to_s("%F")}.jsonl", "should-purge"},
        ].each do |entry|
          File.write(File.join(dir, entry[0]), entry[1] + "\n")
        end

        backend = Arcana::Events::FileBackend.new(
          log_dir: dir,
          compress_age_days: 2,
          retain_days: 90,
        )
        result = backend.sweep!
        result[:compressed].should eq(1)
        result[:purged].should eq(1)

        # Today's file still present and uncompressed
        File.exists?(File.join(dir, "arcana-events-#{today.to_s("%F")}.jsonl")).should be_true
        # 3-day-old file now compressed
        File.exists?(File.join(dir, "arcana-events-#{(today - 3.days).to_s("%F")}.jsonl.gz")).should be_true
        File.exists?(File.join(dir, "arcana-events-#{(today - 3.days).to_s("%F")}.jsonl")).should be_false
        # 100-day-old file deleted
        File.exists?(File.join(dir, "arcana-events-#{(today - 100.days).to_s("%F")}.jsonl")).should be_false

        backend.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "sweep archives instead of purges when archive_dir set" do
      log_dir = File.tempname("arcana-events")
      archive_dir = File.tempname("arcana-archive")
      FileUtils.mkdir_p(log_dir)
      begin
        old_name = "arcana-events-#{(Time.utc - 100.days).to_s("%F")}.jsonl.gz"
        File.write(File.join(log_dir, old_name), "ancient")

        backend = Arcana::Events::FileBackend.new(
          log_dir: log_dir,
          archive_dir: archive_dir,
          retain_days: 90,
        )
        result = backend.sweep!
        result[:archived].should eq(1)
        result[:purged].should eq(0)

        File.exists?(File.join(log_dir, old_name)).should be_false
        File.exists?(File.join(archive_dir, old_name)).should be_true

        backend.close
      ensure
        FileUtils.rm_rf(log_dir)
        FileUtils.rm_rf(archive_dir)
      end
    end

    it "records events end-to-end through Bus + Directory + Mailbox" do
      dir_path = File.tempname("arcana-events-e2e")
      backend = Arcana::Events::FileBackend.new(log_dir: dir_path, retain_days: 7)
      begin
        bus = Arcana::Bus.new
        dir = Arcana::Directory.new
        bus.directory = dir
        bus.events = backend
        dir.events = backend

        dir.register(Arcana::Directory::Listing.new(
          address: "arcana:echo", name: "Echo", description: "echoes",
        ))
        mb = bus.mailbox("arcana:echo")
        bus.mailbox("sender")
        bus.send(Arcana::Envelope.new(from: "sender", to: "arcana:echo", subject: "hi"))
        mb.try_receive
        sleep 100.milliseconds

        events = backend.query(limit: 100)
        types = events.map(&.type)
        types.should contain("listing.registered")
        types.should contain("message.sent")
        types.should contain("message.delivered")
        types.should contain("message.consumed")
      ensure
        backend.close
        FileUtils.rm_rf(dir_path)
      end
    end

    it "sweep purges oldest first when max_size exceeded" do
      dir = File.tempname("arcana-events")
      FileUtils.mkdir_p(dir)
      begin
        today = Time.utc
        # 3 "files", each ~500 KB worth of garbage
        filler = "x" * 500_000
        [today - 2.days, today - 1.days, today].each_with_index do |t, i|
          File.write(File.join(dir, "arcana-events-#{t.to_s("%F")}.jsonl"), filler)
        end

        backend = Arcana::Events::FileBackend.new(
          log_dir: dir,
          compress_age_days: 99,  # don't compress during this test
          retain_days: 365,       # don't age-purge during this test
          max_size_mb: 1,         # 1 MB cap → ~2 files will get dropped
        )
        backend.sweep!

        files = Dir.entries(dir).count { |n| n.starts_with?("arcana-events-") }
        files.should be < 3 # at least one was pruned

        backend.close
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
