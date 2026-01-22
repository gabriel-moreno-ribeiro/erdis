%% RESP2 (REdis Serialization Protocol) encoding and incremental decoding.
-module(resp).
-export([encode/1, decode/1]).

%% Reply terms:
%%   {simple, Bin}  -> +Bin        {error, Bin} -> -Bin
%%   Integer        -> :N          null         -> $-1
%%   Bin            -> $len\r\nBin  List         -> *len ...
-spec encode(term()) -> iodata().
encode({simple, S}) -> [$+, S, "\r\n"];
encode({error, E}) -> [$-, E, "\r\n"];
encode(null) -> <<"$-1\r\n">>;
encode(I) when is_integer(I) -> [$:, integer_to_binary(I), "\r\n"];
encode(B) when is_binary(B) -> [$$, integer_to_binary(byte_size(B)), "\r\n", B, "\r\n"];
encode(L) when is_list(L) -> [$*, integer_to_binary(length(L)), "\r\n" | [encode(X) || X <- L]].

%% Decodes one frame from the front of a buffer. Commands arrive as arrays of
%% bulk strings; a bare line (the inline protocol used by telnet) is split on
%% spaces into an array as well.
-spec decode(binary()) -> {ok, term(), binary()} | incomplete | {error, term()}.
decode(<<>>) -> incomplete;
decode(<<$*, Rest/binary>>) ->
    case line(Rest) of
        {ok, N, R} -> array(binary_to_integer(N), R, []);
        incomplete -> incomplete
    end;
decode(<<$$, Rest/binary>>) ->
    case line(Rest) of
        {ok, N, R} -> bulk(binary_to_integer(N), R);
        incomplete -> incomplete
    end;
decode(<<$+, Rest/binary>>) ->
    case line(Rest) of
        {ok, S, R} -> {ok, {simple, S}, R};
        incomplete -> incomplete
    end;
decode(<<$-, Rest/binary>>) ->
    case line(Rest) of
        {ok, S, R} -> {ok, {error, S}, R};
        incomplete -> incomplete
    end;
decode(<<$:, Rest/binary>>) ->
    case line(Rest) of
        {ok, S, R} -> {ok, binary_to_integer(S), R};
        incomplete -> incomplete
    end;
decode(Bin) ->
    case line(Bin) of
        {ok, Line, R} ->
            Words = [W || W <- binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all]), W =/= <<>>],
            {ok, Words, R};
        incomplete -> incomplete
    end.

line(Bin) ->
    case binary:match(Bin, <<"\r\n">>) of
        {Pos, 2} ->
            <<L:Pos/binary, "\r\n", R/binary>> = Bin,
            {ok, L, R};
        nomatch -> incomplete
    end.

bulk(-1, Rest) -> {ok, null, Rest};
bulk(N, Rest) when byte_size(Rest) >= N + 2 ->
    <<Data:N/binary, "\r\n", R/binary>> = Rest,
    {ok, Data, R};
bulk(_, _) -> incomplete.

array(-1, Rest, _) -> {ok, null, Rest};
array(0, Rest, Acc) -> {ok, lists:reverse(Acc), Rest};
array(N, Rest, Acc) ->
    case decode(Rest) of
        {ok, Item, R} -> array(N - 1, R, [Item | Acc]);
        Other -> Other
    end.
