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
%% @doc Piqi-RPC high-level interface
%%
-module(piqi_rpc).
-behaviour(gen_server).

-include("piqi_rpc.hrl").

%% API
-export([start/0, stop/0, stop_all/0]).

%% RPC service management
-export([
    add_service/1,
    remove_service/1,
    remove_all_services/0,
    get_services/0
]).

%% gen_server callbacks
-export([start_link/1]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% ======================================================================
%% Starting / stopping piqi-rpc
%% ======================================================================

% @doc start Piqi-RPC
start() ->
    ensure_started(piqi),
    ensure_started(ranch),
    ensure_started(crypto),
    ensure_started(cowboy),
    application:start(piqi_rpc).

% @doc stop Piqi-RPC
stop() ->
    application:stop(piqi_rpc).


% @doc stop Piqi-RPC and all dependencies that may have been started by start/0
stop_all() ->
    Res = stop(),
    application:stop(cowboy),
    application:stop(crypto),
    application:stop(ranch),
    application:stop(piqi),
    Res.


ensure_started(App) ->
    case application:start(App) of
        ok -> ok;
        {error, {already_started, App}} -> ok
    end.

%% ======================================================================
%% Service management API
%% ======================================================================

-spec normalize_service_def/1 :: ( piqi_rpc_service_def() ) -> piqi_rpc_service().
normalize_service_def(RpcService = {_ImplMod, _RpcMod, _UrlPath, _Options}) ->
    RpcService;
normalize_service_def(_RpcServiceDef = {ImplMod, RpcMod, UrlPath}) ->
    _RpcService = {ImplMod, RpcMod, UrlPath, _Options = []}.


-spec add_service/1 :: ( piqi_rpc_service_def() ) -> ok.
add_service(RpcServiceDef) ->
    RpcService = normalize_service_def(RpcServiceDef),
    % atomic service addition to both piqi_rpc_monitor and piqi_rpc_http
    try
        % adding Piqi-RPC service first, then adding HTTP resource binding
        ok = check_modules(RpcService),
        ok = add_service_def(RpcService),
        ok = piqi_rpc_http:configure()
    catch
        Class:Reason ->
            catch remove_service(RpcService),
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

-spec remove_service/1 :: ( piqi_rpc_service_def() ) -> ok.
remove_service(RpcServiceDef) ->
    RpcService = normalize_service_def(RpcServiceDef),
    ok = remove_service_def(RpcService),
    ok = piqi_rpc_http:configure().

-spec remove_all_services() -> ok.
remove_all_services() ->
    ok = piqi_rpc_http:cleanup(),
    remove_all_service_defs().

-spec get_services/0 :: () -> [piqi_rpc_service()].
get_services() ->
    [Def || {_Url, Def} <- get_service_defs()].

-spec get_service_defs/0 :: () -> [{url_path(), piqi_rpc_service_def()}].
get_service_defs() ->
    {ok, Defs} = get_env('rpc_services'),
    Defs.

-spec add_service_def/1 :: (piqi_rpc_service_def()) -> ok.
add_service_def(RpcService = {_, _, UrlPath, _}) ->
    Services = get_service_defs(),
    case proplists:is_defined(UrlPath, Services) of
        true -> erlang:error({url_path_already_used, UrlPath});
        _ -> ok
    end,
    set_env('rpc_services', [{UrlPath, RpcService} | Services]).

-spec remove_service_def/1 :: (piqi_rpc_service_def()) -> ok.
remove_service_def({_, _, UrlPath, _}) ->
    Services = get_service_defs(),
    set_env('rpc_services', proplists:delete(UrlPath, Services)).

-spec remove_all_service_defs() -> ok.
remove_all_service_defs() ->
    set_env('rpc_services', []).

%% ======================================================================
%% Internal helpers
%% ======================================================================

% @hidden
get_env(Key) ->
    gen_server:call(?MODULE, {get_env, Key}).

% @hidden
set_env(Key, Value) ->
    gen_server:call(?MODULE, {set_env, {Key, Value}}).

check_modules({ImplMod, RpcMod, _, _}) ->
    ok = ensure_loaded(ImplMod),
    ok = ensure_loaded(RpcMod),
    lists:foldl(
        fun(Name, Acc) ->
            case {erlang:function_exported(ImplMod, Name, 1), Acc} of
                {true, Acc} ->
                    Acc;
                {false, {error, {function_not_exported, L}}} ->
                    {error, {function_not_exported, [{ImplMod, Name} | L]}};
                {false, _} ->
                    {error, {function_not_exported, [{ImplMod, Name}]}}
            end
        end,
        ok,
        RpcMod:get_functions()
    ).

ensure_loaded(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> ok;
        E -> E
    end.


%% ======================================================================
%% gen_server callbacks
%% ======================================================================

start_link(EnvTableId) ->
    Res = gen_server:start_link({local, ?MODULE}, ?MODULE, EnvTableId, []),
    %% Make sure piqi_rpc_http is in sync with what we believe the current
    %% services are
    case Res of
        {ok, _} -> piqi_rpc_http:configure();
        _ -> ok
    end,
    Res.

init(EnvTableId) ->
    {ok, EnvTableId}.

handle_call({get_env, Key}, _From, EnvTableId) ->
    Result = case ets:lookup(EnvTableId, Key) of
        [{Key, Res}] -> Res;
        Other -> Other
    end,
    {reply, {ok, Result}, EnvTableId};

handle_call({set_env, Obj={_Key, _Val}}, _From, EnvTableId) ->
    true = ets:insert(EnvTableId, Obj),
    {reply, ok, EnvTableId};

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
