%% The keyspace: a gen_server owning the ETS table. Every command is executed
%% inside the server, which makes each command atomic (like Redis' single thread)
%% while connections are handled by separate processes.
-module(erdis_store).
-behaviour(gen_server).
-export([start/1, start_link/1, command/1, save/0, load/1, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SWEEP_MS, 100).

%% start/1 does not link to the caller, so stopping the store never takes the starter down.
start(File) -> gen_server:start({local, ?MODULE}, ?MODULE, File, []).
start_link(File) -> gen_server:start_link({local, ?MODULE}, ?MODULE, File, []).

%% Runs a command ([Name | Args], all binaries) and returns the reply term.
command(Cmd) -> gen_server:call(?MODULE, {command, Cmd}, infinity).

save() -> gen_server:call(?MODULE, save, infinity).

load(File) -> gen_server:call(?MODULE, {load, File}, infinity).

stop() -> gen_server:stop(?MODULE).

init(File) ->
    Tab = ets:new(erdis_data, [set, private]),
    case File =/= undefined andalso filelib:is_file(File) of
        true -> load_file(Tab, File);
        false -> ok
    end,
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{tab => Tab, file => File}}.

handle_call({command, [Name | _] = Cmd}, _From, #{tab := Tab, file := File} = State) ->
    case string:uppercase(Name) of
        S when S =:= <<"SAVE">>; S =:= <<"BGSAVE">> ->
            {reply, save_file(Tab, File), State};
        <<"INFO">> ->
            Info = io_lib:format("# Server\r\nredis_version:7.0.0\r\nerdis_version:1.0\r\n# Keyspace\r\ndb0:keys=~p\r\n", [ets:info(Tab, size)]),
            {reply, iolist_to_binary(Info), State};
        _ ->
            {reply, erdis_cmd:run(Tab, Cmd), State}
    end;
handle_call(save, _From, #{tab := Tab, file := File} = State) ->
    {reply, save_file(Tab, File), State};
handle_call({load, File}, _From, #{tab := Tab} = State) ->
    ets:delete_all_objects(Tab),
    {reply, load_file(Tab, File), State#{file => File}}.

handle_cast(_, State) -> {noreply, State}.

handle_info(sweep, #{tab := Tab} = State) ->
    erdis_cmd:expire_sweep(Tab),
    erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_, State) -> {noreply, State}.

terminate(_, _) -> ok.

%% Snapshots are the live rows serialised with term_to_binary, written atomically.
save_file(_, undefined) -> {error, <<"ERR no snapshot file configured">>};
save_file(Tab, File) ->
    erdis_cmd:expire_sweep(Tab),
    Data = term_to_binary({erdis_snapshot, 1, ets:tab2list(Tab)}, [compressed]),
    Tmp = File ++ ".tmp",
    ok = file:write_file(Tmp, Data),
    ok = file:rename(Tmp, File),
    {simple, <<"OK">>}.

load_file(Tab, File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            case binary_to_term(Bin, [safe]) of
                {erdis_snapshot, 1, Rows} -> ets:insert(Tab, Rows), {ok, length(Rows)};
                _ -> {error, bad_snapshot}
            end;
        Error -> Error
    end.
