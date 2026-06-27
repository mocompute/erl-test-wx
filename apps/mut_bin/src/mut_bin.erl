%%% mut_bin: Mutable binary NIF for Erlang
%%% Copyright (C) 2026 Mo Omid
%%%
%%% This program is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program.  If not, see <https://www.gnu.org/licenses/>.
-module(mut_bin).

-export([alloc/1, dealloc/1, data/1, copy/5, to_erl/1]).
-nifs([alloc/1, dealloc/1, data/1, copy/5, to_erl/1]).
-on_load(init/0).

init() ->
    Name = filename:join(code:priv_dir(?MODULE), ?MODULE),
    erlang:load_nif(Name, 0).


-doc "Allocate an unmanaged binary. Caller must manually free the memory by calling `dealloc/1`.".
-spec alloc(integer()) -> {ok, term()} | {error, term()}.
alloc(_Size) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Deallocate an unmanaged binary created with `alloc/1`. ".
-spec dealloc(term()) -> ok.
dealloc(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Return offset (from 0x00) and size in bytes of binary resource.".
-spec data(term()) -> {Offset::integer(), Size::integer()}.
data(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).


-doc "Copy data into binary resource. Source may be an Erlang binary or a mut_bin resource.".
-spec copy(term(), integer(), term(), integer(), integer()) -> ok | {error, term()}.
copy(_Dst, _DstOffset, _Src, _SrcOffset, _Count) ->
    erlang:nif_error(nif_library_not_loaded).

-spec to_erl(term()) -> binary().
to_erl(_Ptr) ->
    erlang:nif_error(nif_library_not_loaded).
