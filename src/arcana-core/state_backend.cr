module Arcana
  # Abstract pluggable persistence for the bus snapshot blob.
  #
  # Decouples *how* state is stored (filesystem today; Postgres or S3
  # tomorrow) from *what* gets stored (the JSON snapshot built by
  # Arcana::Snapshot). Implementations must be safe for concurrent
  # `save` calls: a partial write must never be observable by `load`.
  #
  # The backend handles bytes-on-the-wire only. Serialization /
  # deserialization stays in Snapshot.
  abstract class StateBackend
    # Persist the given payload (typically a JSON string).
    # Must be atomic — a crash mid-save should leave the prior state
    # intact, not a torn or empty file.
    abstract def save(payload : String) : Nil

    # Return the most recent saved payload, or nil if nothing has
    # ever been saved.
    abstract def load : String?

    # Has anything been saved yet?
    abstract def exists? : Bool

    # Release any resources (file handles, DB connections). The
    # default is a no-op for backends that hold nothing open.
    def close : Nil
    end
  end

  # Persists state to a single file on the local filesystem.
  # Atomic writes via tmp + rename (POSIX-atomic on the same filesystem).
  class LocalFileBackend < StateBackend
    getter path : String

    def initialize(@path : String)
    end

    def save(payload : String) : Nil
      tmp = "#{@path}.tmp"
      File.write(tmp, payload)
      File.rename(tmp, @path)
    end

    def load : String?
      return nil unless File.exists?(@path)
      File.read(@path)
    end

    def exists? : Bool
      File.exists?(@path)
    end
  end
end
