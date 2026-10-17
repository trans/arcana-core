require "./spec_helper"

private class EventList < Arcana::Events::Backend
  getter events = [] of Arcana::Events::Event

  def record(event : Arcana::Events::Event) : Nil
    @events << event
  end

  def query(since : Time? = nil, type : String? = nil, subject : String? = nil, limit : Int32 = 100) : Array(Arcana::Events::Event)
    @events.select { |e| type.nil? || e.type == type }
  end
end

private def post(subject : String, text : String = subject, from : String = "@writer")
  Arcana::Envelope.new(from: from, subject: subject, payload: JSON::Any.new(text))
end

# A bus with a directory, the `#news` topic and two agents.
private def topic_bus(retention : Int32? = nil)
  bus = Arcana::Bus.new
  dir = Arcana::Directory.new
  bus.directory = dir
  dir.register(Arcana::Directory::Listing.new("#news", "News", "What's new", kind: Arcana::Directory::Kind::Topic, retention: retention))
  {"@writer", "@reader"}.each do |handle|
    dir.register(Arcana::Directory::Listing.new(handle, handle, ""))
    bus.mailbox(handle)
  end
  {bus, dir}
end

describe Arcana::TopicLog do
  it "numbers posts from 1 and reads after a number" do
    log = Arcana::TopicLog.new("#news")
    log.head.should eq(0)
    log.first.should eq(1)
    log.published_at.should be_nil
    3.times { |i| log.append(post("p#{i + 1}")).should eq(i + 1) }
    log.read.map(&.seq).should eq([1, 2, 3])
    log.read(after: 1).map(&.envelope.subject).should eq(["p2", "p3"])
    log.read(after: 3).should be_empty
    log.read(after: 0, limit: 2).map(&.seq).should eq([1, 2])
    log.read(after: 1, limit: 0).should be_empty
  end

  it "keeps the newest posts, up to its retention" do
    log = Arcana::TopicLog.new("#news", retention: 2)
    5.times { |i| log.append(post("p#{i + 1}")) }
    log.size.should eq(2)
    log.head.should eq(5)
    log.first.should eq(4)
    # A reader that last saw 1 gets what's left; first > after + 1 shows
    # it missed some.
    log.read(after: 1).map(&.seq).should eq([4, 5])
    log.retention = 1
    log.read.map(&.seq).should eq([5])
  end

  it "rejects a retention under one post or over the maximum" do
    expect_raises(Arcana::Error, /from 1 to 100000/) { Arcana::TopicLog.new("#news", retention: 0) }
    expect_raises(Arcana::Error, /from 1 to 100000/) { Arcana::TopicLog.new("#news", retention: 100_001) }
  end

  it "restores from a dump" do
    log = Arcana::TopicLog.new("#news")
    3.times { |i| log.append(post("p#{i + 1}")) }
    snap = log.dump
    copy = Arcana::TopicLog.new("#news")
    copy.load_snapshot(snap[:head], snap[:posts])
    copy.head.should eq(3)
    copy.append(post("p4")).should eq(4)
    copy.read(after: 2).map(&.envelope.subject).should eq(["p3", "p4"])
  end
end

describe "Directory topics" do
  it "takes `#` addresses as topics, with dotted names" do
    dir = Arcana::Directory.new
    dir.register(Arcana::Directory::Listing.new("#arcana.releases", "Releases", ""))
    dir.lookup("#arcana.releases").not_nil!.kind.topic?.should be_true
    Arcana::Directory.topic?("#news").should be_true
    Arcana::Directory.agent?("#news").should be_false
  end

  it "rejects malformed topic names" do
    {"#", "#News", "#a..b", "#a.", "#.a", "#a:b"}.each do |bad|
      expect_raises(Arcana::Error) { Arcana::Directory.validate_address(bad) }
    end
  end

  it "keeps the `#` sigil for topics" do
    dir = Arcana::Directory.new
    expect_raises(Arcana::Error, /must use the `#` sigil/) do
      dir.register(Arcana::Directory::Listing.new("news", "", "", kind: Arcana::Directory::Kind::Topic))
    end
    expect_raises(Arcana::Error, /reserved for topics/) do
      dir.register(Arcana::Directory::Listing.new("#news", "", "", kind: Arcana::Directory::Kind::Agent))
    end
    expect_raises(Arcana::Error, /reserved for topics/) do
      dir.register(Arcana::Directory::Listing.new("#news", "", "", kind: Arcana::Directory::Kind::Service))
    end
  end

  it "lists a topic with its newest post, retention and subscribers" do
    bus, dir = topic_bus(retention: 50)
    listing = JSON.parse(dir.to_json(dir.lookup("#news").not_nil!))
    listing["kind"].should eq("topic")
    listing["retention"].should eq(50)
    listing["last_seq"].should eq(0)
    listing["last_published_at"]?.should be_nil
    listing["busy"]?.should be_nil

    bus.subscribe("#news", "@reader")
    bus.publish("#news", post("hello"))
    listing = JSON.parse(dir.to_json).as_a.find! { |l| l["address"] == "#news" }
    listing["last_seq"].should eq(1)
    listing["last_published_at"].as_s.should_not be_empty
    listing["subscribers"].should eq(1)
  end
