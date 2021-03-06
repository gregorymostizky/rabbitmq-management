%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Plugin.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.

-module(rabbit_mgmt_format).

-export([format/2, print/2, pid/1, ip/1, ipb/1, amqp_table/1, tuple/1]).
-export([timestamp/1, timestamp_ms/1]).
-export([node_and_pid/1, protocol/1, resource/1, permissions/1, queue/1]).
-export([exchange/1, user/1, internal_user/1, binding/1, url/2]).
-export([pack_binding_props/2, unpack_binding_props/1, tokenise/1]).
-export([args_type/1, listener/1, properties/1]).

-include_lib("rabbit_common/include/rabbit.hrl").

%%--------------------------------------------------------------------

format(Stats, Fs) ->
    lists:concat([format_item(Stat, Fs) || {_Name, Value} = Stat <- Stats,
                                           Value =/= unknown]).

format_item(Stat, []) ->
    [Stat];
format_item({Name, Value}, [{Fun, Names} | Fs]) ->
    case lists:member(Name, Names) of
        true  -> case Fun(Value) of
                     List when is_list(List) -> List;
                     Formatted               -> [{Name, Formatted}]
                 end;
        false -> format_item({Name, Value}, Fs)
    end.

print(Fmt, Val) when is_list(Val) ->
    list_to_binary(lists:flatten(io_lib:format(Fmt, Val)));
print(Fmt, Val) ->
    print(Fmt, [Val]).

%% TODO - can we remove all these "unknown" cases? Coverage never hits them.

pid(Pid) when is_pid(Pid) -> list_to_binary(rabbit_misc:pid_to_string(Pid));
pid('')                   ->  <<"">>;
pid(unknown)              -> unknown;
pid(none)                 -> none.

node_and_pid(Pid) when is_pid(Pid) ->
    [{pid,  pid(Pid)},
     {node, node(Pid)}];
node_and_pid('')      -> [];
node_and_pid(unknown) -> [];
node_and_pid(none)    -> [].

ip(unknown) -> unknown;
ip(IP)      -> list_to_binary(rabbit_misc:ntoa(IP)).

ipb(unknown) -> unknown;
ipb(IP)      -> list_to_binary(rabbit_misc:ntoab(IP)).

properties(unknown) -> unknown;
properties(Table)   -> {struct, [{Name, tuple(Value)} ||
                                    {Name, Value} <- Table]}.

amqp_table(unknown) -> unknown;
amqp_table(Table)   -> {struct, [{Name, tuple(Value)} ||
                               {Name, _Type, Value} <- Table]}.

tuple(unknown)                    -> unknown;
tuple(Tuple) when is_tuple(Tuple) -> [tuple(E) || E <- tuple_to_list(Tuple)];
tuple(Term)                       -> Term.

protocol(unknown)                  -> unknown;
protocol({Major, Minor, 0})        -> print("~w-~w", [Major, Minor]);
protocol({Major, Minor, Revision}) -> print("~w-~w-~w",
                                            [Major, Minor, Revision]).

timestamp_ms(unknown) ->
    unknown;
timestamp_ms(Timestamp) ->
    timer:now_diff(Timestamp, {0,0,0}) div 1000.

timestamp(unknown) ->
    unknown;
timestamp(Timestamp) ->
    {{Y, M, D}, {H, Min, S}} = calendar:now_to_local_time(Timestamp),
    print("~w-~w-~w ~w:~w:~w", [Y, M, D, H, Min, S]).

resource(unknown) -> unknown;
resource(Res)     -> resource(name, Res).

resource(_, unknown) ->
    unknown;
