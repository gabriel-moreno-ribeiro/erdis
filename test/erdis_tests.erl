%% EUnit tests: protocol, commands, expiry, the TCP server, pub/sub,
%% pipelining, concurrency and snapshots.
-module(erdis_tests).
-include_lib("eunit/include/eunit.hrl").

%% ------------------------------------------------------------- protocol ---
resp_test_() ->
    Enc = fun(T) -> iolist_to_binary(resp:encode(T)) end,
    [?_assertEqual(<<"+OK\r\n">>, Enc({simple, <<"OK">>})),
     ?_assertEqual(<<"-ERR bad\r\n">>, Enc({error, <<"ERR bad">>})),
     ?_assertEqual(<<":42\r\n">>, Enc(42)),
     ?_assertEqual(<<"$-1\r\n">>, Enc(null)),
     ?_assertEqual(<<"$5\r\nhello\r\n">>, Enc(<<"hello">>)),
     ?_assertEqual(<<"*2\r\n$1\r\na\r\n:1\r\n">>, Enc([<<"a">>, 1])),
     ?_assertEqual({ok, [<<"SET">>, <<"k">>, <<"v">>], <<>>}, resp:decode(<<"*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n">>)),
     ?_assertEqual({ok, [<<"GET">>, <<"k">>], <<"rest">>}, resp:decode(<<"*2\r\n$3\r\nGET\r\n$1\r\nk\r\nrest">>)),
     ?_assertEqual(incomplete, resp:decode(<<"*2\r\n$3\r\nGE">>)),
     ?_assertEqual(incomplete, resp:decode(<<"$5\r\nhel">>)),
     ?_assertEqual({ok, [<<"PING">>], <<>>}, resp:decode(<<"PING\r\n">>)),
     ?_assertEqual({ok, [<<"SET">>, <<"a">>, <<"b">>], <<>>}, resp:decode(<<"SET  a b\r\n">>)),
     ?_assertEqual({ok, null, <<>>}, resp:decode(<<"$-1\r\n">>)),
     ?_assertEqual({ok, {simple, <<"PONG">>}, <<>>}, resp:decode(<<"+PONG\r\n">>)),
     ?_assertEqual({ok, -5, <<>>}, resp:decode(<<":-5\r\n">>)),
     ?_assertEqual({ok, <<"a\r\nb">>, <<>>}, resp:decode(<<"$4\r\na\r\nb\r\n">>))].

glob_test_() ->
    [?_assert(erdis_cmd:glob_match(<<"*">>, <<"anything">>)),
     ?_assert(erdis_cmd:glob_match(<<"user:*">>, <<"user:42">>)),
     ?_assertNot(erdis_cmd:glob_match(<<"user:*">>, <<"order:1">>)),
     ?_assert(erdis_cmd:glob_match(<<"h?llo">>, <<"hello">>)),
     ?_assertNot(erdis_cmd:glob_match(<<"h?llo">>, <<"hllo">>)),
     ?_assert(erdis_cmd:glob_match(<<"h[ae]llo">>, <<"hallo">>)),
     ?_assertNot(erdis_cmd:glob_match(<<"h[ae]llo">>, <<"hillo">>)),
     ?_assert(erdis_cmd:glob_match(<<"a.b">>, <<"a.b">>)),
     ?_assertNot(erdis_cmd:glob_match(<<"a.b">>, <<"axb">>))].

%% ------------------------------------------------------------- commands ---
run(Tab, Cmd) -> erdis_cmd:run(Tab, Cmd).

with_tab(Fun) ->
    Tab = ets:new(t, [set, private]),
    try Fun(Tab) after ets:delete(Tab) end.

