# erdis

> 🇺🇸 [English version below](#english)

Um banco de dados em memória compatível com Redis, em Erlang. Ele fala o protocolo do Redis de verdade (RESP), então `redis-cli`, `redis-benchmark` e qualquer client library conversam com ele. Strings, listas, hashes e sets, expiração de chaves, pipelining, publish/subscribe e snapshot em disco, em umas 600 linhas, sem nada além do OTP.

Erlang foi a linguagem que eu mais queria uma desculpa pra aprender, e um servidor de rede com milhares de conexões é exatamente o problema que ela foi feita pra resolver. Cada conexão é um processo, o store é um `gen_server`, e o resto é pattern matching.

```sh
make test              # suíte EUnit
make run PORT=6379     # serve; snapshots vão pra dump.erdis (SAVE)
redis-cli SET greeting "hello"
redis-cli GET greeting
redis-benchmark -q -n 10000 -t set,get,incr
```

## Design

- `resp.erl`: codificador RESP2 e um decodificador incremental que tira um frame por vez de um buffer de bytes (então comandos em pipeline e pacotes parciais funcionam) e aceita também o protocolo "inline" do telnet.
- `erdis_cmd.erl`: os comandos. As chaves vivem numa tabela ETS de `{Chave, Valor, ExpiraEm}`; chaves expiradas somem no acesso e numa varredura periódica. Os valores são etiquetados (`str`, `list`, `hash`, `set`), então erro de tipo devolve o `WRONGTYPE` do Redis.
- `erdis_store.erl`: um `gen_server` dono da tabela que executa um comando por vez, o que faz cada comando ser atômico exatamente como o núcleo single-thread do Redis, enquanto as conexões rodam em paralelo em processos separados. `SAVE` grava a tabela com `term_to_binary` (atomicamente, via rename) e o arquivo é carregado na partida.
- `erdis_pubsub.erl`: assinaturas de canal com monitores de processo, então um cliente que cai é removido sozinho.
- `erdis_server.erl`: o acceptor TCP e um processo por conexão. `SUBSCRIBE` coloca a conexão em modo push.

Comandos: `PING ECHO SELECT COMMAND INFO DBSIZE FLUSHDB KEYS TYPE DEL EXISTS RENAME EXPIRE PEXPIRE TTL PTTL PERSIST SET (EX PX NX XX KEEPTTL) GET GETSET MGET MSET APPEND STRLEN INCR DECR INCRBY DECRBY LPUSH RPUSH LPOP RPOP LLEN LINDEX LRANGE HSET HGET HDEL HGETALL HKEYS HLEN HEXISTS SADD SREM SMEMBERS SISMEMBER SCARD PUBLISH SUBSCRIBE UNSUBSCRIBE SAVE BGSAVE QUIT`.

No CI o `redis-benchmark` de verdade bate nele a uns 50 mil ops/s de SET/GET. Não é o Redis, mas pra um projeto de aprendizado eu fiquei satisfeito.

Testes: `make test` (codificação e decodificação do protocolo incluindo frames parciais e inline, globs do `KEYS`, cada família de comando com casos de erro, expiração (PX/EX/TTL/PERSIST/KEEPTTL e a varredura), e depois um servidor de verdade numa porta efêmera: comandos por TCP, um pipeline de 100 comandos num pacote só, pub/sub entre duas conexões com limpeza automática, 20 clientes fazendo 1000 `INCR` concorrentes que têm que terminar em exatamente 1000, um valor de 200 KB e um snapshot que sobrevive a um restart). O CI ainda dirige o servidor com `redis-cli` e roda `redis-benchmark`.

---

## English

A Redis-compatible in-memory database, in Erlang. It speaks the real Redis protocol (RESP), so `redis-cli`, `redis-benchmark` and any client library talk to it. Strings, lists, hashes and sets, key expiry, pipelining, publish/subscribe and snapshots to disk, in about 600 lines, with nothing beyond OTP.

Erlang was the language I most wanted an excuse to learn, and a network server with thousands of connections is exactly the problem it was made to solve. Every connection is a process, the store is a `gen_server`, and the rest is pattern matching.

```sh
make test              # EUnit suite
make run PORT=6379     # serves; snapshots go to dump.erdis (SAVE)
redis-cli SET greeting "hello"
redis-cli GET greeting
redis-benchmark -q -n 10000 -t set,get,incr
```

## Design

- `resp.erl`: a RESP2 encoder and an incremental decoder that pulls one frame at a time out of a byte buffer (so pipelined commands and partial packets work) and also accepts telnet's "inline" protocol.
- `erdis_cmd.erl`: the commands. Keys live in an ETS table of `{Key, Value, ExpiresAt}`; expired keys vanish on access and in a periodic sweep. Values are tagged (`str`, `list`, `hash`, `set`), so a type error returns Redis's `WRONGTYPE`.
- `erdis_store.erl`: a `gen_server` that owns the table and executes one command at a time, which makes every command atomic exactly like Redis's single-threaded core, while the connections run in parallel in separate processes. `SAVE` writes the table with `term_to_binary` (atomically, via rename) and the file is loaded at startup.
- `erdis_pubsub.erl`: channel subscriptions with process monitors, so a client that drops is removed on its own.
- `erdis_server.erl`: the TCP acceptor and one process per connection. `SUBSCRIBE` puts the connection in push mode.

Commands: `PING ECHO SELECT COMMAND INFO DBSIZE FLUSHDB KEYS TYPE DEL EXISTS RENAME EXPIRE PEXPIRE TTL PTTL PERSIST SET (EX PX NX XX KEEPTTL) GET GETSET MGET MSET APPEND STRLEN INCR DECR INCRBY DECRBY LPUSH RPUSH LPOP RPOP LLEN LINDEX LRANGE HSET HGET HDEL HGETALL HKEYS HLEN HEXISTS SADD SREM SMEMBERS SISMEMBER SCARD PUBLISH SUBSCRIBE UNSUBSCRIBE SAVE BGSAVE QUIT`.

In CI the real `redis-benchmark` hits it at around 50 thousand SET/GET ops/s. It's not Redis, but for a learning project I was satisfied.

Tests: `make test` (protocol encoding and decoding including partial and inline frames, `KEYS` globs, every command family with error cases, expiry (PX/EX/TTL/PERSIST/KEEPTTL and the sweep), and then a real server on an ephemeral port: commands over TCP, a pipeline of 100 commands in a single packet, pub/sub between two connections with automatic cleanup, 20 clients doing 1000 concurrent `INCR`s that have to end at exactly 1000, a 200 KB value and a snapshot that survives a restart). CI also drives the server with `redis-cli` and runs `redis-benchmark`.

MIT.
