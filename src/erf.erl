%%% Copyright 2023 Nomasystems, S.L. http://www.nomasystems.com
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
%% limitations under the License

%% @doc <code>erf</code> is a library that provides a design-first framework to build
%% RESTful APIs in Erlang.
-module(erf).

%%% INCLUDE FILES
-include_lib("kernel/include/logger.hrl").

%%% START/STOP EXPORTS
-export([
    start_link/1
]).

%%% TYPES
-type api() :: erf_parser:api().
-type conf() :: #{
    spec_path := binary(),
    spec_format => spec_format(),
    callback := module(),
    callback_args => list(),
    port => inet:port_number(),
    ssl => boolean(),
    certfile => binary(),
    keyfile => binary(),
    min_acceptors => pos_integer(),
    accept_timeout => pos_integer(),
    request_timeout => pos_integer(),
    header_timeout => pos_integer(),
    body_timeout => pos_integer(),
    max_body_size => pos_integer()
}.
-type spec_format() :: erf_parser:spec_format().

%%% TYPE EXPORTS
-export_type([
    api/0,
    conf/0
]).

%%%-----------------------------------------------------------------------------
%%% START/STOP EXPORTS
%%%-----------------------------------------------------------------------------
-spec start_link(Conf) -> Result when
    Conf :: conf(),
    Result :: {ok, Pid} | ignore | {error, Reason},
    Pid :: pid(),
    Reason :: term().
%% @doc Starts the supervision tree for an instance of the server.
start_link(Conf) ->
    SpecPath = maps:get(spec_path, Conf),
    SpecFormat = maps:get(spec_format, Conf, oas_3_0),
    case erf_parser:parse(SpecPath, SpecFormat) of
        {ok, API} ->
            Schemas = maps:to_list(maps:get(schemas, API)),
            case build_dtos(Schemas) of
                ok ->
                    case build_router(API, Conf) of
                        {ok, RouterMod} ->
                            ElliConf = build_elli_conf(RouterMod, Conf),
                            elli:start_link(ElliConf);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%%-----------------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%%-----------------------------------------------------------------------------
-spec build_dtos(Schemas) -> Result when
    Schemas :: [{erf_parser:ref(), ndto:schema()}],
    Result :: ok | {error, Reason},
    Reason :: term().
build_dtos([]) ->
    ok;
build_dtos([{Ref, Schema} | Schemas]) ->
    Name = erlang:binary_to_atom(Ref),
    DTO = ndto:generate(Name, Schema),
    case ndto:load(DTO) of
        ok ->
            build_dtos(Schemas);
        {ok, Warnings} ->
            log_warnings(Warnings, <<"dtos generation">>),
            build_dtos(Schemas);
        error ->
            {error, {dto_loading_failed, [unknown_error]}};
        {error, {Errors, Warnings}} ->
            log_warnings(Warnings, <<"dtos generation">>),
            {error, {dto_loading_failed, Errors}}
    end.

-spec build_elli_conf(RouterMod, Conf) -> ElliConf when
    RouterMod :: module(),
    Conf :: conf(),
    ElliConf :: [{atom(), term()}].
build_elli_conf(RouterMod, RawConf) ->
    lists:filter(
        fun
            ({_K, undefined}) -> false;
            ({_K, _V}) -> true
        end,
        [
            {callback, RouterMod},
            {callback_args, maps:get(callback_args, RawConf, [])},
            {port, maps:get(port, RawConf, 8080)},
            {ssl, maps:get(ssl, RawConf, false)},
            {certfile, maps:get(certfile, RawConf, undefined)},
            {keyfile, maps:get(keyfile, RawConf, undefined)},
            {min_acceptors, maps:get(min_acceptors, RawConf, undefined)},
            {accept_timeout, maps:get(accept_timeout, RawConf, undefined)},
            {request_timeout, maps:get(request_timeout, RawConf, undefined)},
            {header_timeout, maps:get(header_timeout, RawConf, undefined)},
            {body_timeout, maps:get(body_timeout, RawConf, undefined)},
            {max_body_size, maps:get(max_body_size, RawConf, undefined)}
        ]
    ).

-spec build_router(API, Conf) -> Result when
    API :: api(),
    Conf :: conf(),
    Result :: {ok, Module} | {error, Reason},
    Module :: module(),
    Reason :: term().
build_router(API, Conf) ->
    {RouterMod, Router} = erf_router:generate(API, #{callback => maps:get(callback, Conf)}),
    case erf_router:load(Router) of
        ok ->
            {ok, RouterMod};
        {ok, Warnings} ->
            log_warnings(Warnings, <<"router generation">>),
            {ok, RouterMod};
        error ->
            {error, {router_loading_failed, [unknown_error]}};
        {error, {Errors, Warnings}} ->
            log_warnings(Warnings, <<"router generation">>),
            {error, {router_loading_failed, Errors}}
    end.

-spec log_warnings(Warnings, Step) -> ok when
    Warnings :: list(),
    Step :: binary().
log_warnings(Warnings, Step) ->
    lists:foreach(
        fun(Warning) ->
            ?LOG_WARNING("[erf] Warning found during ~p: ~p~n", [Step, Warning])
        end,
        Warnings
    ).
