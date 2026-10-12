# arcana-core

The mechanics of the [Arcana](https://github.com/trans/arcana) agent bus,
for Crystal: envelopes, mailboxes, the directory, the bus itself, and the
building blocks for a service on it (`Toolset`, `Service`) or a client of
it (`Client`). The daemon, its MCP bridge and the session hooks live in
`arcana`; this shard is what both sides build on.

## Installation

Add the dependency to your `shard.yml`, then run `shards install`:

```yaml
dependencies:
  arcana-core:
    github: trans/arcana-core
```

## Writing a service

A `Toolset` puts several tools behind one bus address. Over a `Client`, it
runs in your own process and joins the daemon's bus:

```crystal
require "arcana-core"

client = Arcana::Client.new(
  url: "ws://localhost:19118/bus",
  address: "mj:camera", name: "mj:camera",
  description: "Image generation behind a camera abstraction",
  kind: Arcana::Directory::Kind::Service,
)
ts = Arcana::Toolset.new(client: client, max_concurrent: 16)

ts.tool("shoot", "Take a picture") do |data|
  JSON::Any.new({"image" => JSON::Any.new(shoot(data))})
end

ts.run # joins the bus, then serves until the connection closes
```

Callers send `{"tool":"shoot", ...}` to the address; `{"tool":"help"}`
returns the manifest. `Toolset#start` alone only installs the handler, so
use `run` (or `start` then `client.connect`), and to serve several
toolsets from one process, run all but the last in fibers.

### Requests run concurrently

Each request runs in its own fiber, at most `max_concurrent` at once
(default 8, `nil` for no cap). Set the cap to what your handlers' backend
can take. Two things follow from running at the same time:

**A toolset in front of several backends wants lanes.** One cap for the
whole toolset lets requests queued for a slow backend crowd out ones
another backend could serve. Give each backend a lane with its own cap,
and say which lane a request takes, fixed per tool or worked out from its
data:

```crystal
ts.lane("runware", max_concurrent: 3)
ts.lane("google", max_concurrent: 6)
ts.tool("shoot", "Take a picture",
  lane: ->(data : JSON::Any) { backend_for(data) }) do |data|
  # ...
end
```

A request waits for its lane before it takes one of the toolset's slots,
so a busy lane holds up no one else; `max_concurrent` stays the overall
backstop.

**State that handlers share needs `exclusive`.** Even though fibers share
one thread, any IO can pause a handler partway through while another runs.
An append-only log, a counter read and written around a call, or a cached
client can be corrupted that way. A handler's optional second argument
gives it `exclusive`, which runs one block at a time per key and leaves the
rest of the handler concurrent:

```crystal
ts.tool("shoot", "Take a picture") do |data, ctx|
  image = shoot(data)                        # concurrent: the slow part
  ctx.exclusive(:ledger) { ledger << cost }  # one at a time: the shared write
  JSON::Any.new(image)
end
```

Code outside handlers can share the same locks with `ts.exclusive(:ledger)`.

`exclusive` is for state the service owns. State that other code also
touches, such as a log a CLI writes outside any service, should carry its
own lock (a `Mutex` inside the log), so every caller is covered and the
log doesn't depend on a toolset that may not exist when the CLI runs.

`Service`, a single-purpose service registered in-process, has the same
`max_concurrent:` and `exclusive`.

## Development

```sh
crystal spec
crystal docs   # API docs in docs/
```

## Contributors

- [Thomas Sawyer](https://github.com/trans) - creator and maintainer