end

describe "Bus topics" do
  it "stores a post once and lets anyone read it without subscribing" do
    bus, _ = topic_bus
    bus.publish("#news", post("first", "one")).should eq(1)
    bus.publish("#news", post("second", "two")).should eq(2)

    posts = bus.topic_log("#news").read(after: 1)
    posts.size.should eq(1)
    posts[0].seq.should eq(2)
    posts[0].envelope.to.should eq("#news")
    posts[0].envelope.from.should eq("@writer")
    posts[0].envelope.payload.as_s.should eq("two")
    # Reading consumes nothing.
    bus.topic_log("#news").read.size.should eq(2)
    bus.pending("@reader").should eq(0)
  end

  it "keeps a post's id and what it answers" do
    bus, _ = topic_bus
    env = Arcana::Envelope.new(from: "@writer", subject: "re", payload: JSON::Any.new("yes"), id: "8325487c", re: "#news:1")
    bus.publish("#news", env)
    stored = bus.topic_log("#news").read[0].envelope
    {stored.id, stored.re}.should eq({"8325487c", "#news:1"})
  end

  it "notifies subscribers with where to read the post, not the post" do
    bus, _ = topic_bus
    bus.subscribe("#news", "@reader")
    bus.publish("#news", Arcana::Envelope.new(from: "@writer", subject: "Q3 notes", payload: JSON::Any.new("long text"), correlation_id: "abc"))

    note = bus.mailbox("@reader").try_receive.not_nil!
    note.from.should eq("#news")
    note.to.should eq("@reader")
    note.subject.should eq("Q3 notes")
    note.correlation_id.should_not eq("abc")
    note.payload.should eq(JSON.parse(%({"topic":"#news","seq":1,"from":"@writer","subject":"Q3 notes","correlation_id":"abc"})))
    bus.mailbox("@writer").try_receive.should be_nil
  end

  it "names an untitled post by its number in the notification" do
    bus, _ = topic_bus
    bus.subscribe("#news", "@reader")
    bus.publish("#news", post(""))
    bus.mailbox("@reader").try_receive.not_nil!.subject.should eq("post 1")
  end

  it "skips a subscriber whose mailbox is full; the post stays readable" do
    bus, dir = topic_bus
    bus.mailbox_factory = ->(address : String) { Arcana::Mailbox.new(address, max_queue: 1) }
    dir.register(Arcana::Directory::Listing.new("@busy", "", ""))
    full = bus.mailbox("@busy")
    full.deliver(Arcana::Envelope.new(from: "@x"))
    bus.subscribe("#news", "@busy")
    bus.subscribe("#news", "@reader")

    bus.publish("#news", post("hi")).should eq(1)
    full.pending.should eq(1)
    bus.pending("@reader").should eq(1)
    bus.topic_log("#news").read.size.should eq(1)
  end

  it "refuses an unregistered topic" do
    bus, _ = topic_bus
    expect_raises(Arcana::Error, /no topic #nope/) { bus.publish("#nope", post("x")) }
    expect_raises(Arcana::Error, /no topic #nope/) { bus.subscribe("#nope", "@reader") }
    expect_raises(Arcana::Error, /no topic/) { Arcana::Bus.new.publish("#news", post("x")) }
  end

  it "takes only the `always` cadence, and only subscribers with a mailbox" do
    bus, _ = topic_bus
    expect_raises(Arcana::Error, /isn't implemented yet/) { bus.subscribe("#news", "@reader", cadence: "daily") }
    expect_raises(Arcana::Error, /no mailbox/) { bus.subscribe("#news", "@ghost") }
    bus.subscribers("#news").should be_empty
  end

  it "won't send to a topic or give it a mailbox" do
    bus, _ = topic_bus
    expect_raises(Arcana::Error, /is a topic: publish/) { bus.send(Arcana::Envelope.new(from: "@writer", to: "#news")) }
    bus.send?(Arcana::Envelope.new(from: "@writer", to: "#news")).should be_false
    expect_raises(Arcana::Error, /log instead of a mailbox/) { bus.mailbox("#news") }
  end

  it "follows the listing's retention" do
    bus, dir = topic_bus(retention: 2)
    3.times { |i| bus.publish("#news", post("p#{i + 1}")) }
    bus.topic_log("#news").read.map(&.seq).should eq([2, 3])
    dir.claim(Arcana::Directory::Listing.new("#news", "News", "", kind: Arcana::Directory::Kind::Topic, retention: 1), "owner")
    bus.topic_log("#news").read.map(&.seq).should eq([3])
  end

  it "drops a removed topic's log and subscribers" do
    bus, _ = topic_bus
    bus.subscribe("#news", "@reader")
    bus.publish("#news", post("hi"))
    bus.remove_topic("#news")
    bus.topic_log?("#news").should be_nil
    bus.subscribers("#news").should be_empty
  end

  it "records the post's number in the event log" do
    bus, _ = topic_bus
    events = EventList.new
    bus.events = events
    bus.publish("#news", post("hi"))
    event = events.query(type: "topic.published").first
    event.subject.should eq("#news")
    event.metadata.not_nil!["seq"].should eq(1)
  end
end
