-module(pog_ffi).

-export([
    start/1,
    pool_options/1,
    checkout/1,
    query/4,
    query_extended/2,
    commit/1,
    log_rollback_failure/1,
    convert_error/1,
    null/0,
    coerce/1
]).

-include_lib("pog/include/pog_Config.hrl").
-include_lib("pg_types/include/pg_types.hrl").

start(#config{pool_name = PoolName, default_timeout = DefaultTimeout} = Config) ->
    % Unfortunately this has to be supplied via global mutable state currently.
    application:set_env(pg_types, timestamp_config, integer_system_time_microseconds),
    % Written once per pool start and only read afterwards, as a named
    % connection only knows the name of the pool, not its configuration.
    persistent_term:put({?MODULE, default_timeout, PoolName}, DefaultTimeout),
    pgo_pool:start_link(PoolName, pool_options(Config)).

default_timeout(PoolName) -> persistent_term:get({?MODULE, default_timeout, PoolName}, 5000).

pool_options(#config{host = Host, ssl = Ssl, password = Password} = Config) ->
    {SslActivated, SslOptions} = ssl_options(Host, Ssl),
    Options = #{
        host => Host,
        port => Config#config.port,
        database => Config#config.database,
        user => Config#config.user,
        ssl => SslActivated,
        ssl_options => SslOptions,
        connection_parameters => Config#config.connection_parameters,
        pool_size => Config#config.pool_size,
        queue_target => Config#config.queue_target,
        queue_interval => Config#config.queue_interval,
        idle_interval => Config#config.idle_interval,
        trace => Config#config.trace,
        decode_opts => [{return_rows_as_maps, Config#config.rows_as_map}],
        socket_options => socket_options(Config#config.ip_version)
    },
    maps:merge(Options, password_option(Password)).

%% Use correct defaults for SSL connections when SSL is enabled.
%% Peers have to be verified & cacerts are fetched directly from the system.
%%
%% `server_name_indication` should be set to the value of the host, because the
%% connection to Postgres uses a TCP connection that gets upgraded to TLS, and
%% the TLS socket is sent as is, meaning the hostname is lost when the ssl
%% module gets the socket. `server_name_indication` overrides that behaviour and
%% sends the correct hostname to the ssl module.
%%
%% `customize_hostname_check` should be set to verify the hostname the same way
%% HTTPS does, because otherwise wildcard certificates (i.e. *.example.com) are
%% not handled correctly.
ssl_options(_Host, ssl_disabled) -> {false, []};
ssl_options(_Host, ssl_unverified) -> {true, [{verify, verify_none}]};
ssl_options(Host, ssl_verified) ->
    MatchFun = public_key:pkix_verify_hostname_match_fun(https),
    {true, [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, binary_to_list(Host)},
        {customize_hostname_check, [{match_fun, MatchFun}]}
    ]}.

socket_options(ipv4) -> [];
socket_options(ipv6) -> [inet6].

password_option({some, Password}) -> #{password => Password};
password_option(none) -> #{}.

checkout(Name) when is_atom(Name) ->
    case pgo:checkout(Name, [{timeout, default_timeout(Name)}]) of
        {ok, Ref, Conn} -> {ok, {Ref, Conn}};
        {error, Error} -> {error, convert_error(Error)}
    end.

query({single_connection, Conn}, Sql, Arguments, _Timeout) ->
    convert_result(pgo:query(Sql, Arguments, #{}, Conn));
query({pool, Name}, Sql, Arguments, Timeout) ->
    Options = #{pool => Name, pool_options => [{timeout, query_timeout(Name, Timeout)}]},
    convert_result(pgo:query(Sql, Arguments, Options)).

query_timeout(_Name, {some, Timeout}) -> Timeout;
query_timeout(Name, none) -> default_timeout(Name).

query_extended(Conn, Sql) -> convert_result(pgo:query(Sql, [], #{}, Conn)).

%% PostgreSQL answers ROLLBACK to a COMMIT when the transaction has been
%% aborted by a failing query.
commit(Conn) ->
    case pgo:query(<<"commit">>, [], #{}, Conn) of
        #{command := commit} -> {ok, nil};
        #{command := rollback} -> {error, aborted_transaction_error()};
        {error, Error} -> {error, convert_error(Error)}
    end.

aborted_transaction_error() ->
    Message = <<"The transaction has been rolled back because a query failed inside it">>,
    {postgresql_error, <<"25P02">>, <<"in_failed_sql_transaction">>, Message}.

log_rollback_failure(Error) ->
    logger:warning("pog: rollback failed after a crash in a transaction: ~p", [Error]),
    nil.

convert_result(#{rows := Rows, num_rows := NumRows}) -> {ok, {NumRows, Rows}};
convert_result({error, Error}) -> {error, convert_error(Error)}.

convert_error(none_available) -> connection_unavailable;
convert_error(closed) -> query_timeout;
convert_error(query_timeout) -> query_timeout;
convert_error("connection not available because deadline reached while in queue") -> query_timeout;
convert_error({pgo_protocol, Error}) -> protocol_error(Error);
convert_error({pgsql_error, Error}) -> postgresql_error(Error);
convert_error(#{error := badarg_encoding} = Error) -> encoding_error(Error).

protocol_error({parameters, Expected, Got}) -> {unexpected_argument_count, Expected, Got}.

postgresql_error(#{message := Message, constraint := Constraint} = Error) ->
    {constraint_violated, Message, Constraint, maps:get(detail, Error, <<>>)};
postgresql_error(#{code := Code, message := Message}) ->
    {postgresql_error, Code, error_code_name(Code), Message}.

encoding_error(Error) ->
    TypeInfo = maps:get(type_info, Error),
    Got = list_to_binary(io_lib:format("~p", [maps:get(value, Error)])),
    {unexpected_argument_type, TypeInfo#type_info.name, Got}.

error_code_name(Code) ->
    case pog:error_code_name(Code) of
        {ok, Name} -> Name;
        {error, nil} -> <<"unknown">>
    end.

null() -> null.

coerce(Value) -> Value.