resource(NameAs, #resource{name = Name, virtual_host = VHost}) ->
    [{NameAs, Name}, {vhost, VHost}].

permissions({User, VHost, Conf, Write, Read}) ->
    [{user,      User},
     {vhost,     VHost},
     {configure, Conf},
     {write,     Write},
     {read,      Read}].

internal_user(User) ->
    [{name,          User#internal_user.username},
     {password_hash, base64:encode(User#internal_user.password_hash)},
     {administrator, User#internal_user.is_admin}].

user(User) ->
    [{name,          User#user.username},
     {administrator, User#user.is_admin},
     {auth_backend,  User#user.auth_backend}].


listener(#listener{node = Node, protocol = Protocol,
                   host = Host, ip_address = IPAddress, port = Port}) ->
    [{node, Node},
     {protocol, Protocol},
     {host, list_to_binary(Host)},
     {ip_address, ip(IPAddress)},
     {port, Port}].

pack_binding_props(<<"">>, []) ->
    <<"_">>;
pack_binding_props(Key, Args) ->
    Dict = dict:from_list([{K, V} || {K, _, V} <- Args]),
    ArgsKeys = lists:sort(dict:fetch_keys(Dict)),
    PackedArgs =
        string:join(
          [quote_binding(K) ++ "_" ++
               quote_binding(dict:fetch(K, Dict)) || K <- ArgsKeys],
          "_"),
    list_to_binary(quote_binding(Key) ++
                       case PackedArgs of
                           "" -> "";
                           _  -> "_" ++ PackedArgs
                       end).

quote_binding(Name) ->
    binary_to_list(
      iolist_to_binary(
        re:replace(mochiweb_util:quote_plus(Name), "_", "%5F"))).

unpack_binding_props(B) when is_binary(B) ->
    unpack_binding_props(binary_to_list(B));
unpack_binding_props(Str) ->
    unpack_binding_props0(tokenise(Str)).

unpack_binding_props0([Key | Args]) ->
    try
        {unquote_binding(Key), unpack_binding_args(Args)}
    catch E -> E
    end;
unpack_binding_props0([]) ->
    {bad_request, empty_properties}.

unpack_binding_args([]) ->
    [];
unpack_binding_args([K]) ->
    throw({bad_request, {no_value, K}});
unpack_binding_args([K, V | Rest]) ->
    Value = unquote_binding(V),
    [{unquote_binding(K), args_type(Value), Value} | unpack_binding_args(Rest)].

unquote_binding(Name) ->
    list_to_binary(mochiweb_util:unquote(Name)).

%% Unfortunately string:tokens("foo__bar", "_"). -> ["foo","bar"], we lose
%% the fact that there's a double _.
tokenise("") ->
    [];
tokenise(Str) ->
    Count = string:cspan(Str, "_"),
    case length(Str) of
        Count -> [Str];
        _     -> [string:sub_string(Str, 1, Count) |
                  tokenise(string:sub_string(Str, Count + 2))]
    end.

args_type(X) when is_binary(X) ->
    longstr;
args_type(X) when is_number(X) ->
    long;
args_type(X) ->
    throw({unhandled_type, X}).

url(Fmt, Vals) ->
    print(Fmt, [mochiweb_util:quote_plus(V) || V <- Vals]).

exchange(X) ->
    format(X, [{fun resource/1,   [name]},
               {fun amqp_table/1, [arguments]}]).

%% We get queues using rabbit_amqqueue:list/1 rather than :info_all/1 since
%% the latter wakes up each queue. Therefore we have a record rather than a
%% proplist to deal with.
queue(#amqqueue{name            = Name,
                durable         = Durable,
                auto_delete     = AutoDelete,
                exclusive_owner = ExclusiveOwner,
                arguments       = Arguments,
                pid             = Pid }) ->
    format(
      [{name,        Name},
       {durable,     Durable},
       {auto_delete, AutoDelete},
       {owner_pid,   ExclusiveOwner},
       {arguments,   Arguments},
       {pid,         Pid}],
      [{fun pid/1,          [owner_pid]},
       {fun node_and_pid/1, [pid]},
       {fun resource/1,     [name]},
       {fun amqp_table/1,   [arguments]}]).

%% We get bindings using rabbit_binding:list_*/1 rather than :info_all/1 since
%% there are no per-exchange / queue / etc variants for the latter. Therefore
%% we have a record rather than a proplist to deal with.
binding(#binding{source      = S,
                 key         = Key,
                 destination = D,
                 args        = Args}) ->
    format(
      [{source,           S},
       {destination,      D#resource.name},
       {destination_type, D#resource.kind},
       {routing_key,      Key},
       {arguments,        Args},
       {properties_key, pack_binding_props(Key, Args)}],
      [{fun (Res) -> resource(source, Res) end, [source]},
       {fun amqp_table/1,                       [arguments]}]).
