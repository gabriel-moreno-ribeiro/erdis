%% The command implementations. Every command runs against an ETS table of
%% {Key, Value, ExpireAt} rows and returns a reply term for resp:encode/1.
%% Values: {str, Bin} | {list, [Bin]} | {hash, #{Bin => Bin}} | {set, #{Bin => true}}
-module(erdis_cmd).
-export([run/2, now_ms/0, glob_match/2, expire_sweep/1]).

now_ms() -> erlang:system_time(millisecond).

%% ---------------------------------------------------------------- lookup ---
lookup(Tab, Key) ->
    case ets:lookup(Tab, Key) of
        [{Key, Value, Exp}] ->
            case Exp =/= infinity andalso Exp =< now_ms() of
                true -> ets:delete(Tab, Key), none;
                false -> {Value, Exp}
            end;
        [] -> none
    end.

put(Tab, Key, Value, Exp) -> ets:insert(Tab, {Key, Value, Exp}).

keep_ttl(Tab, Key) ->
    case lookup(Tab, Key) of
        {_, Exp} -> Exp;
        none -> infinity
    end.

%% Deletes every expired row; called periodically by the store.
expire_sweep(Tab) ->
    Now = now_ms(),
    ets:select_delete(Tab, [{{'_', '_', '$1'}, [{'=/=', '$1', infinity}, {'=<', '$1', Now}], [true]}]).

wrongtype() -> {error, <<"WRONGTYPE Operation against a key holding the wrong kind of value">>}.
syntax() -> {error, <<"ERR syntax error">>}.
not_int() -> {error, <<"ERR value is not an integer or out of range">>}.
arity(Name) -> {error, <<"ERR wrong number of arguments for '", Name/binary, "' command">>}.

to_int(Bin) ->
    try {ok, binary_to_integer(Bin)} catch error:badarg -> error end.

%% ---------------------------------------------------------------- dispatch ---
-spec run(ets:tab(), [binary()]) -> term().
run(Tab, [Name | Args]) ->
    Cmd = string:uppercase(Name),
    try command(Cmd, Args, Tab)
    catch throw:Reply -> Reply
    end;
run(_, []) -> {error, <<"ERR empty command">>}.

command(<<"PING">>, [], _) -> {simple, <<"PONG">>};
command(<<"PING">>, [Msg], _) -> Msg;
command(<<"ECHO">>, [Msg], _) -> Msg;
command(<<"SELECT">>, [_], _) -> {simple, <<"OK">>};
command(<<"COMMAND">>, _, _) -> [];
command(<<"DBSIZE">>, [], Tab) -> expire_sweep(Tab), ets:info(Tab, size);
command(<<"FLUSHDB">>, _, Tab) -> ets:delete_all_objects(Tab), {simple, <<"OK">>};
command(<<"FLUSHALL">>, _, Tab) -> ets:delete_all_objects(Tab), {simple, <<"OK">>};

%% ---- strings ----
command(<<"SET">>, [Key, Value | Opts], Tab) ->
    case set_options(Opts, #{exp => infinity, mode => any}) of
        {ok, #{exp := Exp0, mode := Mode}} ->
            Exists = lookup(Tab, Key) =/= none,
            Exp = case Exp0 of keepttl -> keep_ttl(Tab, Key); _ -> Exp0 end,
            case {Mode, Exists} of
                {nx, true} -> null;
                {xx, false} -> null;
                _ -> put(Tab, Key, {str, Value}, Exp), {simple, <<"OK">>}
            end;
        error -> syntax()
    end;
command(<<"GET">>, [Key], Tab) ->
    case lookup(Tab, Key) of
        none -> null;
        {{str, V}, _} -> V;
        _ -> wrongtype()
    end;
command(<<"GETSET">>, [Key, Value], Tab) ->
    Old = command(<<"GET">>, [Key], Tab),
    case Old of
        {error, _} -> Old;
        _ -> put(Tab, Key, {str, Value}, infinity), Old
    end;
command(<<"MGET">>, Keys, Tab) when Keys =/= [] ->
    [case lookup(Tab, K) of {{str, V}, _} -> V; _ -> null end || K <- Keys];
command(<<"MSET">>, KVs, Tab) when KVs =/= [], length(KVs) rem 2 =:= 0 ->
    mset(KVs, Tab), {simple, <<"OK">>};
command(<<"APPEND">>, [Key, Value], Tab) ->
    case lookup(Tab, Key) of
        none -> put(Tab, Key, {str, Value}, infinity), byte_size(Value);
        {{str, V}, Exp} -> New = <<V/binary, Value/binary>>, put(Tab, Key, {str, New}, Exp), byte_size(New);
        _ -> wrongtype()
    end;
command(<<"STRLEN">>, [Key], Tab) ->
    case lookup(Tab, Key) of
        none -> 0;
        {{str, V}, _} -> byte_size(V);
        _ -> wrongtype()
    end;
command(<<"INCR">>, [Key], Tab) -> incr(Tab, Key, 1);
command(<<"DECR">>, [Key], Tab) -> incr(Tab, Key, -1);
command(<<"INCRBY">>, [Key, N], Tab) ->
    case to_int(N) of {ok, I} -> incr(Tab, Key, I); error -> not_int() end;
command(<<"DECRBY">>, [Key, N], Tab) ->
    case to_int(N) of {ok, I} -> incr(Tab, Key, -I); error -> not_int() end;

%% ---- keys ----
command(<<"DEL">>, Keys, Tab) when Keys =/= [] ->
    length([K || K <- Keys, lookup(Tab, K) =/= none, ets:delete(Tab, K)]);
command(<<"EXISTS">>, Keys, Tab) when Keys =/= [] ->
    length([K || K <- Keys, lookup(Tab, K) =/= none]);
command(<<"TYPE">>, [Key], Tab) ->
    {simple, case lookup(Tab, Key) of
        none -> <<"none">>;
        {{str, _}, _} -> <<"string">>;
        {{list, _}, _} -> <<"list">>;
        {{hash, _}, _} -> <<"hash">>;
        {{set, _}, _} -> <<"set">>
    end};
command(<<"KEYS">>, [Pattern], Tab) ->
    expire_sweep(Tab),
    [K || {K, _, _} <- ets:tab2list(Tab), glob_match(Pattern, K)];
command(<<"RENAME">>, [Old, New], Tab) ->
    case lookup(Tab, Old) of
        none -> {error, <<"ERR no such key">>};
        {V, Exp} -> ets:delete(Tab, Old), put(Tab, New, V, Exp), {simple, <<"OK">>}
    end;
command(<<"EXPIRE">>, [Key, Secs], Tab) -> set_expire(Tab, Key, Secs, 1000);
command(<<"PEXPIRE">>, [Key, Ms], Tab) -> set_expire(Tab, Key, Ms, 1);
command(<<"TTL">>, [Key], Tab) -> ttl(Tab, Key, 1000);
command(<<"PTTL">>, [Key], Tab) -> ttl(Tab, Key, 1);
command(<<"PERSIST">>, [Key], Tab) ->
    case lookup(Tab, Key) of
        {V, Exp} when Exp =/= infinity -> put(Tab, Key, V, infinity), 1;
        _ -> 0
    end;

%% ---- lists ----
command(<<"LPUSH">>, [Key | Values], Tab) when Values =/= [] ->
    with_list(Tab, Key, fun(L) -> New = lists:reverse(Values) ++ L, {length(New), New} end);
command(<<"RPUSH">>, [Key | Values], Tab) when Values =/= [] ->
    with_list(Tab, Key, fun(L) -> New = L ++ Values, {length(New), New} end);
command(<<"LPOP">>, [Key], Tab) ->
    with_list(Tab, Key, fun([]) -> {null, []}; ([H | T]) -> {H, T} end);
command(<<"RPOP">>, [Key], Tab) ->
    with_list(Tab, Key, fun([]) -> {null, []}; (L) -> {lists:last(L), lists:droplast(L)} end);
command(<<"LLEN">>, [Key], Tab) ->
    case lookup(Tab, Key) of none -> 0; {{list, L}, _} -> length(L); _ -> wrongtype() end;
command(<<"LINDEX">>, [Key, I], Tab) ->
    case {lookup(Tab, Key), to_int(I)} of
        {none, _} -> null;
        {{{list, L}, _}, {ok, Idx}} ->
            N = length(L),
            Pos = if Idx < 0 -> N + Idx; true -> Idx end,
            if Pos < 0; Pos >= N -> null; true -> lists:nth(Pos + 1, L) end;
        {{{list, _}, _}, error} -> not_int();
        _ -> wrongtype()
    end;
command(<<"LRANGE">>, [Key, Start, Stop], Tab) ->
    case {lookup(Tab, Key), to_int(Start), to_int(Stop)} of
        {none, _, _} -> [];
        {{{list, L}, _}, {ok, S}, {ok, E}} -> lrange(L, S, E);
        {{{list, _}, _}, _, _} -> not_int();
        _ -> wrongtype()
    end;

%% ---- hashes ----
command(<<"HSET">>, [Key | FVs], Tab) when FVs =/= [], length(FVs) rem 2 =:= 0 ->
    with_hash(Tab, Key, fun(H) ->
        Pairs = pairs(FVs),
        Added = length(lists:usort([F || {F, _} <- Pairs, not maps:is_key(F, H)])),
        {Added, maps:merge(H, maps:from_list(Pairs))}
    end);
command(<<"HGET">>, [Key, Field], Tab) ->
    case lookup(Tab, Key) of none -> null; {{hash, H}, _} -> maps:get(Field, H, null); _ -> wrongtype() end;
command(<<"HDEL">>, [Key | Fields], Tab) when Fields =/= [] ->
    with_hash(Tab, Key, fun(H) -> Removed = length([F || F <- Fields, maps:is_key(F, H)]), {Removed, maps:without(Fields, H)} end);
command(<<"HGETALL">>, [Key], Tab) ->
    case lookup(Tab, Key) of
        none -> [];
        {{hash, H}, _} -> lists:append([[F, V] || {F, V} <- lists:sort(maps:to_list(H))]);
        _ -> wrongtype()
    end;
command(<<"HKEYS">>, [Key], Tab) ->
    case lookup(Tab, Key) of none -> []; {{hash, H}, _} -> lists:sort(maps:keys(H)); _ -> wrongtype() end;
command(<<"HLEN">>, [Key], Tab) ->
    case lookup(Tab, Key) of none -> 0; {{hash, H}, _} -> maps:size(H); _ -> wrongtype() end;
command(<<"HEXISTS">>, [Key, Field], Tab) ->
    case lookup(Tab, Key) of none -> 0; {{hash, H}, _} -> bool(maps:is_key(Field, H)); _ -> wrongtype() end;

%% ---- sets ----
command(<<"SADD">>, [Key | Members], Tab) when Members =/= [] ->
    with_set(Tab, Key, fun(S) -> Added = length(lists:usort([M || M <- Members, not maps:is_key(M, S)])), {Added, maps:merge(S, maps:from_keys(Members, true))} end);
command(<<"SREM">>, [Key | Members], Tab) when Members =/= [] ->
    with_set(Tab, Key, fun(S) -> Removed = length([M || M <- Members, maps:is_key(M, S)]), {Removed, maps:without(Members, S)} end);
command(<<"SMEMBERS">>, [Key], Tab) ->
    case lookup(Tab, Key) of none -> []; {{set, S}, _} -> lists:sort(maps:keys(S)); _ -> wrongtype() end;
command(<<"SISMEMBER">>, [Key, M], Tab) ->
    case lookup(Tab, Key) of none -> 0; {{set, S}, _} -> bool(maps:is_key(M, S)); _ -> wrongtype() end;
command(<<"SCARD">>, [Key], Tab) ->
    case lookup(Tab, Key) of none -> 0; {{set, S}, _} -> maps:size(S); _ -> wrongtype() end;

command(Name, _, _) ->
    case lists:member(Name, [<<"PING">>, <<"ECHO">>, <<"SET">>, <<"GET">>, <<"GETSET">>, <<"MGET">>, <<"MSET">>, <<"APPEND">>,
                             <<"STRLEN">>, <<"INCR">>, <<"DECR">>, <<"INCRBY">>, <<"DECRBY">>, <<"DEL">>, <<"EXISTS">>,
                             <<"TYPE">>, <<"KEYS">>, <<"RENAME">>, <<"EXPIRE">>, <<"PEXPIRE">>, <<"TTL">>, <<"PTTL">>,
                             <<"PERSIST">>, <<"LPUSH">>, <<"RPUSH">>, <<"LPOP">>, <<"RPOP">>, <<"LLEN">>, <<"LINDEX">>,
                             <<"LRANGE">>, <<"HSET">>, <<"HGET">>, <<"HDEL">>, <<"HGETALL">>, <<"HKEYS">>, <<"HLEN">>,
                             <<"HEXISTS">>, <<"SADD">>, <<"SREM">>, <<"SMEMBERS">>, <<"SISMEMBER">>, <<"SCARD">>,
                             <<"DBSIZE">>, <<"SELECT">>]) of
        true -> arity(string:lowercase(Name));
        false -> {error, <<"ERR unknown command '", Name/binary, "'">>}
    end.

%% ---------------------------------------------------------------- helpers ---
bool(true) -> 1;
bool(false) -> 0.

pairs([]) -> [];
pairs([A, B | Rest]) -> [{A, B} | pairs(Rest)].

mset([], _) -> ok;
mset([K, V | Rest], Tab) -> put(Tab, K, {str, V}, infinity), mset(Rest, Tab).

set_options([], Acc) -> {ok, Acc};
set_options([Opt | Rest], Acc) ->
    case {string:uppercase(Opt), Rest} of
        {<<"NX">>, _} -> set_options(Rest, Acc#{mode => nx});
        {<<"XX">>, _} -> set_options(Rest, Acc#{mode => xx});
        {<<"KEEPTTL">>, _} -> set_options(Rest, Acc#{exp => keepttl});
        {<<"EX">>, [N | R]} -> expire_opt(N, 1000, R, Acc);
        {<<"PX">>, [N | R]} -> expire_opt(N, 1, R, Acc);
        _ -> error
    end.

expire_opt(N, Unit, Rest, Acc) ->
    case to_int(N) of
        {ok, I} when I > 0 -> set_options(Rest, Acc#{exp => now_ms() + I * Unit});
        _ -> error
    end.

incr(Tab, Key, Delta) ->
    case lookup(Tab, Key) of
        none -> put(Tab, Key, {str, integer_to_binary(Delta)}, infinity), Delta;
        {{str, V}, Exp} ->
            case to_int(V) of
                {ok, I} -> put(Tab, Key, {str, integer_to_binary(I + Delta)}, Exp), I + Delta;
                error -> not_int()
            end;
        _ -> wrongtype()
    end.

set_expire(Tab, Key, Amount, Unit) ->
    case {lookup(Tab, Key), to_int(Amount)} of
        {none, _} -> 0;
        {{V, _}, {ok, N}} -> put(Tab, Key, V, now_ms() + N * Unit), 1;
        {_, error} -> not_int()
    end.

ttl(Tab, Key, Unit) ->
    case lookup(Tab, Key) of
        none -> -2;
        {_, infinity} -> -1;
        {_, Exp} -> max(0, (Exp - now_ms()) div Unit)
    end.

with_list(Tab, Key, Fun) ->
    case lookup(Tab, Key) of
        none -> apply_list(Tab, Key, [], infinity, Fun);
        {{list, L}, Exp} -> apply_list(Tab, Key, L, Exp, Fun);
        _ -> wrongtype()
    end.

apply_list(Tab, Key, L, Exp, Fun) ->
    {Reply, New} = Fun(L),
    case New of
        [] -> ets:delete(Tab, Key);
        _ -> put(Tab, Key, {list, New}, Exp)
    end,
    Reply.

with_hash(Tab, Key, Fun) -> with_map(Tab, Key, hash, Fun).
with_set(Tab, Key, Fun) -> with_map(Tab, Key, set, Fun).

with_map(Tab, Key, Kind, Fun) ->
    case lookup(Tab, Key) of
        none -> apply_map(Tab, Key, Kind, #{}, infinity, Fun);
        {{Kind, M}, Exp} -> apply_map(Tab, Key, Kind, M, Exp, Fun);
        _ -> wrongtype()
    end.

apply_map(Tab, Key, Kind, M, Exp, Fun) ->
    {Reply, New} = Fun(M),
    case maps:size(New) of
        0 -> ets:delete(Tab, Key);
        _ -> put(Tab, Key, {Kind, New}, Exp)
    end,
    Reply.

%% Redis-style ranges: negative indexes count from the end, bounds are clamped.
lrange(L, S0, E0) ->
    N = length(L),
    S = max(0, if S0 < 0 -> N + S0; true -> S0 end),
    E = min(N - 1, if E0 < 0 -> N + E0; true -> E0 end),
    if S > E; S >= N -> [];
       true -> lists:sublist(L, S + 1, E - S + 1)
    end.

%% Glob matching with *, ? and [...] character classes.
glob_match(Pattern, Key) ->
    Regex = ["^", glob_to_regex(binary_to_list(Pattern)), "$"],
    case re:run(Key, iolist_to_binary(Regex)) of
        {match, _} -> true;
        nomatch -> false
    end.

glob_to_regex([]) -> [];
glob_to_regex([$* | R]) -> [".*" | glob_to_regex(R)];
glob_to_regex([$? | R]) -> ["." | glob_to_regex(R)];
glob_to_regex([$[ | R]) ->
    {Class, Rest} = lists:splitwith(fun(C) -> C =/= $] end, R),
    Rest2 = case Rest of [$] | T] -> T; [] -> [] end,
    ["[", [escape_class(C) || C <- Class], "]" | glob_to_regex(Rest2)];
glob_to_regex([$\\, C | R]) -> [escape(C) | glob_to_regex(R)];
glob_to_regex([C | R]) -> [escape(C) | glob_to_regex(R)].

escape(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9; C =:= $_; C =:= $: -> [C];
escape(C) -> [$\\, C].

escape_class($\\) -> "\\\\";
escape_class($]) -> "\\]";
escape_class(C) -> [C].
