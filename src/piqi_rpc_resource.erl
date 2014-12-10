-module(piqi_rpc_resource).

-export([init/3, handle/2, terminate/3]).

-record(rpc_state, {
    impl_mod,
    rpc_mod,
    status,
    options
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

init({tcp, http}, Req, {ImplMod, RpcMod, Options}) ->
    Status = proplists:get_value(status, Options, active),
    {ok, Req, #rpc_state{
        impl_mod = ImplMod,
        rpc_mod = RpcMod,
        options = Options,
        status = Status
    }}.

handle(Req, State = #rpc_state{status=active}) ->
    {Method, Req2} = cowboy_req:method(Req),
    handle(Method, Req2, State);
handle(Req, State = #rpc_state{status=_}) ->
    reply(503, [], <<"service unavailable">>, Req, State).

terminate(_Reason, _Req, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

handle(<<"GET">>, Req, State) ->
    case get_output_format(Req) of
        {ok, OutputFormat, Req2} ->
            case cowboy_req:qs_val(<<"body">>, Req2) of
                {undefined, Req3} -> get_piqi(Req3, State, OutputFormat);
                {true, Req3} -> rpc(Req3, State, json, OutputFormat, <<"">>);
                {Body, Req3} -> rpc(Req3, State, json, OutputFormat, Body)
            end;
        {error, {Code, Message}, Req2} ->
            reply(Code, [], Message, Req2, State)
    end;
handle(<<"POST">>, Req, State) ->
    case cowboy_req:body(infinity, Req) of
        {ok, Body, Req2} ->
            case get_input_format(byte_size(Body), Req2) of
                {ok, InputFormat, Req3} ->
                    case get_output_format(InputFormat, Req3) of
                        {ok, OutputFormat, Req4} ->
                            rpc(Req4, State, InputFormat, OutputFormat, Body);
                        {error, {Code, Message}, Req4} ->
                            reply(Code, [], Message, Req4, State)
                    end;
                {error, {Code, Message}, _} ->
                    reply(Code, [], Message, Req2, State)
            end;
        {error, _Reason} ->
            reply(400, [], <<"invalid input">>, Req, State)
    end;
handle(_Method, Req, State) ->
    reply(405, [], <<"method not allowed">>, Req, State).

get_piqi(Req, State = #rpc_state{rpc_mod = RpcMod, options = Options}, OutputFormat) ->
    case proplists:get_value('return_definition', Options, false) of
        true ->
            Body = RpcMod:get_piqi(OutputFormat, Options),
            reply(200, [format_to_content_type(OutputFormat)], Body, Req, State);
        _ ->
            reply(411, [], <<"non-empty input expected">>, Req, State)
    end.

rpc(Req, State, InputFormat, OutputFormat, <<>>) when InputFormat =/= 'pb' ->
    % Body must be undefined if empty, unless it's protobuf
    rpc(Req, State, InputFormat, OutputFormat, undefined);
rpc(Req, State = #rpc_state{rpc_mod = RpcMod, impl_mod =ImplMod, options = Options}, InputFormat, OutputFormat, Body) ->
    {Function, Req2} = cowboy_req:binding(function, Req),
    % Pass the whole request through the process dictionary
    % @TODO based on options pass it or parts as second argument to the implementation function call.
    erlang:put(cowboy_req, Req2),
    % Body is not stored in the request object.
    erlang:put(cowboy_body, Body),
    RpcResponse = RpcMod:rpc(ImplMod, Function, Body, InputFormat, OutputFormat, Options),
    Req3 = erlang:get(cowboy_req),
    case RpcResponse of
        % ok responses
        ok ->
            reply(204, [], <<>>, Req3, State);
        {ok, Output} ->
            reply(200, [format_to_content_type(OutputFormat)], Output, Req3, State);

        % application error:
        {error, ErrorData} ->
            error_response(OutputFormat, ErrorData, Req3, State);

        % input-related errors:
        {'rpc_error', 'unknown_function'} ->
            int_error_reply(404, <<"unknown function: ", Function/binary>>, Req3, State);
        {'rpc_error', 'missing_input'} ->
            int_error_reply(411, <<"non-empty input expected">>, Req3, State);
        {'rpc_error', {'invalid_input', Err}} ->
            int_error_reply(400, Err, Req3, State);

        % server errors:
        {'rpc_error', {'invalid_output', Err}} ->
            int_error_reply(411, Err, Req3, State);
        {'rpc_error', {'internal_error', Err}} ->
            int_error_reply(500, Err, Req3, State);
        {'rpc_error', {'service_unavailable', Err}} ->
            int_error_reply(503, Err, Req3, State)
    end.

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

get_input_format(InputSize, Req) ->
    {Format, Req3} = case cowboy_req:parse_header(<<"content-type">>, Req) of
        {ok, {Type, SubType, _}, Req2} ->
            {content_type_to_format(Type, SubType), Req2};
        _ ->
            {undefined, Req}
    end,
    case InputSize of
        % allow undefined only if no input body
        0 -> {ok, Format, Req3};
        _ -> valid_format(Format, Req3)
    end.

get_output_format(InputFormat, Req) ->
    {Format, Req3} = case cowboy_req:parse_header(<<"accept">>, Req) of
        {ok, undefined, Req2} ->
            {InputFormat, Req2};
        {ok, AcceptList, Req2} ->
            Formats = [content_type_to_format(Type, SubType, InputFormat) || {{Type, SubType, _}, _, _} <- AcceptList],
            case lists:member(InputFormat, Formats) of
                true -> {InputFormat, Req2};
                false -> [First | _] = Formats, {First, Req2}
            end;
        _ ->
            {undefined, Req}
    end,
    valid_format(Format, Req3).

get_output_format(Req) ->
    {Format, Req3} = case cowboy_req:parse_header(<<"accept">>, Req) of
        {ok, undefined, Req2} ->
            {undefined, Req2};
        {ok, [{{Type, SubType, _}, _, _} | _T], Req2} ->
            {content_type_to_format(Type, SubType), Req2};
        _ ->
            {undefined, Req}
    end,
    valid_format(Format, Req3).

error_response(OutputFormat, ErrorData, Req2, State) ->
    case cowboy_req:header(<<"x-piqi-rpc-return-http-status-via-header">>, Req2) of
        {<<"true">>, Req3} ->
            reply(200, [{<<"X-Piqi-RPC-http-status">>, <<"500">>}, format_to_content_type(OutputFormat)], ErrorData, Req3, State);
        _Other ->
            reply(500, [format_to_content_type(OutputFormat)], ErrorData, Req2, State)
    end.

%% Wrapper for internal error replies (such as invalid input)
int_error_reply(Code, ErrorBody, Req, State) ->
    Headers =[format_to_content_type(text)],
    Body = [<<"Piqi-RPC: ">>, ErrorBody],
    reply(Code, Headers, Body, Req, State).

reply(Code, Headers, Body, Req, State) ->
    {ok, Req2} = cowboy_req:reply(Code, Headers, Body, Req),
    {ok, Req2, State}.

content_type_to_format(Type, SubType, Default) ->
    case content_type_to_format(Type, SubType) of
        any -> Default;
        Format -> Format
    end.

content_type_to_format(<<"text">>, <<"plain">>) -> piq;
content_type_to_format(<<"application">>, <<"xml">>) -> xml;
content_type_to_format(<<"application">>, <<"json">>) -> json;
content_type_to_format(<<"application">>, <<"x-protobuf">>) -> pb;
content_type_to_format(<<"*">>, <<"*">>) -> any;
content_type_to_format(_, _) -> undefined.

format_to_content_type('pb') -> {<<"Content-Type">>, <<"application/x-protobuf">>};
format_to_content_type('json') -> {<<"Content-Type">>, <<"application/json">>};
format_to_content_type('xml') -> {<<"Content-Type">>, <<"application/xml">>};
format_to_content_type('text') -> {<<"Content-Type">>, <<"text/plain">>};
format_to_content_type('piq') -> {<<"Content-Type">>, <<"text/plain">>}.

valid_format(Format, Req) ->
    case Format of
        undefined ->
            {error, {415, <<"unsupported media-type">>}, Req};
        _ ->
            {ok, Format, Req}
    end.