strings_test() ->
    with_tab(fun(T) ->
        ?assertEqual({simple, <<"PONG">>}, run(T, [<<"ping">>])),
        ?assertEqual(null, run(T, [<<"GET">>, <<"k">>])),
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"SET">>, <<"k">>, <<"v">>])),
        ?assertEqual(<<"v">>, run(T, [<<"get">>, <<"k">>])),
        ?assertEqual(null, run(T, [<<"SET">>, <<"k">>, <<"w">>, <<"NX">>])),
        ?assertEqual(<<"v">>, run(T, [<<"GET">>, <<"k">>])),
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"SET">>, <<"k">>, <<"w">>, <<"XX">>])),
        ?assertEqual(null, run(T, [<<"SET">>, <<"missing">>, <<"w">>, <<"XX">>])),
        ?assertEqual(3, run(T, [<<"APPEND">>, <<"k">>, <<"12">>])),
        ?assertEqual(<<"w12">>, run(T, [<<"GET">>, <<"k">>])),
        ?assertEqual(3, run(T, [<<"STRLEN">>, <<"k">>])),
        ?assertEqual(<<"w12">>, run(T, [<<"GETSET">>, <<"k">>, <<"x">>])),
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"MSET">>, <<"a">>, <<"1">>, <<"b">>, <<"2">>])),
        ?assertEqual([<<"1">>, <<"2">>, null], run(T, [<<"MGET">>, <<"a">>, <<"b">>, <<"c">>])),
        ?assertEqual(1, run(T, [<<"INCR">>, <<"n">>])),
        ?assertEqual(11, run(T, [<<"INCRBY">>, <<"n">>, <<"10">>])),
        ?assertEqual(8, run(T, [<<"DECRBY">>, <<"n">>, <<"3">>])),
        ?assertEqual(7, run(T, [<<"DECR">>, <<"n">>])),
        ?assertMatch({error, <<"ERR value is not an integer", _/binary>>}, run(T, [<<"INCR">>, <<"k">>])),
        ?assertMatch({error, <<"ERR syntax error">>}, run(T, [<<"SET">>, <<"k">>, <<"v">>, <<"BOGUS">>])),
        ?assertMatch({error, <<"ERR unknown command 'NOPE'">>}, run(T, [<<"NOPE">>])),
        ?assertMatch({error, <<"ERR wrong number of arguments for 'get' command">>}, run(T, [<<"GET">>])),
        ?assertEqual(2, run(T, [<<"DEL">>, <<"a">>, <<"b">>, <<"zzz">>])),
        ?assertEqual(1, run(T, [<<"EXISTS">>, <<"k">>, <<"a">>])),
        ?assertEqual({simple, <<"string">>}, run(T, [<<"TYPE">>, <<"k">>])),
        ?assertEqual({simple, <<"none">>}, run(T, [<<"TYPE">>, <<"a">>])),
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"RENAME">>, <<"k">>, <<"k2">>])),
        ?assertEqual(<<"x">>, run(T, [<<"GET">>, <<"k2">>])),
        ?assertEqual([<<"k2">>, <<"n">>], lists:sort(run(T, [<<"KEYS">>, <<"*">>]))),
        ?assertEqual(2, run(T, [<<"DBSIZE">>])),
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"FLUSHDB">>])),
        ?assertEqual(0, run(T, [<<"DBSIZE">>]))
    end).

expiry_test() ->
    with_tab(fun(T) ->
        ?assertEqual({simple, <<"OK">>}, run(T, [<<"SET">>, <<"k">>, <<"v">>, <<"PX">>, <<"80">>])),
        ?assertEqual(<<"v">>, run(T, [<<"GET">>, <<"k">>])),
        Ttl = run(T, [<<"PTTL">>, <<"k">>]),
        ?assert(Ttl > 0 andalso Ttl =< 80),
        timer:sleep(120),
        ?assertEqual(null, run(T, [<<"GET">>, <<"k">>])),
        ?assertEqual(-2, run(T, [<<"TTL">>, <<"k">>])),
        run(T, [<<"SET">>, <<"p">>, <<"1">>]),
        ?assertEqual(-1, run(T, [<<"TTL">>, <<"p">>])),
        ?assertEqual(1, run(T, [<<"EXPIRE">>, <<"p">>, <<"100">>])),
        ?assert(run(T, [<<"TTL">>, <<"p">>]) >= 99),
        ?assertEqual(1, run(T, [<<"PERSIST">>, <<"p">>])),
        ?assertEqual(-1, run(T, [<<"TTL">>, <<"p">>])),
        ?assertEqual(0, run(T, [<<"EXPIRE">>, <<"nokey">>, <<"1">>])),
        %% SET without options clears a pending expiry; KEEPTTL keeps it
        ?assertEqual(1, run(T, [<<"PEXPIRE">>, <<"p">>, <<"50000">>])),
        run(T, [<<"SET">>, <<"p">>, <<"2">>, <<"KEEPTTL">>]),
        ?assert(run(T, [<<"TTL">>, <<"p">>]) > 0),
        run(T, [<<"SET">>, <<"p">>, <<"3">>]),
        ?assertEqual(-1, run(T, [<<"TTL">>, <<"p">>])),
        %% the sweep removes expired rows without a lookup
        run(T, [<<"SET">>, <<"gone">>, <<"1">>, <<"PX">>, <<"1">>]),
        timer:sleep(5),
        ?assertEqual(1, erdis_cmd:expire_sweep(T)),
        ?assertEqual([], ets:lookup(T, <<"gone">>))
    end).

