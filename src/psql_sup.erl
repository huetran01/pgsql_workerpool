-module(psql_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-export([add_pool/3]).

%% Helper macro for declaring children of supervisor
-define(CHILD(Name, I, Args, Type), {Name, {I, start_link, Args}, permanent, infinity, Type, [I]}).


%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================


init([]) -> 
    PoolSpec = case application:get_env(psql, pools) of 
    {ok, Pools} ->
        lists:map(fun ({PoolName, SizeArgs, WorkerArgs}) ->
            ?CHILD(PoolName, psql_worker, [PoolName, SizeArgs, WorkerArgs], supervisor)
        end, Pools);
    _ ->
        []
    end, 
    {ok, { {one_for_one, 10, 10}, PoolSpec} }.

add_pool(PoolName, SizeArgs, WorkerArgs) ->
    Child = ?CHILD(PoolName, psql_worker, [PoolName, SizeArgs, WorkerArgs], supervisor),
    supervisor:start_child(?MODULE, Child).