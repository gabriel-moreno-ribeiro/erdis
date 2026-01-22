%% Publish/subscribe: channels map to subscriber processes, which are monitored
%% so a dropped connection unsubscribes itself.
-module(erdis_pubsub).
-behaviour(gen_server).
-export([start/0, start_link/0, subscribe/1, unsubscribe/1, publish/2, subscriptions/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns the caller's subscription count after the change.
subscribe(Channel) -> gen_server:call(?MODULE, {subscribe, self(), Channel}).
unsubscribe(Channel) -> gen_server:call(?MODULE, {unsubscribe, self(), Channel}).
%% Returns the number of subscribers that received the message.
publish(Channel, Message) -> gen_server:call(?MODULE, {publish, Channel, Message}).
subscriptions() -> gen_server:call(?MODULE, subscriptions).

init([]) -> {ok, #{channels => #{}, monitors => #{}}}.

handle_call({subscribe, Pid, Channel}, _From, #{channels := Ch, monitors := Mon} = S) ->
    Subs = maps:get(Channel, Ch, []),
    Ch2 = Ch#{Channel => lists:usort([Pid | Subs])},
    Mon2 = case maps:is_key(Pid, Mon) of true -> Mon; false -> Mon#{Pid => erlang:monitor(process, Pid)} end,
    {reply, count(Pid, Ch2), S#{channels => Ch2, monitors => Mon2}};
handle_call({unsubscribe, Pid, Channel}, _From, #{channels := Ch} = S) ->
    Ch2 = remove(Pid, Channel, Ch),
    {reply, count(Pid, Ch2), S#{channels => Ch2}};
handle_call({publish, Channel, Message}, _From, #{channels := Ch} = S) ->
    Subs = maps:get(Channel, Ch, []),
    [Pid ! {pubsub, Channel, Message} || Pid <- Subs],
    {reply, length(Subs), S};
handle_call(subscriptions, _From, #{channels := Ch} = S) ->
    {reply, maps:map(fun(_, Pids) -> length(Pids) end, Ch), S}.

handle_cast(_, S) -> {noreply, S}.

handle_info({'DOWN', _, process, Pid, _}, #{channels := Ch, monitors := Mon} = S) ->
    Ch2 = maps:filter(fun(_, Pids) -> Pids =/= [] end, maps:map(fun(_, Pids) -> lists:delete(Pid, Pids) end, Ch)),
    {noreply, S#{channels => Ch2, monitors => maps:remove(Pid, Mon)}};
handle_info(_, S) -> {noreply, S}.

remove(Pid, Channel, Ch) ->
    case lists:delete(Pid, maps:get(Channel, Ch, [])) of
        [] -> maps:remove(Channel, Ch);
        Pids -> Ch#{Channel => Pids}
    end.

count(Pid, Ch) -> length([C || {C, Pids} <- maps:to_list(Ch), lists:member(Pid, Pids)]).
