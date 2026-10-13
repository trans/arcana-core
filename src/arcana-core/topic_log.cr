require "./error"
require "./envelope"

module Arcana
  # The posts of one `#topic`: a log on the bus that everyone shares. A
  # post is stored once and numbered from 1; anyone reads from any point
  # with `read(after:)`, without subscribing and without consuming it.
  # The log keeps the newest `retention` posts and drops older ones.
  class TopicLog
    DEFAULT_RETENTION = 10_000

    # A post and its number in the topic.
    record Post, seq : Int64, envelope : Envelope

    getter address : String

    def initialize(@address : String, retention : Int32 = DEFAULT_RETENTION)
      TopicLog.check_retention!(retention)
      @retention = retention
      @posts = Deque(Post).new
      @head = 0_i64
      @mutex = Mutex.new
    end

    def self.check_retention!(retention : Int32) : Nil
      raise Error.new("retention must be at least 1 post, got #{retention}") if retention < 1
    end

    # The newest post's number; 0 before the first post.
    def head : Int64
      @mutex.synchronize { @head }
    end

    # The oldest kept post's number; `head + 1` when none are kept.
    def first : Int64
      @mutex.synchronize { first_seq }
    end

    # When the newest post was published; nil before the first.
    def published_at : Time?
      @mutex.synchronize { @posts.last?.try(&.envelope.timestamp) }
    end

    # How many posts are kept.
    def size : Int32
      @mutex.synchronize { @posts.size }
    end

    def retention : Int32
      @mutex.synchronize { @retention }
    end

    # Keep at most `retention` posts from now on, dropping the oldest.
    def retention=(retention : Int32)
      TopicLog.check_retention!(retention)
      @mutex.synchronize do
        @retention = retention
        trim
      end
    end

    # Add a post; returns its number.
    def append(envelope : Envelope) : Int64
      @mutex.synchronize do
        @head += 1
        @posts.push(Post.new(@head, envelope))
        trim
        @head
      end
    end

    # The posts numbered after `after`, oldest first, at most `limit` of
    # them. Posts already dropped are skipped: compare `first` with
    # `after + 1` to tell whether any were missed.
    def read(after : Int64 = 0_i64, limit : Int32? = nil) : Array(Post)
      @mutex.synchronize do
        start = Math.max(after - first_seq + 1, 0_i64)
        stop = @posts.size.to_i64
        stop = Math.min(stop, start + Math.max(limit, 0)) if limit
        start < stop ? (start...stop).map { |i| @posts[i] } : [] of Post
      end
    end

    # The log's state for a snapshot.
    def dump : NamedTuple(head: Int64, posts: Array(Post))
      @mutex.synchronize { {head: @head, posts: @posts.to_a} }
    end

    # Restore a snapshot, replacing what the log holds. Posts must be in
    # order with consecutive numbers, as `dump` gives them.
    def load_snapshot(head : Int64, posts : Array(Post)) : Nil
      @mutex.synchronize do
        @posts.clear
        posts.each { |p| @posts.push(p) }
        @head = Math.max(head, posts.last?.try(&.seq) || 0_i64)
        trim
      end
    end

    private def first_seq : Int64
      @posts.first?.try(&.seq) || @head + 1
    end

    private def trim : Nil
      while @posts.size > @retention
        @posts.shift
      end
    end
  end
end
