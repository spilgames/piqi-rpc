%% Copyright 2009, 2010, 2011, 2012, 2013 Anton Lavrik
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%%
%% @doc Piqi-RPC HTTP interface
%%
%% Currently it is implemented on top of Cowboy.
%%

-module(piqi_rpc_http).

-export([
    start_listener/0,
    stop_listener/0,
    cleanup/0
]).

-export([add_service/1, remove_service/1, configure/0]).

-define(DEFAULT_PORT, 8080).
-define(DEFAULT_NAME, piqi_rpc_server).
-define(DEFAULT_NB_ACCEPTORS, 100).
-define(DEFAULT_TRANS_OPTS, []).

-include("piqi_rpc.hrl").

start_listener() ->
    cowboy:start_http(
        get_http_env(name),
        get_http_env(nb_acceptors),
        [{port, get_http_env(port)}|get_http_env(trans_opts)],
        [{env, [{dispatch, []}]}]
    ).

stop_listener() ->
    cowboy:stop_listener(get_http_env(name)).

configure() ->
    Routes = get_cowboy_routes(),
    configure(Routes).

configure(Routes) ->
    cowboy:set_env(get_http_env(name), dispatch, Routes).

cleanup() ->
    configure([]).

get_cowboy_routes() ->
    RpcServices = piqi_rpc:get_services(),
    Routes = [ rpc_service_to_cowboy_route(X) || X <- RpcServices ],
    HealthRoutes = cowboy_health_routes(RpcServices),
    Dispatch = [
        {'_', lists:flatten(HealthRoutes ++ Routes)}
    ],
    cowboy_router:compile(Dispatch).

rpc_service_to_cowboy_route(_RpcService = {ImplMod, RpcMod, UrlPath, Options}) ->
    LAdjustedPath = case string:left(UrlPath, 1) of
        "/" -> UrlPath;
        _ -> "/" ++ UrlPath
    end,
    AdjustedPath = case string:right(LAdjustedPath, 1) of
        "/" -> LAdjustedPath;
        _ -> LAdjustedPath ++ "/"
    end,
    PathMatch = AdjustedPath ++ ":function/[...]",
    [
        {PathMatch, piqi_rpc_resource, {ImplMod, RpcMod, make_service_options(Options)}},
        {AdjustedPath, piqi_rpc_resource, {ImplMod, RpcMod, make_service_options(Options)}}
    ].

cowboy_health_routes(RpcServices) ->
    Endpoints = find_undefined_health_endpoints(RpcServices, [], []),
    [{"/" ++ E ++ "/health/", piqi_health_resource, [E]} || E <- Endpoints].


-spec add_service/1 :: ( piqi_rpc_service() ) -> ok.
add_service(_RpcService = {_ImplMod, _RpcMod, _UrlPath, _Options}) ->
    configure().

-spec remove_service/1 :: ( piqi_rpc_service() ) -> ok.
remove_service(_RpcService = {_ImplMod, _RpcMod, _UrlPath, _Options}) ->
    configure().

default_http_envs() ->
    [
        {port, ?DEFAULT_PORT},
        {name, ?DEFAULT_NAME},
        {nb_acceptors, ?DEFAULT_NB_ACCEPTORS},
        {trans_opts, ?DEFAULT_TRANS_OPTS}
    ].

% Utility
get_http_env(Key) ->
    get_http_env(
      Key,
      proplists:get_value(Key, default_http_envs())
    ).

get_http_env(Key, Default) ->
    case proplists:get_value(Key, get_env(piqi_rpc, http_server, [])) of
        undefined -> Default;
        Value -> Value
    end.

get_env(App, Key, Default) ->
    case application:get_env(App, Key) of
        undefined -> Default;
        {ok, Value} -> Value
    end.

make_service_options(Options) ->
    DefaultOpts = get_env(piqi_rpc, 'default_service_options', []),
    ReturnDefinition = get_env(piqi_rpc, 'return_definition', false),
    Options ++ [{return_definition, ReturnDefinition}] ++ DefaultOpts.

find_undefined_health_endpoints([], _Defined, Undefined) ->
    lists:usort(Undefined);

find_undefined_health_endpoints([{_ImplMod, health, UrlPath, _Options}|RpcServices], Defined, Undefined) ->
    FilteredUndefined = lists:filter(fun(E) -> E =/= UrlPath end, Undefined),
    find_undefined_health_endpoints(RpcServices, [UrlPath|Defined], FilteredUndefined);

find_undefined_health_endpoints([{_ImplMod, _RpcMod, UrlPath, _Options}|RpcServices], Defined, Undefined) ->
    case lists:member(UrlPath, Defined) of
        true ->
            find_undefined_health_endpoints(RpcServices, Defined, Undefined);
        false ->
            find_undefined_health_endpoints(RpcServices, Defined, [UrlPath|Undefined])
    end.
