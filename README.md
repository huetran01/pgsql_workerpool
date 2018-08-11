* Erlang Postgres Database Client 

Manage a pool connections to postgres database use epgsql and worker_pool.

* Configure at rebar2 

{deps,
 [
    {psql, ".*", {git, "https://github.com/huetran01/pgsql_workerpool.git", "master"}},
 ]
}.


* Configure at sys.config

{psql, [
                {pools, [
                        {psql_pool, [
                                        {size, 10},
                                        {max_overflow, 20},
                                        {keepalive_interval, 15},
					{start_interval, 10}
                                ],
                                [
                                        {host, "127.0.0.1"},
                                        {database, "postgres_database_name"},
                                        {username, "postgres_user"},
                                        {password, "postgres_password"}
                                ]}]
                }]
}


Note :
- size:  indicates pool size connections to the database
- max_overflow : when 'size' of connections is reached, additional connections will be returned up to 'max_overflow'. The total number of simultaneous connections the pool will allow is 'size' + 'max_overflow'. 
- keepalive_interval : an interval to make a dummy SQL request to keep alive the connections to the database. The default value is undefined, so no keepalive requests are made. Specify in seconds: for example 15 means 15s.
- start_interval : if the connection to the database fails, will waits 15 seconds before retrying. You can modify this interval with this option. Specify in seconds: for example 10 means 10s.



