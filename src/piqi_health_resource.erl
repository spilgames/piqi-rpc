-module(piqi_health_resource).

-export([init/3, handle/2, terminate/3]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

init({tcp, http}, Req, State) ->
    {ok, Req, State}.

handle(Req, State) ->
    reply(200, [], <<"{\"status\": \"ok\"}">>, Req, State).

terminate(_Reason, _Req, _State) ->
    ok.

reply(Code, Headers, Body, Req, State) ->
    {ok, Req2} = cowboy_req:reply(Code, Headers, Body, Req),
    {ok, Req2, State}.
