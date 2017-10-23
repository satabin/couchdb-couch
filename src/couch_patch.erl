% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_patch).

-export([from_json_array/1]).

is_int(S) ->
  case re:run(Field,"^[0-9]+$") of
    {match, _} -> true;
    _ -> false
  end.

% Generic pointer evaluation just traversing the tree structure.
% Traversal calls the continuation `K` at each step, which makes it
% possible to implement special behavior for specific operations.
eval_pointer(Obj, [], _) ->
  Obj;
eval_pointer(Obj, [Field|Rest], K) when is_map(Obj) andalso maps:is_key(Field, Obj) ->
  maps:map(
    fun (Name,Value) when Name == Field -> K(Value, Rest);
        (_,Value) -> Value
    end,
    Obj);
eval_pointer(L, [Field|Rest], K) when is_list(L) ->
  if
    is_int(Field) ->
      Idx = binary_to_integer(Field),
      if
        Idx >= 0 andalso Idx < length(L) ->
          {Before,[_ | After]} = lists:split(Idx, L),
          Before ++ [K(lists:nth(Idx + 1, Obj), Rest)] ++ After;
        true ->
          throw({bad_request, "Invalid JSON pointer"})
      end;
    true -> throw({bad_request, "Invalid JSON pointer"})
  end;
eval_pointer(_, _, _) ->
  throw({bad_request, "Invalid JSON pointer"}).

% simple traversal, that returns the pointed value
get_value(Obj, Pointer) ->
  eval_pointer(Obj, Pointer, get_value).

add(_, [], Val, _) ->
  % simply replace the root
  Val;
add(Obj, [Field], Val, Repl) when is_map(Obj) ->
  if
    not Repl orelse maps:is_key(Field, Obj) ->
      % insert the value at the given position in the object
      maps:update(Field, Val, Obj);
    true ->
      throw({bad_request, "Invalid JSON pointer"})
  end;
add(L, [<<"-">>], Val, Repl) when is_list(L) andalso not Repl ->
  % insert the value as last list element
  lists:append(L, [Val]);
add(L, [Field], Val, _) when is_list(L) andalso is_int(Field) ->
  % insert value at the given index in the list
  Idx = binary_to_integer(Field),
  if
    Idx >= 0 andalso Idx < length(L) ->
      {Before, After} = lists:split(Idx, L),
      Before ++ [Val] ++ After;
    true ->
      throw({bad_request, "Invalid JSON pointer"})
  end;
add(Obj, Pointer, Val, Repl) ->
  % use generic traversal with add as continuation
  eval_pointer(Obj, Pointer, fun(Obj, Pointer) -> add(Obj, Pointer, Val, Repl)).

remove(_, []) when is_map(Obj) ->
  % root cannot be removed
  throw({bad_request, "Invalid JSON pointer"})
remove(Obj, [Field]) when is_map(Obj) ->
  % remove the key from map
  maps:remove(Field, Obj);
remove(L, [Field]) when is_list(L) andalso is_int(Field) ->
  % remove the element at given index
  Idx = binary_to_integer(Field),
  if
    Idx >= 0 andalso Idx < length(L) ->
      {Before, [_ | After]} = lists:split(Idx, L),
      Before ++ After;
    true ->
      throw({bad_request, "Invalid JSON pointer"})
  end;
remove(Obj, Pointer) ->
  % use generic traversal with remove as continuation
  eval_pointer(Obj, Pointer, remove).

is_prefix([H1|T1], [H2|T2]) when H1 == H2 ->
  is_prefix(T1, T2);
is_prefix([], [_|_]) ->
  true;
is_prefix(_, _) ->
  false.

move(Obj, From, To, Rem) when not is_prefix(From, To) ->
  % retrieve the value to duplicate
  Val = get_value(Obj, From),
  % remove from original path if required
  Clean =
    if Rem  -> remove(Obj, From);
       true -> Obj
    end,
  % insert at new path
  add(Clean, To, Val).

test(Obj, Pointer, Expected) ->
  % retrieve the value to test
  Val = get_value(Obj, Pointer),
  if Val == Expected ->
       Obj;
     true ->
       throw({bad_request, "Non-applicable JSON patch"})
  end.

% returns the operation function that can be applied to a JSON value
parse_op(#{<""op"">=<<"add">>, <<"path">>=Path, <<"value">>=Value}) ->
  fun (Obj) -> add(Obj, Path, Value, false) end;
parse_op(#{<""op"">=<<"remove">>, <<"path">>=Path}) ->
  fun (Obj) -> remove(Obj, Path) end;
parse_op(#{<""op"">=<<"replace">>, <<"path">>=Path, <<"value">>=Value}) ->
  fun (Obj) -> add(Obj, Path, Value, true) end;
parse_op(#{<""op"">=<<"move">>, <<"path">>=Path, <<"from">>=From}) ->
  fun (Obj) -> duplicate(Obj, From, Path, true) end;
parse_op(#{<""op"">=<<"copy">>, <<"path">>=Path, <<"from">>=From}) ->
  fun (Obj) -> duplicate(Obj, From, Path, false) end;
parse_op(#{<""op"">=<<"test">>, <<"path">>=Path, <<"value">>=Value}) ->
  fun (Obj) -> test(Obj, Path, Value) end;
parse_op(_) ->
  throw({bad_request, "Invalid JSON patch"}).

from_json_array(Arr) when is_list(Arr) ->
  lists:map(parse_op, Arr);
from_json_array(_Other) ->
  throw({bad_request, "Invalid JSON patch"}).
