%%%
%%% Generic machine
%%%
%%% TODOs
%%%
%%%  - Split ctx and time tracking into different machine layers.
%%%

-module(ff_machine).

-type id()        :: machinery:id().
-type namespace() :: machinery:namespace().
-type timestamp() :: machinery:timestamp().
-type ctx()       :: ff_ctx:ctx().

-type st(Model) :: #{
    model         := Model,
    ctx           := ctx(),
    times         => {timestamp(), timestamp()}
}.

-type timestamped_event(T) ::
    {ev, timestamp(), T}.

-type auxst() ::
    #{ctx := ctx()}.

-type machine(T) ::
    machinery:machine(timestamped_event(T), auxst()).

-type result(T) ::
    machinery:result(timestamped_event(T), auxst()).

-export_type([st/1]).
-export_type([machine/1]).
-export_type([result/1]).
-export_type([timestamped_event/1]).

%% Accessors

-export([model/1]).
-export([ctx/1]).
-export([created/1]).
-export([updated/1]).

%%

-export([get/3]).

-export([collapse/2]).

-export([emit_event/1]).
-export([emit_events/1]).

%%

-export([init/4]).
-export([process_timeout/3]).
-export([process_call/4]).

%%

-import(ff_pipeline, [do/1, unwrap/1]).

%%

-spec model(st(Model)) ->
    Model.
-spec ctx(st(_)) ->
    ctx().
-spec created(st(_)) ->
    timestamp() | undefined.
-spec updated(st(_)) ->
    timestamp() | undefined.

model(#{model := V}) ->
    V.
ctx(#{ctx := V}) ->
    V.
created(St) ->
    erlang:element(1, times(St)).
updated(St) ->
    erlang:element(2, times(St)).

times(St) ->
    genlib_map:get(times, St, {undefined, undefined}).

%%

-spec get(module(), namespace(), id()) ->
    {ok, st(_)} |
    {error, notfound}.

get(Mod, NS, ID) ->
    do(fun () ->
        collapse(Mod, unwrap(machinery:get(NS, ID, fistful:backend(NS))))
    end).

-spec collapse(module(), machine(_)) ->
    st(_).

collapse(Mod, #{history := History, aux_state := #{ctx := Ctx}}) ->
    collapse_history(Mod, History, #{ctx => Ctx}).

collapse_history(Mod, History, St0) ->
    lists:foldl(fun (Ev, St) -> merge_event(Mod, Ev, St) end, St0, History).

-spec emit_event(E) ->
    [timestamped_event(E)].

emit_event(Event) ->
    emit_events([Event]).

-spec emit_events([E]) ->
    [timestamped_event(E)].

emit_events(Events) ->
    emit_timestamped_events(Events, machinery_time:now()).

emit_timestamped_events(Events, Ts) ->
    [{ev, Ts, Body} || Body <- Events].

merge_event(Mod, {_ID, _Ts, TsEvent}, St0) ->
    {Ev, St1} = merge_timestamped_event(TsEvent, St0),
    Model1 = Mod:apply_event(Ev, maps:get(model, St1, undefined)),
    St1#{model => Model1}.

merge_timestamped_event({ev, Ts, Body}, St = #{times := {Created, _Updated}}) ->
    {Body, St#{times => {Created, Ts}}};
merge_timestamped_event({ev, Ts, Body}, St = #{}) ->
    {Body, St#{times => {Ts, Ts}}}.

%%

-spec init({machinery:args(_), ctx()}, machinery:machine(E, A), module(), _) ->
    machinery:result(E, A).

init({Args, Ctx}, _Machine, Mod, _) ->
    Events = Mod:init(Args),
    #{
        events => emit_events(Events),
        aux_state => #{ctx => Ctx}
    }.

-spec process_timeout(machinery:machine(E, A), module(), _) ->
    machinery:result(E, A).

process_timeout(Machine, Mod, _) ->
    Events = Mod:process_timeout(collapse(Mod, Machine)),
    #{
        events => emit_events(Events)
    }.

-spec process_call(machinery:args(_), machinery:machine(E, A), module(), _) ->
    {machinery:response(_), machinery:result(E, A)}.

process_call(Args, Machine, Mod, _) ->
    {Response, Events} = Mod:process_call(Args, collapse(Mod, Machine)),
    {Response, #{
        events => emit_events(Events)
    }}.