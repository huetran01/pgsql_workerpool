-module(psql_worker).

-behaviour(gen_server).

-export([squery/2, squery/3,
		equery/3, equery/4,
		with_transaction/2, with_transaction/3]).

-export([start_link/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
				 terminate/2, code_change/3]).

-export([report_overrun/1]).

-export([statistic/1]).


-record(state, {conn::pid(),
					delay::pos_integer(),
					timer::timer:tref(),
					start_args::proplists:proplist(),
					worker_handler :: pid(),
					conn_status :: boolean(),
					parent_pid :: pid()}).


-type custom_strategy() :: fun(([atom()])-> Atom::atom()).
-type strategy() :: best_worker
								| random_worker
								| next_worker
								| available_worker
								| next_available_worker
								| {hash_worker, term()}
								| custom_strategy().


-define(INITIAL_DELAY, 15). 
-define(MAXIMUM_DELAY, 5 * 60 * 1000). % Five minutes
-define(TIMEOUT, 5 * 1000).

-define(Strategy, next_worker).


-spec start_link(atom(), proplists:proplist(), proplists:proplist()) -> {ok, pid()}|term().
start_link(PoolName, SizeArgs, WorkerArgs) ->
	WorkerSize = proplists:get_value(size, SizeArgs, 50),
    PoolOptions  = [ {overrun_warning, 10000}
                    , {overrun_handler, {?MODULE, report_overrun}}
                    , {pool_sup_shutdown, 'infinity'}
                    , {pool_sup_intensity, 10}
                    , {pool_sup_period, 10}
                    , {workers, WorkerSize}
                    , {worker, {?MODULE, [SizeArgs ++ WorkerArgs]}}],
  	wpool:start_pool(PoolName, PoolOptions).


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



init([Args]) ->
	process_flag(trap_exit, true),
	DelayInterval = proplists:get_value(start_interval, Args, ?INITIAL_DELAY),
	State = #state{start_args = Args, delay = DelayInterval * 1000},
	HandlerPid = spawn_link(fun() -> worker_init(State) end),
	HandlerPid ! {init_conn, self()},
	maybe_keep_alive(Args),	
	{ok, State#state{worker_handler = HandlerPid}}.

handle_call(_Query, _From, #state{conn_status = false} = State) ->
	lager:warning("psql_worker: disconnected",[]),
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

handle_info(reconnect, #state{worker_handler = undefined} = State) ->
	HandlerPid = spawn_link(fun() -> worker_init(State) end),
        lager:warning("psql_worker: reconnect self ~p and handlerpid ~p",[self(), HandlerPid]),
        HandlerPid ! {init_conn, self()},
        {noreply, State#state{worker_handler = HandlerPid, timer = undefined}}; 

handle_info(reconnect, #state{worker_handler = HandlerPid} = State) ->
	lager:warning("psql_worker: reconnect self ~p and handlerpid ~p",[self(), HandlerPid]),
	HandlerPid ! {init_conn, self()},
	{noreply, State#state{timer = undefined}};

handle_info({connected, Conn}, #state{start_args = Args} = State) ->
	lager:info("psql_worker: connected: ~p",[Conn]),
	DelayInterval = proplists:get_value(start_interval, Args, ?INITIAL_DELAY),
	cancel_timer(State#state.timer),
	{noreply, State#state{conn_status = true, delay= DelayInterval * 1000, timer = undefined, conn= Conn}};

handle_info({fail_init_conn, _Why}, State) ->
	lager:warning("psql_worker: fail_init_conn: ~p; reconnect after ~p",[_Why, State#state.delay]),
	Tref = erlang:send_after(State#state.delay, self(), reconnect),
	{noreply, State#state{conn_status = false, timer = Tref}};

% handle_info({fail_init_conn, _Why}, State) ->
% 	lager:info("psql_worker:  fail_init_conn: _Why: ~p",[_Why]),
% 	{stop, normal, State };

handle_info({'EXIT', Pid, Reason}, #state{worker_handler = Pid} = State) ->
    lager:error("psql_worker: worker will reconnect for ~p exited with ~p after ~p ~n", [Pid, Reason, State#state.delay]),
    Tref = erlang:send_after(State#state.delay, self(), reconnect),
    {noreply, State#state{conn_status = false, timer = Tref, worker_handler = undefined}};

handle_info({'EXIT', Pid, Reason}, State) ->
    lager:error("psql_worker: worker ~p exited with ~p~n", [Pid, Reason]),
    %% Worker process exited for some other reason; stop this process
    %% as well so that everything gets restarted by the sup
    {stop, normal, State};

handle_info(keepalive, #state{conn_status = true, worker_handler = Pid, start_args = Args} = State) ->
	Pid ! keepalive,
	maybe_keep_alive(Args),
	{noreply, State};

handle_info(keepalive, #state{start_args = Args} = State) ->
	maybe_keep_alive(Args),
	{noreply, State};

handle_info(_Msg, State) ->
	{noreply, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, #state{worker_handler = HandlerPid} =  _State) when is_pid(HandlerPid) -> 
	lager:info("psql_worker: terminate: Reason: ~p",[_Reason]),
	case is_process_alive(HandlerPid) of 
	true -> HandlerPid ! {stop, self()};
	_ -> ok 
	end,
  	ok;

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
			lager:debug(
				"~p Unable to connect to ~s at ~s with user ~s (~p) ",
				[self(), Database, Hostname, Username, Error]),
			Error
	end.

worker_init(State) ->
	process_flag(trap_exit, true),
	work_loop(State).

work_loop(State) ->
	Conn = State#state.conn,
	receive
		{init_conn, Caller} ->
			lager:debug("psql_worker: conn: parent_pid: ~p",[Caller]),
			case connect(State) of 
			{ok,  SqlConn} ->
				Caller ! {connected, SqlConn},
				work_loop(State#state{parent_pid = Caller, conn= SqlConn});
			Error ->
				lager:warning("psql_worker: die with fail_connect reason ~p; itself ~p exit",[Error, self()]),
				ok
			end;
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
		
		{'EXIT', Pid, _Reason} ->
			lager:warning("psql_worker: die with Pid: ~p; Reason: ~p; child itself ~p exit",[Pid, _Reason, self()]),
			need_shutdown(Pid, State),
			ok;
		{stop, Pid} ->
			lager:warning("psql_worker: die with Pid: ~p;  Child: ~p stop",[Pid, self()]),
			need_shutdown(Pid, State),
			ok;
		keepalive ->
			Sql = <<"SELECT 1;">>,
			Result = epgsql:squery(Conn, Sql),
			lager:debug("psql_worker: keepalive interval ~p", [Result]),
			work_loop(State); 	
		Msg ->
		 	lager:warning("psql_worker: other Signal: ~p",[Msg]),
			work_loop(State)
	end.

need_shutdown(Pid, State) ->
	Parent = State#state.parent_pid,
	Conn = State#state.conn,
	case Pid of 
	Parent -> 
		(catch epgsql:close(Conn));
	_ -> ok 
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


cancel_timer(Ref) when is_reference(Ref) ->
	erlang:cancel_timer(Ref);
cancel_timer(_) -> ok. 

maybe_keep_alive(Args) when is_list(Args) ->
	KeepAliveInterval = proplists:get_value(keepalive_interval, Args, undefined),
	start_keep_alive(KeepAliveInterval);
maybe_keep_alive(_) -> ok.


start_keep_alive(undefined) -> ok;

start_keep_alive(KeepAliveInterval) when is_integer(KeepAliveInterval) ->
	erlang:send_after(KeepAliveInterval * 1000, self(), keepalive);

start_keep_alive(_) -> ok.


