-module(floodgate_store_ffi).
-export([open/0, put_document/1, has_document/1, put_op/3, get_ops/1, put_summary/3, get_summary/1, put_obj/3, get_obj/2, create_ref/3, put_ref/3, get_ref/2, list_refs/1]).

%% Named public ETS tables persist for the VM run, surviving session-actor
%% restarts. Analogue of levee_storage ETS backend.
open() ->
  ensure(floodgate_docs, set),
  ensure(floodgate_ops, ordered_set),
  ensure(floodgate_sum, set),
  ensure(floodgate_git, set),
  ensure(floodgate_refs, ordered_set),
  nil.

ensure(T, Type) ->
  case ets:info(T) of
    undefined -> ets:new(T, [named_table, public, Type, {read_concurrency, true}]), ok;
    _ -> ok
  end.

put_document(Topic) -> ets:insert(floodgate_docs, {Topic}), nil.

has_document(Topic) -> ets:member(floodgate_docs, Topic).

put_op(Topic, Sn, Contents) -> ets:insert(floodgate_ops, {{Topic, Sn}, Contents}), nil.

get_ops(Topic) -> [{Sn, C} || {{T, Sn}, C} <- ets:tab2list(floodgate_ops), T =:= Topic].

put_summary(Topic, Handle, Sn) -> ets:insert(floodgate_sum, {Topic, Handle, Sn}), nil.

get_summary(Topic) ->
  case ets:lookup(floodgate_sum, Topic) of
    [{_, H, S}] -> {H, S};
    _ -> {<<>>, 0}
  end.

%% Content-addressed git object store, keyed by {Tenant, Sha}.
put_obj(Tenant, Sha, Data) -> ets:insert(floodgate_git, {{Tenant, Sha}, Data}), nil.

get_obj(Tenant, Sha) ->
  case ets:lookup(floodgate_git, {Tenant, Sha}) of
    [{_, Data}] -> {ok, Data};
    _ -> {error, nil}
  end.

put_ref(Tenant, Ref, Sha) -> ets:insert(floodgate_refs, {{Tenant, Ref}, Sha}), nil.

create_ref(Tenant, Ref, Sha) -> ets:insert_new(floodgate_refs, {{Tenant, Ref}, Sha}).

get_ref(Tenant, Ref) ->
  case ets:lookup(floodgate_refs, {Tenant, Ref}) of
    [{_, Sha}] -> {ok, Sha};
    _ -> {error, nil}
  end.

list_refs(Tenant) ->
  [{Ref, Sha} || {{T, Ref}, Sha} <- ets:tab2list(floodgate_refs), T =:= Tenant].
