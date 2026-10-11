module Arcana
  # Runs a service's requests concurrently: each in its own fiber, at most
  # `max_concurrent` at once (`nil` for no cap), and reports busy while at
  # least one request is in flight. `Toolset` and `Service` use one each.
  #
  # Before this, a service took one request at a time, so its throughput
  # was 1 / handler latency however much its backend could take: a
  # handler that spends 3 s on a provider call served 20 requests a minute.
  #
  # Two ways in:
  #
  # - `submit` waits for a free slot before starting the fiber. A mailbox
  #   reader uses it, so it stops taking messages while every slot is busy
  #   and the rest wait in the (bounded) mailbox.
  # - `submit_nowait` starts the fiber at once and lets it wait for a slot
  #   there. A WebSocket read loop uses it: the loop must keep reading,
  #   because it also carries the replies to requests a handler may be
  #   waiting on.
  class Dispatcher
    # A cap protects the backend a handler calls: most are HTTP APIs with
    # rate limits (Runware, for one, recommends 2–4 concurrent requests).
    DEFAULT_MAX_CONCURRENT = 8

    getter max_concurrent : Int32?
    @slots : Channel(Nil)? # a semaphore: one token per running request

    def initialize(@max_concurrent : Int32? = DEFAULT_MAX_CONCURRENT, @on_busy : Proc(Bool, Nil)? = nil)
      if (n = @max_concurrent) && n < 1
        raise ArgumentError.new("max_concurrent must be at least 1, or nil for no cap")
      end
      @slots = @max_concurrent.try { |n| Channel(Nil).new(n) }
      @in_flight = 0
      @mutex = Mutex.new
    end

    # Requests running now.
    def in_flight : Int32
      @mutex.synchronize { @in_flight }
    end

    # Wait for a free slot, then run `job` in its own fiber.
    def submit(&job : ->) : Nil
      @slots.try &.send(nil)
      spawn { run(job) }
    end

    # Run `job` in its own fiber, which waits there for a free slot.
    def submit_nowait(&job : ->) : Nil
      spawn do
        @slots.try &.send(nil)
        run(job)
      end
    end

    private def run(job : ->) : Nil
      change(+1)
      job.call
    rescue ex
      STDERR.puts "Arcana::Dispatcher: request handler raised: #{ex.message}"
    ensure
      change(-1)
      @slots.try &.receive
    end

    # Busy flips only between none and some in flight, under the lock, so
    # overlapping requests can't clear it while others still run.
    private def change(delta : Int32) : Nil
      @mutex.synchronize do
        before = @in_flight
        @in_flight += delta
        if before == 0 && @in_flight > 0
          notify(true)
        elsif before > 0 && @in_flight == 0
          notify(false)
        end
      end
    end

    private def notify(busy : Bool) : Nil
      @on_busy.try &.call(busy)
    rescue
      # The listing may be gone (the service stopped while requests ran).
    end
  end
end
