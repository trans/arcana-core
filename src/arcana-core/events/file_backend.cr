require "file_utils"
require "compress/gzip"

module Arcana
  module Events
    # Writes events as JSONL to a directory, one file per day.
    #
    # Files:
    #   <dir>/arcana-events-YYYY-MM-DD.jsonl         (today, uncompressed)
    #   <dir>/arcana-events-YYYY-MM-DD.jsonl.gz      (older days, compressed)
    #
    # The `record` call is non-blocking: events go onto a buffered
    # channel, drained by a background fiber that appends to the daily
    # file. If the channel fills up, events are dropped and the drop
    # count is logged to STDERR. (Better to drop than to block every
    # Bus.send on disk I/O.)
    #
    # Retention (via `sweep!`):
    #   - Files older than `compress_age_days` are gzipped and the
    #     uncompressed source is deleted.
    #   - Files (.jsonl or .jsonl.gz) older than `retain_days` are
    #     either deleted or moved to `archive_dir` (if set).
    #   - If `max_size_mb` is set and total dir size exceeds it, the
    #     oldest files are removed first until under the cap.
    class FileBackend < Backend
      FILENAME_REGEX = /\Aarcana-events-(\d{4}-\d{2}-\d{2})\.jsonl(?:\.gz)?\z/

      property log_dir : String
      property compress_age_days : Int32
      property retain_days : Int32
      property archive_dir : String?
      property max_size_mb : Int32?
      getter dropped : Int64 = 0i64

      @channel : Channel(Event)
      @drain_fiber : Fiber?
      @mutex : Mutex

      def initialize(
        @log_dir : String,
        *,
        buffer_size : Int32 = 1024,
        @compress_age_days : Int32 = 2,
        @retain_days : Int32 = 90,
        @archive_dir : String? = nil,
        @max_size_mb : Int32? = nil,
      )
        FileUtils.mkdir_p(@log_dir)
        if ad = @archive_dir
          FileUtils.mkdir_p(ad)
        end
        @channel = Channel(Event).new(buffer_size)
        @mutex = Mutex.new
        @drain_fiber = spawn { drain }
      end

      def record(event : Event) : Nil
        # Non-blocking send; drop on overflow rather than block the hot path.
        select
        when @channel.send(event)
          # sent
        else
          @mutex.synchronize { @dropped += 1 }
          # Rate-limit the stderr log to once per 1000 drops.
          STDERR.puts "Arcana::Events: dropped #{@dropped} event(s) (channel full)" if @dropped % 1000 == 1
        end
      end

      def query(
        since : Time? = nil,
        type : String? = nil,
        subject : String? = nil,
        limit : Int32 = 100,
      ) : Array(Event)
        cutoff = since
        result = [] of Event
        # Walk files newest-first. Today's plain .jsonl first, then .jsonl.gz
        # descending by date.
        files = Dir.entries(@log_dir).compact_map do |name|
          m = FILENAME_REGEX.match(name) || next
          date = Time.parse_utc(m[1], "%F")
          {path: File.join(@log_dir, name), date: date, gz: name.ends_with?(".gz")}
        end.sort_by { |f| f[:date].to_unix }.reverse

        files.each do |f|
          break if result.size >= limit
          # Skip whole file if its day is before cutoff date
          if c = cutoff
            next if f[:date] < Time.utc(c.year, c.month, c.day, 0, 0, 0)
          end
          scan_file(f[:path], f[:gz], cutoff, type, subject, limit, result)
        end

        result
      end

      def close : Nil
        @channel.close rescue nil
        # Wait a brief moment for the drain fiber to flush. Crystal
        # doesn't expose fiber.join directly; we yield to let it run.
        3.times { Fiber.yield; sleep 10.milliseconds }
      end

      # Retention sweep — compresses old files and purges/archives very old ones.
      # Safe to call periodically from any fiber.
      def sweep! : NamedTuple(compressed: Int32, purged: Int32, archived: Int32)
        compressed = 0
        purged = 0
        archived = 0
        now = Time.utc

        files = Dir.entries(@log_dir).compact_map do |name|
          m = FILENAME_REGEX.match(name) || next
          date = Time.parse_utc(m[1], "%F")
          {name: name, path: File.join(@log_dir, name), date: date, gz: name.ends_with?(".gz")}
        end

        files.each do |f|
          age_days = (now - f[:date]).total_days.to_i

          # Purge / archive files older than retain_days
          if age_days > @retain_days
            if ad = @archive_dir
              FileUtils.mv(f[:path], File.join(ad, f[:name]))
              archived += 1
            else
              File.delete(f[:path])
              purged += 1
            end
            next
          end

          # Compress files older than compress_age_days (skip today's open file)
          if !f[:gz] && age_days >= @compress_age_days
            gz_path = "#{f[:path]}.gz"
            File.open(f[:path], "r") do |src|
              File.open(gz_path, "w") do |dst|
                Compress::Gzip::Writer.open(dst) { |gz| IO.copy(src, gz) }
              end
            end
            File.delete(f[:path])
            compressed += 1
          end
        end

        # Size cap enforcement (oldest first).
        if cap_mb = @max_size_mb
          cap_bytes = cap_mb.to_i64 * 1024 * 1024
          remaining = Dir.entries(@log_dir).compact_map do |name|
            m = FILENAME_REGEX.match(name) || next
            path = File.join(@log_dir, name)
            {name: name, path: path, date: Time.parse_utc(m[1], "%F"), size: File.size(path)}
          end.sort_by { |f| f[:date].to_unix }

          total = remaining.sum { |f| f[:size] }
          while total > cap_bytes && !remaining.empty?
            victim = remaining.shift
            File.delete(victim[:path])
            total -= victim[:size]
            purged += 1
          end
        end

        {compressed: compressed, purged: purged, archived: archived}
      end

      # -- Private --

      private def drain
        loop do
          event = @channel.receive? || break # channel closed
          write_event(event)
        end
      rescue ex
        STDERR.puts "Arcana::Events drain error: #{ex.message}"
      end

      private def write_event(event : Event)
        path = current_file_path(event.timestamp)
        File.open(path, "a") do |f|
          f.puts event.to_json
        end
      rescue ex
        STDERR.puts "Arcana::Events write error: #{ex.message}"
      end

      private def current_file_path(ts : Time) : String
        File.join(@log_dir, "arcana-events-#{ts.to_s("%F")}.jsonl")
      end

      private def scan_file(
        path : String,
        gzipped : Bool,
        cutoff : Time?,
        type_filter : String?,
        subject_filter : String?,
        limit : Int32,
        result : Array(Event),
      )
        io : IO = File.open(path, "r")
        io = Compress::Gzip::Reader.new(io) if gzipped
        begin
          io.each_line do |line|
            next if line.empty?
            ev = Event.from_json(line) rescue next
            next if cutoff && ev.timestamp < cutoff
            next if type_filter && ev.type != type_filter
            next if subject_filter && ev.subject != subject_filter
            result << ev
            break if result.size >= limit
          end
        ensure
          io.close
        end
      end
    end
  end
end