lists_test() ->
    with_tab(fun(T) ->
        ?assertEqual(2, run(T, [<<"RPUSH">>, <<"l">>, <<"b">>, <<"c">>])),
        ?assertEqual(3, run(T, [<<"LPUSH">>, <<"l">>, <<"a">>])),
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], run(T, [<<"LRANGE">>, <<"l">>, <<"0">>, <<"-1">>])),
        ?assertEqual([<<"b">>, <<"c">>], run(T, [<<"LRANGE">>, <<"l">>, <<"1">>, <<"100">>])),
        ?assertEqual([], run(T, [<<"LRANGE">>, <<"l">>, <<"5">>, <<"6">>])),
        ?assertEqual(<<"c">>, run(T, [<<"LINDEX">>, <<"l">>, <<"-1">>])),
        ?assertEqual(null, run(T, [<<"LINDEX">>, <<"l">>, <<"9">>])),
        ?assertEqual(3, run(T, [<<"LLEN">>, <<"l">>])),
        ?assertEqual(<<"a">>, run(T, [<<"LPOP">>, <<"l">>])),
        ?assertEqual(<<"c">>, run(T, [<<"RPOP">>, <<"l">>])),
        ?assertEqual(<<"b">>, run(T, [<<"RPOP">>, <<"l">>])),
        ?assertEqual(null, run(T, [<<"RPOP">>, <<"l">>])),
        ?assertEqual(0, run(T, [<<"EXISTS">>, <<"l">>])),
        run(T, [<<"SET">>, <<"s">>, <<"x">>]),
        ?assertMatch({error, <<"WRONGTYPE", _/binary>>}, run(T, [<<"LPUSH">>, <<"s">>, <<"y">>])),
        %% LPUSH with several values pushes them in order, like Redis
        run(T, [<<"LPUSH">>, <<"m">>, <<"1">>, <<"2">>, <<"3">>]),
        ?assertEqual([<<"3">>, <<"2">>, <<"1">>], run(T, [<<"LRANGE">>, <<"m">>, <<"0">>, <<"-1">>]))
    end).

