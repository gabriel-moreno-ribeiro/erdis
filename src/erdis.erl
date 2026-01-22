%% Entry points: start the store, the pub/sub registry and the TCP server.
-module(erdis).
-export([start/0, start/1, start/2, stop/0, port/0, run/1]).

-define(DEFAULT_PORT, 6379).

start() -> start(?DEFAULT_PORT).
start(Port) -> start(Port, "dump.erdis").

%% Starts everything; File may be undefined to disable snapshots. Returns {ok, Port}.
start(Port, File) ->
    {ok, _} = erdis_store:start(File),
    {ok, _} = erdis_pubsub:start(),
    case erdis_server:start(Port) of
        {ok, _, Actual} -> {ok, Actual};
        {error, Reason} -> stop(), {error, Reason}
    end.

stop() ->
    erdis_server:stop(),
    catch gen_server:stop(erdis_pubsub),
    catch erdis_store:stop(),
    ok.

port() -> erdis_server:port().

%% `erl -noshell -pa ebin -s erdis run [Port]` keeps the node alive serving requests.
run([]) -> run(["6379"]);
run([PortArg | _]) ->
    Port = list_to_integer(atom_to_list_or_string(PortArg)),
    process_flag(trap_exit, true),
    {ok, Actual} = start(Port, "dump.erdis"),
    io:format("erdis listening on port ~p (snapshot: dump.erdis)~n", [Actual]),
    receive stop -> ok end.

atom_to_list_or_string(A) when is_atom(A) -> atom_to_list(A);
atom_to_list_or_string(S) -> S.
