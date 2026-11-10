-module(ugwo_ffi).
-export([run_zig_kernel/4, read_static_file/1, get_env_or/2]).

run_zig_kernel(BinPath, DbPath, Cmd, Arg) ->
    BinList = unicode:characters_to_list(BinPath),
    Args = [DbPath, Cmd, Arg],
    Port = erlang:open_port(
        {spawn_executable, BinList},
        [binary, exit_status, use_stdio, hide, {args, Args}]
    ),
    collect_port_output(Port, <<>>).

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Chunk}} ->
            collect_port_output(Port, <<Acc/binary, Chunk/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _Code}} ->
            {error, <<"zig_kernel_nonzero_exit">>}
    after 8000 ->
        catch erlang:port_close(Port),
        {error, <<"zig_kernel_timeout">>}
    end.

read_static_file(FilePath) ->
    case file:read_file(FilePath) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

get_env_or(NameBin, DefaultBin) ->
    NameList = unicode:characters_to_list(NameBin),
    case os:getenv(NameList) of
        false -> DefaultBin;
        "" -> DefaultBin;
        ValList -> unicode:characters_to_binary(ValList)
    end.
