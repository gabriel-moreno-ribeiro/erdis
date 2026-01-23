# erdis

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

**EN:** a Redis-compatible in-memory data store in Erlang/OTP: RESP2 with incremental decoding and pipelining, strings/lists/hashes/sets, key expiry, pub/sub with process monitors, atomic commands through a single `gen_server`, and atomic snapshots. Works with the real `redis-cli` and `redis-benchmark` (~50k ops/s in CI). 35 EUnit tests. MIT.
