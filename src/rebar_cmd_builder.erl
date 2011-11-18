%% -----------------------------------------------------------------------------
%% Copyright (c) 2002-2011 Tim Watson (watson.timothy@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
-module(rebar_cmd_builder).
-export([generate_handler/3]).

-define(DEBUG(Msg, Args), ?LOG(debug, Msg, Args)).
-define(WARN(Msg, Args), ?LOG(warn, Msg, Args)).
-define(LOG(Lvl, Msg, Args), rebar_log:log(Lvl, Msg, Args)).
-define(ABORT(Msg, Args), rebar_utils:abort(Msg, Args)).

%%
%% @doc Generate '<Command>'(Config, _AppFile) handler functions for each
%% command in `Cmds' and append them to either (a) a new module or (b) the
%% origin (module) if (a) fails.
%%
generate_handler(Base, Cmds, Origin) ->
    case rebar_config:get_global({Base, Origin}, undefined) of
        undefined ->
            ?DEBUG("Generating handler(s) for ~p~n", [Base]),
            Exports = [ {C, 2} || {command, C, _, _} <- Cmds ],
            Functions = [ gen_function(Base, C, Origin) ||
                                            {command, C, _, _} <- Cmds ],

            %% Using get_object_code can lead to all kinds of situations when
            %% we're in an escript, when we're called by other code that isn't
            %% and so on. This *mixed* approach is intended to cover the edge
            %% cases I've seen thus far.
            {Forms, Loader} = case code:get_object_code(Origin) of
                {_,Bin,_} ->
                    ?DEBUG("Compiling from existing binary~n", []),
                    GeneratedForms = to_forms(atom_to_list(Origin),
                                                Exports, Functions, Bin),
                    {GeneratedForms, fun load_binary/2};
                error ->
                    File = code:which(Origin),
                    case compile:file(File, [debug_info,
                                             binary, return_errors]) of
                        {ok, _, Bin} ->
                            ?DEBUG("Compiling from binary~n", []),
                            {to_forms(atom_to_list(Origin), Exports,
                                    Functions, Bin), fun load_binary/2};
                        Error ->
                            ?WARN("Unable to recompile ~p: ~p~n",
                                  [Origin, Error]),
                            {mod_from_scratch(Base, Exports, Functions),
                                    fun evil_load_binary/2}
                    end;
                _ ->
                    ?WARN("Cannot modify ~p - generating new module~n",
                          [Origin]),
                    {mod_from_scratch(Base, Exports, Functions),
                                                        fun evil_load_binary/2}
            end,
            Loaded = case compile:forms(Forms, [report, return]) of
                {ok, ModName, Binary} ->
                    Loader(ModName, Binary);
                {ok, ModName, Binary, _Warnings} ->
                    Loader(ModName, Binary);
                CompileError ->
                    ?ABORT("Unable to compile: ~p~n", [CompileError])
            end,
            rebar_config:set_global({Base, Origin}, Loaded),
            Loaded;
        Handler ->
            Handler
    end.

mod_from_scratch(Base, Exports, Functions) ->
    [{attribute, ?LINE, module, list_to_atom(Base ++
                                             "_custom_build_plugin")},
     {attribute, ?LINE, export, Exports}] ++ Functions.

to_forms(Base, Exports, Functions, Bin) ->
    case beam_lib:chunks(Bin, [abstract_code]) of
        {ok, {_,[{abstract_code,{_,[FileDef, ModDef|Code]}}|_]}} ->
            Code2 = lists:keydelete(eof, 1, Code),
            [FileDef, ModDef] ++
            [{attribute,31,export,Exports}] ++
            Code2 ++ Functions; %%  ++ [EOF],
        _ ->
            [{attribute, ?LINE, module, list_to_atom(Base)},
             {attribute, ?LINE, export, Exports}] ++ Functions
    end.

gen_function(Base, Cmd, Origin) ->
    {function, ?LINE, Cmd, 2, [
        {clause, ?LINE,
            [{var,?LINE,'Config'},
             {var,?LINE,'File'}],
            [],
            [{call,?LINE,
                {remote,?LINE,
                    {atom,?LINE,Origin},
                    {atom,?LINE,execute_command}},
                    [erl_parse:abstract(Cmd),
                     erl_parse:abstract(Base),
                     {var,?LINE,'Config'},
                     {var,?LINE,'File'}]}]}]}.

evil_load_binary(Name, Binary) ->
    %% this is a nasty hack - perhaps adding the function to *this*
    %% module would be a better approach, but for now....
    ?DEBUG("Evil Loading: ~p~n", [Name]),
    Name = load_binary(Name, Binary),
    {ok, Existing} = application:get_env(rebar, any_dir_modules),
    application:set_env(rebar, any_dir_modules, [Name|Existing]),
    Name.

load_binary(Name, Binary) ->
    case code:load_binary(Name, "", Binary) of
        {module, Name}  ->
            ?DEBUG("Module ~p loaded~n", [Name]),
            Name;
        {error, Reason} -> ?ABORT("Unable to load binary: ~p~n", [Reason])
    end.