hashes_and_sets_test() ->
    with_tab(fun(T) ->
        ?assertEqual(2, run(T, [<<"HSET">>, <<"h">>, <<"name">>, <<"ana">>, <<"age">>, <<"30">>])),
        ?assertEqual(0, run(T, [<<"HSET">>, <<"h">>, <<"age">>, <<"31">>])),
        ?assertEqual(<<"31">>, run(T, [<<"HGET">>, <<"h">>, <<"age">>])),
        ?assertEqual(null, run(T, [<<"HGET">>, <<"h">>, <<"nope">>])),
        ?assertEqual([<<"age">>, <<"31">>, <<"name">>, <<"ana">>], run(T, [<<"HGETALL">>, <<"h">>])),
        ?assertEqual([<<"age">>, <<"name">>], run(T, [<<"HKEYS">>, <<"h">>])),
        ?assertEqual(2, run(T, [<<"HLEN">>, <<"h">>])),
        ?assertEqual(1, run(T, [<<"HEXISTS">>, <<"h">>, <<"name">>])),
        ?assertEqual(1, run(T, [<<"HDEL">>, <<"h">>, <<"name">>, <<"zzz">>])),
        ?assertEqual({simple, <<"hash">>}, run(T, [<<"TYPE">>, <<"h">>])),
        ?assertEqual(3, run(T, [<<"SADD">>, <<"s">>, <<"a">>, <<"b">>, <<"c">>, <<"a">>])),
        ?assertEqual(0, run(T, [<<"SADD">>, <<"s">>, <<"a">>])),
        ?assertEqual([<<"a">>, <<"b">>, <<"c">>], run(T, [<<"SMEMBERS">>, <<"s">>])),
        ?assertEqual(1, run(T, [<<"SISMEMBER">>, <<"s">>, <<"b">>])),
        ?assertEqual(0, run(T, [<<"SISMEMBER">>, <<"s">>, <<"z">>])),
        ?assertEqual(2, run(T, [<<"SREM">>, <<"s">>, <<"a">>, <<"b">>, <<"q">>])),
        ?assertEqual(1, run(T, [<<"SCARD">>, <<"s">>])),
        ?assertMatch({error, <<"WRONGTYPE", _/binary>>}, run(T, [<<"GET">>, <<"s">>]))
    end).

%% --------------------------------------------------------------- server ---
server_test_() ->
    {setup,
     fun() ->
         {ok, Port} = erdis:start(0, undefined),
         Port
     end,
     fun(_) -> erdis:stop() end,
     fun(Port) ->
         [{"basic commands over TCP", fun() -> tcp_basic(Port) end},
          {"inline protocol and pipelining", fun() -> tcp_inline(Port) end},
          {"pub/sub", fun() -> tcp_pubsub(Port) end},
          {"concurrent increments are atomic", fun() -> tcp_concurrency(Port) end},
          {"large values", fun() -> tcp_large(Port) end}]
     end}.

connect(Port) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, raw}, {active, false}]),
    S.

send(S, Cmd) -> ok = gen_tcp:send(S, resp:encode(Cmd)).

recv(S) -> recv(S, <<>>).
recv(S, Acc) ->
    case resp:decode(Acc) of
        {ok, Term, _} -> Term;
        incomplete ->
            {ok, Data} = gen_tcp:recv(S, 0, 2000),
            recv(S, <<Acc/binary, Data/binary>>)
    end.

call(S, Cmd) -> send(S, Cmd), recv(S).

tcp_basic(Port) ->
    S = connect(Port),
    ?assertEqual({simple, <<"PONG">>}, call(S, [<<"PING">>])),
    ?assertEqual({simple, <<"OK">>}, call(S, [<<"SET">>, <<"greeting">>, <<"hello world">>])),
    ?assertEqual(<<"hello world">>, call(S, [<<"GET">>, <<"greeting">>])),
    ?assertEqual(1, call(S, [<<"INCR">>, <<"counter">>])),
    ?assertEqual({error, <<"ERR unknown command 'WAT'">>}, call(S, [<<"WAT">>])),
    ?assertEqual([], call(S, [<<"COMMAND">>, <<"DOCS">>])),
    ?assertMatch(B when is_binary(B), call(S, [<<"INFO">>])),
    ?assertEqual({simple, <<"OK">>}, call(S, [<<"QUIT">>])),
    ?assertEqual({error, closed}, gen_tcp:recv(S, 0, 1000)),
    gen_tcp:close(S).

tcp_inline(Port) ->
    S = connect(Port),
    ok = gen_tcp:send(S, <<"SET inline yes\r\nGET inline\r\n">>),
    {ok, Data} = gen_tcp:recv(S, 0, 2000),
    ?assertEqual(<<"+OK\r\n$3\r\nyes\r\n">>, collect(S, Data, byte_size(<<"+OK\r\n$3\r\nyes\r\n">>))),
    %% a pipeline of 100 commands in a single packet
    Cmds = [resp:encode([<<"INCR">>, <<"pipe">>]) || _ <- lists:seq(1, 100)],
    ok = gen_tcp:send(S, Cmds),
    Expected = iolist_to_binary([resp:encode(N) || N <- lists:seq(1, 100)]),
    ?assertEqual(Expected, collect(S, <<>>, byte_size(Expected))),
    gen_tcp:close(S).

