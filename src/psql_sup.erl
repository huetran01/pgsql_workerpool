-module(psql_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-export([add_pool/3]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

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
            WorkerSize = proplists:get_value(size, SizeArgs, 50),
            PoolOptions  = [ {overrun_warning, 10000}
                    , {overrun_handler, {psql_worker, report_overrun}}
                    , {workers, WorkerSize}
                    , {worker, {psql_worker, [SizeArgs ++ WorkerArgs]}}],
            % wpool:start_pool(PoolName, PoolOptions)
            {PoolName, {wpool, start_pool, [PoolName, PoolOptions]}, permanent, 5000, supervisor, [PoolName]}
        end, Pools);
    _ ->
        []
    end, 
    {ok, { {one_for_one, 10, 10}, PoolSpec} }.

add_pool(PoolName, SizeArgs, WorkerArgs) ->
    WorkerSize = proplists:get_value(size, SizeArgs, 10),
    PoolOptions  = [ {overrun_warning, 10000}
                , {overrun_handler, {psql_worker, report_overrun}}
                , {workers, WorkerSize}
                , {worker, {psql_worker, [SizeArgs ++ WorkerArgs]}}],
    Child = {PoolName, {wpool, start_pool, [PoolName, PoolOptions]}, permanent, 5000, supervisor, [PoolName]},
    supervisor:start_child(?MODULE, Child).
    % wpool:start_pool(PoolName, PoolOptions).