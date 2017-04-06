-module(psql).

%% API
-export([connect/2, equery/3, 
		equery/4, squery/2, squery/3,
	 	with_transaction/2, with_transaction/3]).

%%%===================================================================
%%% API
%%%===================================================================


connect(PoolName, Settings) ->
	PoolSize    = proplists:get_value(size, Settings, 5),
	MaxOverflow = proplists:get_value(max_overflow, Settings, 5), 
	psql_sup:add_pool(PoolName, [{size, PoolSize}, {max_overflow, MaxOverflow}], Settings).



-spec equery(PoolName :: atom(), Sql    :: epgsql:sql_query(),
						 Params :: list(epgsql:bind_param()))
						-> epgsql:reply(epgsql:equery_row()) | {error, Reason :: any()}.
equery(PoolName, Sql, Params) ->
	psql_worker:equery(PoolName, Sql, Params).

-spec equery(PoolName :: atom(),
						 Sql::epgsql:sql_query(),
						 Params   :: list(epgsql:bind_param()),
						 Timeout  :: atom() | integer())
						-> epgsql:reply(epgsql:equery_row()) | {error, Reason :: any()}.
equery(PoolName, Sql, Params, Timeout) ->
	psql_worker:equery(PoolName, Sql, Params, Timeout).



-spec squery(PoolName :: atom(), Sql :: epgsql:sql_query())
						-> epgsql:reply(epgsql:squery_row()) |
							 [epgsql:reply(epgsql:squery_row())] | {error, Reason :: any()}.
squery(PoolName, Sql) ->
	psql_worker:squery(PoolName, Sql).

-spec squery(PoolName :: atom(), Sql::epgsql:sql_query(),
						 Timeout :: atom() | integer())
						-> epgsql:reply(epgsql:squery_row()) |
							 [epgsql:reply(epgsql:squery_row())] | {error, Reason :: any()}.
squery(PoolName, Sql, Timeout) ->
	psql_worker:squery(PoolName, Sql, Timeout).


-spec with_transaction(PoolName :: atom(),
	 Function :: fun(() -> Reply))
	-> Reply | {rollback | error, any()} when Reply :: any().
with_transaction(PoolName, Fun) when is_function(Fun, 0) ->
	psql_worker:with_transaction(PoolName, Fun).

-spec with_transaction(PoolName :: atom(),
	 Function :: fun(() -> Reply),
	 Timeout  :: atom() | non_neg_integer())
	-> Reply | {rollback | error, any()} when Reply :: any().
with_transaction(PoolName, Fun, Timeout) when is_function(Fun, 0) ->
	psql_worker:with_transaction(PoolName, Fun, Timeout).