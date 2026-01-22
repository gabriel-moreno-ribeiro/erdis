%% TCP front end: an acceptor process and one process per client connection.
%% Each connection buffers bytes, decodes RESP frames (pipelining works
%% naturally) and answers; SUBSCRIBE switches it into push mode.
-module(erdis_server).
-export([start/1, stop/0, port/0, connection/1]).

%% Starts the acceptor (not linked to the caller) and waits until it listens.
start(Port) ->
    Parent = self(),
    Pid = spawn(fun() -> acceptor(Port, Parent) end),
    receive
        {listening, Pid, ActualPort} -> register(?MODULE, Pid), {ok, Pid, ActualPort};
        {listen_error, Pid, Reason} -> {error, Reason}
    after 5000 -> exit(Pid, kill), {error, timeout}
    end.

%% Killing the acceptor closes the listening socket it owns.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> exit(Pid, kill), ok
    end.

port() -> ?MODULE ! {port, self()}, receive {port_reply, P} -> P after 1000 -> undefined end.

acceptor(Port, Parent) ->
    case gen_tcp:listen(Port, [binary, {packet, raw}, {active, false}, {reuseaddr, true}, {backlog, 128}, {nodelay, true}]) of
        {ok, Listen} ->
            {ok, Actual} = inet:port(Listen),
            Parent ! {listening, self(), Actual},
            accept_loop(Listen, Actual);
        {error, Reason} ->
            Parent ! {listen_error, self(), Reason}
    end.

accept_loop(Listen, Port) ->
    receive
        {port, From} -> From ! {port_reply, Port}
    after 0 -> ok
    end,
    case gen_tcp:accept(Listen, 200) of
        {ok, Sock} ->
            Pid = spawn(?MODULE, connection, [Sock]),
            gen_tcp:controlling_process(Sock, Pid),
            Pid ! go,
            accept_loop(Listen, Port);
        {error, timeout} -> accept_loop(Listen, Port);
        {error, closed} -> ok;
        {error, _} -> accept_loop(Listen, Port)
    end.

connection(Sock) ->
    receive go -> ok end,
    inet:setopts(Sock, [{active, once}]),
    loop(Sock, <<>>, normal).

loop(Sock, Buffer, Mode) ->
    receive
        {tcp, Sock, Data} ->
            case handle_buffer(Sock, <<Buffer/binary, Data/binary>>, Mode) of
                {ok, Rest, NewMode} ->
                    inet:setopts(Sock, [{active, once}]),
                    loop(Sock, Rest, NewMode);
                close ->
                    gen_tcp:close(Sock)
            end;
        {tcp_closed, Sock} -> ok;
        {tcp_error, Sock, _} -> ok;
        {pubsub, Channel, Message} ->
            gen_tcp:send(Sock, resp:encode([<<"message">>, Channel, Message])),
            loop(Sock, Buffer, Mode)
    end.

handle_buffer(Sock, Buffer, Mode) ->
    case resp:decode(Buffer) of
        {ok, Cmd, Rest} when is_list(Cmd), Cmd =/= [] ->
            case handle(Sock, Cmd, Mode) of
                {reply, Reply, NewMode} ->
                    gen_tcp:send(Sock, resp:encode(Reply)),
                    handle_buffer(Sock, Rest, NewMode);
                {noreply, NewMode} ->
                    handle_buffer(Sock, Rest, NewMode);
                close ->
                    close
            end;
        {ok, _, Rest} ->
            handle_buffer(Sock, Rest, Mode);
        incomplete ->
            {ok, Buffer, Mode};
        {error, _} ->
            gen_tcp:send(Sock, resp:encode({error, <<"ERR Protocol error">>})),
            close
    end.

handle(_Sock, [Name | Args], Mode) ->
    case {string:uppercase(Name), Args, Mode} of
        {<<"QUIT">>, _, _} ->
            gen_tcp:send(_Sock, resp:encode({simple, <<"OK">>})),
            close;
        {<<"SUBSCRIBE">>, Channels, _} when Channels =/= [] ->
            [gen_tcp:send(_Sock, resp:encode([<<"subscribe">>, C, erdis_pubsub:subscribe(C)])) || C <- Channels],
            {noreply, subscribed};
        {<<"UNSUBSCRIBE">>, Channels, _} ->
            Counts = [{C, erdis_pubsub:unsubscribe(C)} || C <- Channels],
            [gen_tcp:send(_Sock, resp:encode([<<"unsubscribe">>, C, N])) || {C, N} <- Counts],
            NewMode = case Counts of [] -> normal; _ -> case lists:last([N || {_, N} <- Counts]) of 0 -> normal; _ -> subscribed end end,
            {noreply, NewMode};
        {<<"PUBLISH">>, [Channel, Message], _} ->
            {reply, erdis_pubsub:publish(Channel, Message), Mode};
        {<<"PING">>, _, subscribed} ->
            {reply, [<<"pong">>, <<>>], Mode};
        {_, _, subscribed} ->
            {reply, {error, <<"ERR only SUBSCRIBE / UNSUBSCRIBE / PING / QUIT are allowed in this context">>}, Mode};
        _ ->
            {reply, erdis_store:command([Name | Args]), Mode}
    end.