collect(_, Acc, N) when byte_size(Acc) >= N -> Acc;
collect(S, Acc, N) ->
    {ok, D} = gen_tcp:recv(S, 0, 2000),
    collect(S, <<Acc/binary, D/binary>>, N).

tcp_pubsub(Port) ->
    Sub = connect(Port),
    Pub = connect(Port),
    send(Sub, [<<"SUBSCRIBE">>, <<"news">>, <<"sport">>]),
    ?assertEqual([<<"subscribe">>, <<"news">>, 1], recv(Sub)),
    ?assertEqual([<<"subscribe">>, <<"sport">>, 2], recv(Sub)),
    ?assertEqual(1, call(Pub, [<<"PUBLISH">>, <<"news">>, <<"hello">>])),
    ?assertEqual(0, call(Pub, [<<"PUBLISH">>, <<"other">>, <<"nobody">>])),
    ?assertEqual([<<"message">>, <<"news">>, <<"hello">>], recv(Sub)),
    ?assertMatch({error, _}, call(Sub, [<<"GET">>, <<"x">>])),
    send(Sub, [<<"UNSUBSCRIBE">>, <<"news">>]),
    ?assertEqual([<<"unsubscribe">>, <<"news">>, 1], recv(Sub)),
    ?assertEqual(0, call(Pub, [<<"PUBLISH">>, <<"news">>, <<"again">>])),
    gen_tcp:close(Sub),
    timer:sleep(50),
    ?assertEqual(0, call(Pub, [<<"PUBLISH">>, <<"sport">>, <<"gone">>])),
    gen_tcp:close(Pub).

tcp_concurrency(Port) ->
    Parent = self(),
    Workers = [spawn_link(fun() ->
                   S = connect(Port),
                   [1 = length([call(S, [<<"INCR">>, <<"shared">>])]) || _ <- lists:seq(1, 50)],
                   gen_tcp:close(S),
                   Parent ! done
               end) || _ <- lists:seq(1, 20)],
    [receive done -> ok after 10000 -> exit(timeout) end || _ <- Workers],
    S = connect(Port),
    ?assertEqual(<<"1000">>, call(S, [<<"GET">>, <<"shared">>])),
    gen_tcp:close(S).

tcp_large(Port) ->
    S = connect(Port),
    Big = binary:copy(<<"x">>, 200000),
    ?assertEqual({simple, <<"OK">>}, call(S, [<<"SET">>, <<"big">>, Big])),
    ?assertEqual(Big, call(S, [<<"GET">>, <<"big">>])),
    ?assertEqual(200000, call(S, [<<"STRLEN">>, <<"big">>])),
    gen_tcp:close(S).

%% ------------------------------------------------------------ snapshots ---
snapshot_test() ->
    File = filename:join(os:getenv("TMPDIR", "/tmp"), "erdis_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".snap"),
    {ok, Port} = erdis:start(0, File),
    S = connect(Port),
    ?assertEqual({simple, <<"OK">>}, call(S, [<<"SET">>, <<"persist">>, <<"me">>])),
    ?assertEqual(2, call(S, [<<"RPUSH">>, <<"l">>, <<"1">>, <<"2">>])),
    ?assertEqual({simple, <<"OK">>}, call(S, [<<"SAVE">>])),
    gen_tcp:close(S),
    erdis:stop(),
    timer:sleep(50),
    {ok, Port2} = erdis:start(0, File),
    S2 = connect(Port2),
    ?assertEqual(<<"me">>, call(S2, [<<"GET">>, <<"persist">>])),
    ?assertEqual([<<"1">>, <<"2">>], call(S2, [<<"LRANGE">>, <<"l">>, <<"0">>, <<"-1">>])),
    gen_tcp:close(S2),
    erdis:stop(),
    file:delete(File).
