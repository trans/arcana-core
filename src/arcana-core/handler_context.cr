module Arcana
  # What a `Toolset` tool or `Service` handler gets besides its data: the
  # request as it arrived, and `exclusive` for state it shares with the
  # other handlers.
  #
  #   ts.tool("shoot", "Take a picture") do |data, ctx|
  #     image = camera.shoot(data)                 # concurrent: the slow part
  #     ctx.exclusive(:ledger) { ledger << cost }  # one at a time: the shared write
  #     image
  #   end
  #
  # Handlers that don't need it can keep taking just the data:
  # `{ |data| ... }`.
  class HandlerContext
    # The request: `from`, `subject`, `correlation_id`, the raw payload.
    getter envelope : Envelope

    def initialize(@envelope : Envelope, @locks : Locks)
    end

    # Run the block while no other handler of this toolset (or service)
    # runs a block under the same key; returns the block's value. Use it
    # for the shared part of a handler only, so the rest stays concurrent.
    # Locks are reentrant: a block may take the same key again.
    def exclusive(key : String | Symbol = :default, &)
      @locks.synchronize(key.to_s) { yield }
    end
  end

  # Named locks, one per key, made on first use.
  class Locks
    def initialize
      @locks = {} of String => Mutex
      @mutex = Mutex.new
    end

    def synchronize(key : String, &)
      lock = @mutex.synchronize { @locks[key] ||= Mutex.new(:reentrant) }
      lock.synchronize { yield }
    end
  end
end
