# erdis

A Redis-compatible in-memory data store written from scratch in Erlang.
It speaks the real Redis protocol (RESP), so `redis-cli`, `redis-benchmark`
and any Redis client library can talk to it. Strings, lists, hashes and
sets, key expiry, pipelining, publish/subscribe and snapshots to disk are
implemented in about 600 lines, with no dependencies beyond OTP.

```sh
make test              # EUnit suite
make run PORT=6379     # serve; snapshots go to dump.erdis (SAVE)
redis-cli SET greeting "hello"
redis-cli GET greeting
redis-benchmark -q -n 10000 -t set,get,incr
```

## Design

- `resp.erl` — RESP2 encoder and an incremental decoder that pulls one
  frame at a time from a byte buffer (so pipelined commands and partial
  packets are handled) and also accepts the inline protocol used by
  telnet.
- `erdis_cmd.erl` — the commands. Keys live in one ETS table of
  `{Key, Value, ExpireAt}`; expired keys are dropped lazily on access and
  by a periodic sweep. Values are tagged (`str`, `list`, `hash`, `set`),
  so type errors produce Redis' `WRONGTYPE` reply.
- `erdis_store.erl` — a `gen_server` that owns the table and executes
  commands one at a time, which makes every command atomic exactly like
  Redis' single-threaded core, while the connections themselves run in
  parallel Erlang processes. `SAVE` writes the table with
  `term_to_binary` (atomically, via rename) and the file is loaded on
  start-up.
- `erdis_pubsub.erl` — channel subscriptions with process monitors, so a
  client that disconnects is removed automatically.
- `erdis_server.erl` — the TCP acceptor and one process per connection.
  `SUBSCRIBE` puts a connection into push mode, where published messages
  are delivered as `message` arrays.
- `erdis.erl` — start/stop and the `erl -s erdis run` entry point.

### Commands

`PING ECHO SELECT COMMAND INFO DBSIZE FLUSHDB KEYS TYPE DEL EXISTS RENAME
EXPIRE PEXPIRE TTL PTTL PERSIST SET (EX PX NX XX KEEPTTL) GET GETSET MGET
MSET APPEND STRLEN INCR DECR INCRBY DECRBY LPUSH RPUSH LPOP RPOP LLEN
LINDEX LRANGE HSET HGET HDEL HGETALL HKEYS HLEN HEXISTS SADD SREM SMEMBERS
SISMEMBER SCARD PUBLISH SUBSCRIBE UNSUBSCRIBE SAVE BGSAVE QUIT`

## Tests

`make test` runs EUnit: protocol encoding/decoding including partial and
inline frames, glob patterns for `KEYS`, every command family with error
cases, expiry (PX/EX/TTL/PERSIST/KEEPTTL and the sweep), and then a real
server on an ephemeral port: commands over TCP, a 100-command pipeline in
one packet, pub/sub across two connections with automatic cleanup, 20
clients doing 1000 concurrent `INCR`s that must end at exactly 1000, a
200 KB value, and a snapshot that survives a restart. CI additionally
drives the server with `redis-cli` and runs `redis-benchmark` against it.

## License

MIT
