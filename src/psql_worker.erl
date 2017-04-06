-module(psql_worker).

-behaviour(gen_server).

-export([squery/2, squery/3,
		equery/3, equery/4,
		with_transaction/2, with_transaction/3]).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
				 terminate/2, code_change/3]).

-export([report_overrun/1]).

-export([statistic/1]).


-record(state, {conn::pid(),
					delay::pos_integer(),
					timer::timer:tref(),
					start_args::proplists:proplist(),
					worker_handler :: pid(),
					conn_status :: boolean()}).


-type custom_strategy() :: fun(([atom()])-> Atom::atom()).
-type strategy() :: best_worker
								| random_worker
								| next_worker
								| available_worker
								| next_available_worker
								| {hash_worker, term()}
								| custom_strategy().


-define(INITIAL_DELAY, 5000). 
-define(MAXIMUM_DELAY, 5 * 60 * 1000). % Five minutes
-define(TIMEOUT, 5 * 1000).

-define(Strategy, next_worker).



squery(PoolName, Sql)  ->
	squery(PoolName, Sql, ?TIMEOUT).

squery(PoolName, Sql, Timeout) ->
	wpool:call(PoolName, {squery, Sql}, default_strategy(), Timeout).

equery(PoolName, Sql, Params) ->
	equery(PoolName, Sql, Params, ?TIMEOUT).
equery(PoolName, Sql, Params, Timeout) ->
	wpool:call(PoolName, {equery, Sql, Params}, default_strategy(), Timeout).


with_transaction(PoolName, Fun) ->
	with_transaction(PoolName, Fun, ?TIMEOUT).

with_transaction(PoolName, Fun, Timeout) ->
	wpool:call(PoolName, {transaction, Fun}, default_strategy(), Timeout).


start_link(Args) ->
	gen_server:start_link(?MODULE, Args, []).


init([Args]) ->
	State = #state{start_args = Args, delay = ?INITIAL_DELAY},
	HandlerPid = spawn_link(fun() -> worker_init(State) end),
	erlang:monitor(process, HandlerPid),
	HandlerPid ! {init_conn, self()},
	{ok, State#state{worker_handler = HandlerPid}}.

handle_call(_Query, _From, #state{conn_status = false} = State) ->
		{reply, {error, disconnected}, State};
handle_call({squery, Sql}, From, #state{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {squery, From, Sql},
	{noreply, State};
handle_call({equery, Sql, Params}, From, #state{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {equery, From, Sql, Params},
	{noreply, State};

handle_call({transaction, Fun}, From, #state{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {transaction, From, Fun},
	{noreply, State};

handle_call(_Msg, _From, State) ->
	{reply, {error, nonsupport}, State}.

handle_info(reconnect, #state{worker_handler = HandlerPid} = State) ->
	HandlerPid ! {init_conn, self()},
	{noreply, State};

handle_info({connected, _Conn}, State) ->
	catch erlang:cancel_timer(State#state.timer),
	{noreply, State#state{conn_status = true, delay=?INITIAL_DELAY, timer = undefined}};

handle_info({fail_init_conn, _Why}, State) ->
	NewDelay = calculate_delay(State#state.delay),
	Tref = erlang:send_after(State#state.delay, self(), reconnect),
	{noreply, State#state{conn_status = false, delay = NewDelay, timer = Tref}};

handle_info({'DOWN', Ref, _Type, _Object, _Info}, State) ->
	erlang:demonitor(Ref),
	HandlerPid = spawn_link(fun() -> worker_init(State) end),
	erlang:monitor(process, HandlerPid),
	{noreply, State#state{worker_handler = HandlerPid}};

handle_info(_Msg, State) ->
	{noreply, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.


terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

connect(State) ->
	Args = State#state.start_args,
	Hostname = proplists:get_value(host, Args),
	Database = proplists:get_value(database, Args),
	Username = proplists:get_value(username, Args),
	case epgsql:connect(Args) of
		{ok, Conn} ->
			{ok, Conn};
		Error ->
			lager:warning(
				"~p Unable to connect to ~s at ~s with user ~s (~p) ",
				[self(), Database, Hostname, Username, Error]),
			Error
	end.

calculate_delay(Delay) when (Delay * 2) >= ?MAXIMUM_DELAY ->
	?MAXIMUM_DELAY;
calculate_delay(Delay) ->
	Delay * 2.


worker_init(State) ->
	process_flag(trap_exit, true),
	work_loop(State).

work_loop(State) ->
	Conn = State#state.conn,
	receive
		{init_conn, Caller} ->
			NewState = case connect(State) of 
			{ok,  Conn} ->
				Caller ! {connected, Conn},
				State#state{conn=Conn};
			Error ->
				Caller ! {fail_init_conn, Error},
				State#state{conn = undefined}
			end,
			work_loop(NewState);
		
		{squery, Caller, Sql} ->
			Result = epgsql:squery(Conn, Sql),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{equery, Caller, Sql, Params} ->
			Result =  epgsql:equery(Conn, Sql, Params),
			gen_server:reply(Caller, Result),
			work_loop(State);

		{transaction, Caller, Fun} ->
			Result = epgsql:with_transaction(Conn, fun(_) -> Fun() end),
			gen_server:reply(Caller, Result),
			work_loop(State);
		
		{'EXIT', _From, _Reason} ->
			case is_pid(Conn) of 
			true -> 
				epgsql:close(Conn);
			_ ->
				ok
			end;
		_ ->
			work_loop(State)
	end.

-spec report_overrun(term()) -> ok.
report_overrun(Report) ->
  lager:error("~p", [Report]).

-spec default_strategy() -> strategy().
default_strategy() ->
	case application:get_env(worker_pool, default_strategy) of
		undefined -> ?Strategy;
		{ok, Strategy} -> Strategy
	end.

statistic(PoolName) ->
	Get = fun proplists:get_value/2,
	InitStats = wpool:stats(PoolName),
	PoolPid = Get(supervisor, InitStats),
	Options = Get(options, InitStats),
	InitWorkers = Get(workers, InitStats),
	WorkerStatus = 
	[begin
	    WorkerStats = Get(I, InitWorkers),
	    MsgQueueLen = Get(message_queue_len, WorkerStats),
	    Memory = Get(memory, WorkerStats),
	    {status, WorkerStats, MsgQueueLen, Memory}
   	end || I <- lists:seq(1, length(InitWorkers))],
   	[PoolPid, Options, WorkerStatus].
