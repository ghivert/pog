-module(pog_ffi_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pog/include/pog_Config.hrl").

config() ->
    pog:default_config(pog_ffi_test).

default_pool_options_test() ->
    ?assertEqual(#{
        host => <<"127.0.0.1">>,
        port => 5432,
        database => <<"postgres">>,
        user => <<"postgres">>,
        ssl => false,
        ssl_options => [],
        connection_parameters => [],
        pool_size => 10,
        queue_target => 50,
        queue_interval => 1000,
        idle_interval => 1000,
        trace => false,
        decode_opts => [{return_rows_as_maps, false}],
        socket_options => []
    }, pog_ffi:pool_options(config())).

password_pool_options_test() ->
    Config = (config())#config{password = {some, <<"secret">>}},
    Options = pog_ffi:pool_options(Config),
    ?assertEqual(<<"secret">>, maps:get(password, Options)).

ipv6_pool_options_test() ->
    Config = (config())#config{ip_version = ipv6},
    Options = pog_ffi:pool_options(Config),
    ?assertEqual([inet6], maps:get(socket_options, Options)).

rows_as_map_pool_options_test() ->
    Config = (config())#config{rows_as_map = true},
    Options = pog_ffi:pool_options(Config),
    ?assertEqual([{return_rows_as_maps, true}], maps:get(decode_opts, Options)).

ssl_unverified_pool_options_test() ->
    Config = (config())#config{ssl = ssl_unverified},
    Options = pog_ffi:pool_options(Config),
    ?assertEqual(true, maps:get(ssl, Options)),
    ?assertEqual([{verify, verify_none}], maps:get(ssl_options, Options)).

ssl_verified_pool_options_test() ->
    Config = (config())#config{host = <<"db.test">>, ssl = ssl_verified},
    Options = pog_ffi:pool_options(Config),
    SslOptions = maps:get(ssl_options, Options),
    ?assertEqual(true, maps:get(ssl, Options)),
    ?assertEqual(verify_peer, proplists:get_value(verify, SslOptions)),
    ?assertEqual("db.test", proplists:get_value(server_name_indication, SslOptions)),
    ?assertMatch([_ | _], proplists:get_value(cacerts, SslOptions)),
    ?assertMatch([{match_fun, _}], proplists:get_value(customize_hostname_check, SslOptions)).

%% pgo returns this error when the checkout deadline expires between the pool
%% handing over a connection and the caller using it. The race is too narrow to
%% be reproduced reliably, so the conversion is tested directly.
deadline_reached_in_queue_error_test() ->
    Error = "connection not available because deadline reached while in queue",
    ?assertEqual(query_timeout, pog_ffi:convert_error(Error)).

query_timeout_error_test() ->
    ?assertEqual(query_timeout, pog_ffi:convert_error(query_timeout)).

unexpected_error_test() ->
    ?assertEqual({unexpected_error, <<"something_new">>}, pog_ffi:convert_error(something_new)).

unexpected_protocol_error_test() ->
    ?assertEqual(
        {unexpected_error, <<"{pgo_protocol,{unknown,1}}">>},
        pog_ffi:convert_error({pgo_protocol, {unknown, 1}})
    ).

unexpected_result_test() ->
    Expected = {error, {unexpected_error, <<"{throw,oops}">>}},
    ?assertEqual(Expected, pog_ffi:convert_result({throw, oops})).

count_without_number_test() ->
    ?assertEqual({ok, {1, [{1}]}}, pog_ffi:convert_result(#{rows => [{1}], num_rows => nil})),
    ?assertEqual({ok, {0, []}}, pog_ffi:convert_result(#{rows => [], num_rows => table})).

postgresql_error_position_test() ->
    Error = {pgsql_error, #{code => <<"42601">>, message => <<"m">>, position => <<"3">>}},
    ?assertMatch({postgresql_error, _, _, _, none, none, {some, 3}, none, none, none},
                 pog_ffi:convert_error(Error)).
