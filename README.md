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

## Topics

A `#topic` is a log that everyone on the bus shares. A post is stored
once and numbered from 1. Anyone can read the topic from any point
without subscribing, and reading consumes nothing. Subscribing only buys
a short notification of each post.

```crystal
dir.register(Arcana::Directory::Listing.new("#releases", "Releases",
  "New versions of the arcana shards", kind: :topic, retention: 1000))

seq = bus.publish("#releases", Arcana::Envelope.new(from: "@arcana",
  subject: "arcana-core 0.19.0", payload: JSON::Any.new("Topics.")))

bus.topic_log("#releases").read(after: last_seen)  # posts after a number
bus.subscribe("#releases", "@mj")                   # optional
```

- **Registered first.** Publishing to an unregistered topic raises, so a
  typo (`#release`) fails instead of vanishing. Names take the `#`
  sigil, and may have dot-separated parts (`#arcana.releases`).
- **Retention.** A topic keeps its newest `retention` posts (10,000 by
  default, 100,000 at most) and drops older ones. `read` skips posts already dropped:
  when `log.first` is past `after + 1`, the reader missed some.
- **Seeing what's new.** A topic's directory listing shows `last_seq`
  and `last_published_at`. A reader compares those with the last number
  it read, and doesn't need to subscribe.
- **Notifications** come from the topic (`from` is `#releases`) with the
  post's subject. The payload says where to read the post:
  `{topic, seq, from, subject, correlation_id}`. A subscriber whose
  mailbox is full misses the notification, and can still read the post.
  Only the `"always"` cadence exists yet: a notification on every post.
- A topic has no mailbox: `send` to one raises.

Other topic names (no `#`) keep the older behavior: no registration, and
each subscriber gets a full copy of each post.

## Message ids and replies

An envelope can carry two mail headers, in the sense of the dot-ai mail
spec, which the bus passes along and never sets itself:

- `id`: the message's own id, hex, 8 digits or more. It's the same on
  the sender's and the recipient's copy, whatever carried the message.
  It isn't the `correlation_id`, which a request and its reply share.
- `re`: what the message answers, a message's `id` or a topic's post as
  `#topic:<seq>` (`#releases:3`).

```crystal
bus.send(Arcana::Envelope.new(from: "@arcana", to: "@mj",
  payload: JSON::Any.new("Yes, that works."), id: "5f1e09a2", re: "8325487c"))
```

A value in any other form is dropped, so neither field can carry
anything else into the headers of a file written from it.

## Development

```sh
crystal spec
crystal docs   # API docs in docs/
```

## Contributors

- [Thomas Sawyer](https://github.com/trans) - creator and maintainer
