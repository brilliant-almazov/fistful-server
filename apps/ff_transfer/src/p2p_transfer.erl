%%%
%%% P2PTransfer
%%%

-module(p2p_transfer).

-include_lib("damsel/include/dmsl_payment_processing_thrift.hrl").

-type id() :: binary().
% -type clock() :: ff_transaction:clock().

-define(ACTUAL_FORMAT_VERSION, 1).
-opaque p2p_transfer() :: #{
    version := ?ACTUAL_FORMAT_VERSION,
    id := id(),
    transfer_type := p2p_transfer,
    body := body(),
    identity_id := identity_id(),
    sender_resource := resource_full(),
    receiver_resource := resource_full(),
    created_at := ff_time:timestamp_ms(),
    party_revision := party_revision(),
    domain_revision := domain_revision(),
    exchange => exchange(),
    session => session(),
    route => route(),
    risk_score => risk_score(),
    p_transfer => p_transfer(),
    adjustments => adjustments_index(),
    status => status(),
    external_id => id()
}.
-type params() :: #{
    id := id(),
    identity_id := identity_id(),
    body := body(),
    sender_resource := resource(),
    receiver_resource := resource(),
    exchange => exchange(),
    external_id => id()
}.

-type resource() ::
    {raw, resource_raw()}.

-type resource_full() ::
    {raw_full, resource_raw_full()} .

-type resource_raw() :: #{
    token          := binary(),
    bin            => binary(),
    masked_pan     => binary()
}.

-type exchange() :: #{
    created_at := ff_time:timestamp_ms(),
    party_revision := party_revision(),
    domain_revision := domain_revision(),
    sender_resource_id := ff_bin_data:bin_data_id(),
    receiver_resource_id := ff_bin_data:bin_data_id()
}.

-type resource_raw_full() :: #{
    token               := binary(),
    bin                 => binary(),
    payment_system      := atom(), % TODO
    masked_pan          => binary(),
    bank_name           => binary(),
    iso_country_code    => atom(),
    card_type           => charge_card | credit | debit | credit_or_debit,
    bin_data_id         := ff_bin_data:bin_data_id()
}.

-type status() ::
    pending         |
    succeeded       |
    {failed, failure()} .

-type event() ::
    {created, p2p_transfer()} |
    {resource_got, resource_full(), resource_full()} |
    {risk_score_changed, risk_score()} |
    {route_changed, route()} |
    {p_transfer, ff_postings_transfer:event()} |
    {session_started, session_id()} |
    {session_finished, {session_id(), session_result()}} |
    {status_changed, status()} |
    wrapped_adjustment_event().

-type resource_owner() :: sender | receiver.

-type create_error() ::
    {identity, notfound} |
    %% TODO add this validation
    % {terms, ff_party:validate_p2p_transfer_creation_error()} |
    {resource_full, {bin_data, not_found, resource_owner()}}.

-type route() :: #{
    provider_id := provider_id()
}.

-type prepared_route() :: #{
    route := route(),
    party_revision := party_revision(),
    domain_revision := domain_revision()
}.

-type adjustment_params() :: #{
    id := adjustment_id(),
    change := adjustment_change(),
    external_id => id()
}.

-type adjustment_change() ::
    {change_status, status()}.

-type start_adjustment_error() ::
    invalid_p2p_transfer_status_error() |
    invalid_status_change_error() |
    {another_adjustment_in_progress, adjustment_id()} |
    ff_adjustment:create_error().

-type unknown_adjustment_error() :: ff_adjustment_utils:unknown_adjustment_error().

-type invalid_status_change_error() ::
    {invalid_status_change, {unavailable_status, status()}} |
    {invalid_status_change, {already_has_status, status()}}.

-type invalid_p2p_transfer_status_error() ::
    {invalid_p2p_transfer_status, status()}.

-type action() :: poll | continue | undefined.

-export_type([p2p_transfer/0]).
-export_type([id/0]).
-export_type([params/0]).
-export_type([event/0]).
-export_type([route/0]).
-export_type([prepared_route/0]).
-export_type([create_error/0]).
-export_type([action/0]).
-export_type([adjustment_params/0]).
-export_type([start_adjustment_error/0]).

%% Transfer logic callbacks

-export([process_transfer/1]).

%% Accessors

-export([id/1]).
-export([body/1]).
-export([identity_id/1]).
-export([status/1]).
-export([risk_score/1]).
-export([exchange/1]).
-export([route/1]).
-export([external_id/1]).
-export([created_at/1]).
-export([party_revision/1]).
-export([domain_revision/1]).
-export([resource_full/2]).

%% API

-export([create/1]).
-export([is_finished/1]).

-export([start_adjustment/2]).
-export([find_adjustment/2]).
-export([adjustments/1]).

%% Event source

-export([apply_event/2]).
-export([maybe_migrate/1]).

%% Pipeline

-import(ff_pipeline, [do/1, unwrap/1, unwrap/2]).

%% Internal types

-type body() :: ff_transaction:body().
-type identity() :: ff_identity:identity().
-type identity_id() :: ff_identity:id().
-type party_id() :: ff_party:id().
-type process_result() :: {action(), [event()]}.
-type final_cash_flow() :: ff_cash_flow:final_cash_flow().
-type external_id() :: id() | undefined.
-type p_transfer() :: ff_postings_transfer:transfer().
-type session_id() :: id().
-type failure() :: ff_failure:failure().
%% FIXME change to real result type
-type session_result() :: ok. %p2p_transfer_session:session_result().
-type adjustment() :: ff_adjustment:adjustment().
-type adjustment_id() :: ff_adjustment:id().
-type adjustments_index() :: ff_adjustment_utils:index().
-type currency_id() :: ff_currency:id().
-type party_revision() :: ff_party:revision().
-type domain_revision() :: ff_domain_config:revision().
-type terms() :: ff_party:terms().
-type party_varset() :: hg_selector:varset().
-type risk_score() :: p2p_inspector:risk_score().

-type wrapped_adjustment_event() :: ff_adjustment_utils:wrapped_event().

-type provider_id() :: pos_integer().

-type legacy_event() :: any().

-type session() :: #{
    id := session_id(),
    result => session_result()
}.

-type party_varset_params() :: #{
    body := body(),
    party_id := party_id(),
    sender := resource_full(),
    receiver := resource_full()
}.

-type activity() ::
    risk_scoring |
    routing |
    p_transfer_start |
    p_transfer_prepare |
    session_starting |
    session_polling |
    p_transfer_commit |
    p_transfer_cancel |
    {fail, fail_type()} |
    adjustment |
    finish.

-type fail_type() ::
    risk_score_is_too_high |
    route_not_found |
    {invalid_exchange, _TODO} |
    session.

%% Accessors

-spec resource_full(p2p_transfer(), resource_owner()) ->
    resource_full().
resource_full(#{sender_resource := Resource}, sender) ->
    Resource;
resource_full(#{receiver_resource := Resource}, receiver) ->
    Resource.
%%

-spec exchange(p2p_transfer()) -> exchange() | undefined.
exchange(T) ->
    maps:get(exchange, T, undefined).

-spec id(p2p_transfer()) -> id().
id(#{id := V}) ->
    V.

-spec body(p2p_transfer()) -> body().
body(#{body := V}) ->
    V.

-spec identity_id(p2p_transfer()) -> identity_id().
identity_id(#{identity_id := V}) ->
    V.

-spec status(p2p_transfer()) -> status() | undefined.
status(T) ->
    OwnStatus = maps:get(status, T, undefined),
    %% `OwnStatus` is used in case of `{created, p2p_transfer()}` event marshaling
    %% The event p2p_transfer is not created from events, so `adjustments` can not have
    %% initial p2p_transfer status.
    ff_adjustment_utils:status(adjustments_index(T), OwnStatus).

-spec risk_score(p2p_transfer()) -> risk_score() | undefined.
risk_score(T) ->
    maps:get(risk_score, T, undefined).

-spec route(p2p_transfer()) -> route() | undefined.
route(T) ->
    maps:get(route, T, undefined).

-spec external_id(p2p_transfer()) -> external_id() | undefined.
external_id(T) ->
    maps:get(external_id, T, undefined).

-spec party_revision(p2p_transfer()) -> party_revision() | undefined.
party_revision(T) ->
    maps:get(party_revision, T, undefined).

-spec domain_revision(p2p_transfer()) -> domain_revision() | undefined.
domain_revision(T) ->
    maps:get(domain_revision, T, undefined).

-spec created_at(p2p_transfer()) -> ff_time:timestamp_ms() | undefined.
created_at(T) ->
    maps:get(created_at, T, undefined).

%% API

-spec create(params()) ->
    {ok, [event()]} |
    {error, create_error()}.
create(Params) ->
    do(fun() ->
        #{
            id := ID, 
            body := Body, 
            identity_id := IdentityID, 
            sender_resource := SenderSrc, 
            receiver_resource := ReceiverSrc
        } = Params,
        CreatedAt = ff_time:now(),

        Identity = get_identity(IdentityID),
        PartyID = ff_identity:party(Identity),

        Exchange = maps:get(exchange, Params, undefined),
        Timestamp = ff_maybe:get_defined(exchange_timestamp(Exchange), CreatedAt),
        PartyRevision = ensure_party_revision_defined(PartyID, exchange_party_revision(Exchange)),
        DomainRevision = ensure_domain_revision_defined(exchange_domain_revision(Exchange)),
        ResourceIDSender = ff_maybe:get_defined(exchange_resource_id_sender(Exchange), SenderSrc),
        ResourceSender = unwrap(resource_full, ff_destination:resource_full(ResourceIDSender)),
        ResourceIDReceiver = ff_maybe:get_defined(exchange_resource_id_receiver(Exchange), ReceiverSrc),
        ResourceReceiver = unwrap(resource_full, ff_destination:resource_full(ResourceIDReceiver)),

        ContractID = ff_identity:contract(Identity),
        VarsetParams = genlib_map:compact(#{
            body => Body,
            party_id => PartyID,
            sender => ResourceSender,
            receiver => ResourceReceiver
        }),
        {ok, Terms} = ff_party:get_contract_terms(
            PartyID, ContractID, build_party_varset(VarsetParams), Timestamp, PartyRevision, DomainRevision
        ),
        valid = unwrap(validate_p2p_transfer_creation(Terms, Body, ResourceSender, ResourceReceiver)),

        ExternalID = maps:get(external_id, Params, undefined),
        [
            {created, add_external_id(ExternalID, #{
                version => ?ACTUAL_FORMAT_VERSION,
                id => ID,
                transfer_type => p2p_transfer,
                body => Body,
                created_at => CreatedAt,
                party_revision => PartyRevision,
                domain_revision => DomainRevision,
                exchange => Exchange
            })},
            {status_changed, pending},
            {resource_got, ResourceSender, ResourceReceiver}
        ]
    end).

-spec start_adjustment(adjustment_params(), p2p_transfer()) ->
    {ok, process_result()} |
    {error, start_adjustment_error()}.
start_adjustment(Params, P2PTransfer) ->
    #{id := AdjustmentID} = Params,
    case find_adjustment(AdjustmentID, P2PTransfer) of
        {error, {unknown_adjustment, _}} ->
            do_start_adjustment(Params, P2PTransfer);
        {ok, _Adjustment} ->
            {ok, {undefined, []}}
    end.

-spec find_adjustment(adjustment_id(), p2p_transfer()) ->
    {ok, adjustment()} | {error, unknown_adjustment_error()}.
find_adjustment(AdjustmentID, P2PTransfer) ->
    ff_adjustment_utils:get_by_id(AdjustmentID, adjustments_index(P2PTransfer)).

-spec adjustments(p2p_transfer()) -> [adjustment()].
adjustments(P2PTransfer) ->
    ff_adjustment_utils:adjustments(adjustments_index(P2PTransfer)).

%% Сущность в настоящий момент нуждается в передаче ей управления для совершения каких-то действий
-spec is_active(p2p_transfer()) -> boolean().
is_active(#{status := succeeded} = P2PTransfer) ->
    is_childs_active(P2PTransfer);
is_active(#{status := {failed, _}} = P2PTransfer) ->
    is_childs_active(P2PTransfer);
is_active(#{status := pending}) ->
    true.

%% Сущность завершила свою основную задачу по переводу денег. Дальше её состояние будет меняться только
%% изменением дочерних сущностей, например запуском adjustment.
-spec is_finished(p2p_transfer()) -> boolean().
is_finished(#{status := succeeded}) ->
    true;
is_finished(#{status := {failed, _}}) ->
    true;
is_finished(#{status := pending}) ->
    false.

%% Transfer callbacks

-spec process_transfer(p2p_transfer()) ->
    process_result().
process_transfer(P2PTransfer) ->
    Activity = deduce_activity(P2PTransfer),
    do_process_transfer(Activity, P2PTransfer).

%% Internals

-spec do_start_adjustment(adjustment_params(), p2p_transfer()) ->
    {ok, process_result()} |
    {error, start_adjustment_error()}.
do_start_adjustment(Params, P2PTransfer) ->
    do(fun() ->
        valid = unwrap(validate_adjustment_start(Params, P2PTransfer)),
        AdjustmentParams = make_adjustment_params(Params, P2PTransfer),
        #{id := AdjustmentID} = Params,
        {Action, Events} = unwrap(ff_adjustment:create(AdjustmentParams)),
        {Action, ff_adjustment_utils:wrap_events(AdjustmentID, Events)}
    end).

%% Internal getters

-spec p_transfer(p2p_transfer()) -> p_transfer() | undefined.
p_transfer(P2PTransfer) ->
    maps:get(p_transfer, P2PTransfer, undefined).

-spec p_transfer_status(p2p_transfer()) -> ff_postings_transfer:status() | undefined.
p_transfer_status(P2PTransfer) ->
    case p_transfer(P2PTransfer) of
        undefined ->
            undefined;
        Transfer ->
            ff_postings_transfer:status(Transfer)
    end.

-spec risk_score_status(p2p_transfer()) -> unknown | scored.
risk_score_status(P2PTransfer) ->
    case risk_score(P2PTransfer) of
        undefined ->
            unknown;
        _Known ->
            found
    end.

-spec route_selection_status(p2p_transfer()) -> unknown | found.
route_selection_status(P2PTransfer) ->
    case route(P2PTransfer) of
        undefined ->
            unknown;
        _Known ->
            found
    end.

add_external_id(undefined, Event) ->
    Event;
add_external_id(ExternalID, Event) ->
    Event#{external_id => ExternalID}.

-spec adjustments_index(p2p_transfer()) -> adjustments_index().
adjustments_index(P2PTransfer) ->
    case maps:find(adjustments, P2PTransfer) of
        {ok, Adjustments} ->
            Adjustments;
        error ->
            ff_adjustment_utils:new_index()
    end.

-spec set_adjustments_index(adjustments_index(), p2p_transfer()) -> p2p_transfer().
set_adjustments_index(Adjustments, P2PTransfer) ->
    P2PTransfer#{adjustments => Adjustments}.

-spec effective_final_cash_flow(p2p_transfer()) -> final_cash_flow().
effective_final_cash_flow(P2PTransfer) ->
    case ff_adjustment_utils:cash_flow(adjustments_index(P2PTransfer)) of
        undefined ->
            ff_cash_flow:make_empty_final();
        CashFlow ->
            CashFlow
    end.

-spec operation_timestamp(p2p_transfer()) -> ff_time:timestamp_ms().
operation_timestamp(P2PTransfer) ->
    QuoteTimestamp = exchange_timestamp(exchange(P2PTransfer)),
    ff_maybe:get_defined([QuoteTimestamp, created_at(P2PTransfer), ff_time:now()]).

-spec operation_party_revision(p2p_transfer()) ->
    domain_revision().
operation_party_revision(P2PTransfer) ->
    case party_revision(P2PTransfer) of
        undefined ->
            PartyID = ff_identity:party(get_identity(identity_id(P2PTransfer))),
            {ok, Revision} = ff_party:get_revision(PartyID),
            Revision;
        Revision ->
            Revision
    end.

-spec operation_domain_revision(p2p_transfer()) ->
    domain_revision().
operation_domain_revision(P2PTransfer) ->
    case domain_revision(P2PTransfer) of
        undefined ->
            ff_domain_config:head();
        Revision ->
            Revision
    end.

%% Processing helpers

-spec deduce_activity(p2p_transfer()) ->
    activity().
deduce_activity(P2PTransfer) ->
    Params = #{
        risk_score => risk_score_status(P2PTransfer),
        route => route_selection_status(P2PTransfer),
        p_transfer => p_transfer_status(P2PTransfer),
        session => session_processing_status(P2PTransfer),
        status => status(P2PTransfer),
        active_adjustment => ff_adjustment_utils:is_active(adjustments_index(P2PTransfer))
    },
    do_deduce_activity(Params).

do_deduce_activity(#{status := pending} = Params) ->
    do_pending_activity(Params);
do_deduce_activity(#{status := succeeded} = Params) ->
    do_finished_activity(Params);
do_deduce_activity(#{status := {failed, _}} = Params) ->
    do_finished_activity(Params).

do_pending_activity(#{risk_score := unknown, p_transfer := undefined}) ->
    risk_scoring;
do_pending_activity(#{risk_score := scored, route := unknown, p_transfer := undefined}) ->
    routing;
do_pending_activity(#{route := found, p_transfer := undefined}) ->
    p_transfer_start;
do_pending_activity(#{p_transfer := created}) ->
    p_transfer_prepare;
do_pending_activity(#{p_transfer := prepared, session := undefined}) ->
    session_starting;
do_pending_activity(#{p_transfer := prepared, session := pending}) ->
    session_polling;
do_pending_activity(#{p_transfer := prepared, session := succeeded}) ->
    p_transfer_commit;
do_pending_activity(#{p_transfer := committed, session := succeeded}) ->
    finish;
do_pending_activity(#{p_transfer := prepared, session := failed}) ->
    p_transfer_cancel;
do_pending_activity(#{p_transfer := cancelled, session := failed}) ->
    {fail, session}.

do_finished_activity(#{active_adjustment := true}) ->
    adjustment.

-spec do_process_transfer(activity(), p2p_transfer()) ->
    process_result().
do_process_transfer(risk_scoring, P2PTransfer) ->
    process_risk_scoring(P2PTransfer);
do_process_transfer(routing, P2PTransfer) ->
    process_routing(P2PTransfer);
do_process_transfer(p_transfer_start, P2PTransfer) ->
    process_p_transfer_creation(P2PTransfer);
do_process_transfer(p_transfer_prepare, P2PTransfer) ->
    {ok, Events} = ff_pipeline:with(p_transfer, P2PTransfer, fun ff_postings_transfer:prepare/1),
    {continue, Events};
do_process_transfer(p_transfer_commit, P2PTransfer) ->
    {ok, Events} = ff_pipeline:with(p_transfer, P2PTransfer, fun ff_postings_transfer:commit/1),
    {continue, Events};
do_process_transfer(p_transfer_cancel, P2PTransfer) ->
    {ok, Events} = ff_pipeline:with(p_transfer, P2PTransfer, fun ff_postings_transfer:cancel/1),
    {continue, Events};
do_process_transfer(session_starting, P2PTransfer) ->
    process_session_creation(P2PTransfer);
do_process_transfer(session_polling, P2PTransfer) ->
    process_session_poll(P2PTransfer);
do_process_transfer({fail, Reason}, P2PTransfer) ->
    process_transfer_fail(Reason, P2PTransfer);
do_process_transfer(finish, P2PTransfer) ->
    process_transfer_finish(P2PTransfer);
do_process_transfer(adjustment, P2PTransfer) ->
    Result = ff_adjustment_utils:process_adjustments(adjustments_index(P2PTransfer)),
    handle_child_result(Result, P2PTransfer).

-spec process_risk_scoring(p2p_transfer()) ->
    process_result().
process_risk_scoring(_P2PTransfer) ->
    {continue, [
        {risk_score_changed, #{risk_score => low}}
    ]}.

-spec process_routing(p2p_transfer()) ->
    process_result().
process_routing(P2PTransfer) ->
    case do_process_routing(P2PTransfer) of
        {ok, ProviderID} ->
            {continue, [
                {route_changed, #{provider_id => ProviderID}}
            ]};
        {error, route_not_found} ->
            process_transfer_fail(route_not_found, P2PTransfer)
    end.

-spec do_process_routing(p2p_transfer()) -> 
    {ok, provider_id()} | {error, route_not_found}.
do_process_routing(P2PTransfer) ->
    DomainRevision = operation_domain_revision(P2PTransfer),
    ResourceSender = resource_full(P2PTransfer, sender),
    ResourceReceiver = resource_full(P2PTransfer, receiver),
    Identity = get_identity(identity_id(P2PTransfer)),
    PartyID = ff_identity:party(Identity),
    VarsetParams = genlib_map:compact(#{
        body => body(P2PTransfer),
        party_id => PartyID,
        sender => ResourceSender,
        receiver => ResourceReceiver
    }),

    do(fun() ->
        unwrap(prepare_route(build_party_varset(VarsetParams), Identity, DomainRevision))
    end).

-spec prepare_route(party_varset(), identity(), domain_revision()) ->
    {ok, provider_id()} | {error, route_not_found}.

prepare_route(PartyVarset, Identity, DomainRevision) ->
    {ok, PaymentInstitutionID} = ff_party:get_identity_payment_institution_id(Identity),
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionID, DomainRevision),
    case ff_payment_institution:compute_p2p_transfer_providers(PaymentInstitution, PartyVarset) of
        {ok, Providers}  ->
            choose_provider(Providers, PartyVarset);
        {error, {misconfiguration, _Details} = Error} ->
            %% TODO: Do not interpret such error as an empty route list.
            %% The current implementation is made for compatibility reasons.
            %% Try to remove and follow the tests.
            _ = logger:warning("Route search failed: ~p", [Error]),
            {error, route_not_found}
    end.

-spec choose_provider([provider_id()], party_varset()) ->
    {ok, provider_id()} | {error, route_not_found}.
choose_provider(Providers, VS) ->
    case lists:filter(fun(P) -> validate_p2p_transfers_terms(P, VS) end, Providers) of
        [ProviderID | _] ->
            {ok, ProviderID};
        [] ->
            {error, route_not_found}
    end.

-spec validate_p2p_transfers_terms(provider_id(), party_varset()) ->
    boolean().
validate_p2p_transfers_terms(ID, VS) ->
    % TODO Change to p2p provider module
    Provider = unwrap(ff_payouts_provider:get(ID)),
    case ff_payouts_provider:validate_terms(Provider, VS) of
        {ok, valid} ->
            true;
        {error, _Error} ->
            false
    end.

-spec process_p_transfer_creation(p2p_transfer()) ->
    process_result().
process_p_transfer_creation(P2PTransfer) ->
    FinalCashFlow = make_final_cash_flow(P2PTransfer),
    PTransferID = construct_p_transfer_id(id(P2PTransfer)),
    {ok, PostingsTransferEvents} = ff_postings_transfer:create(PTransferID, FinalCashFlow),
    {continue, [{p_transfer, Ev} || Ev <- PostingsTransferEvents]}.

-spec process_session_creation(p2p_transfer()) ->
    process_result().
process_session_creation(P2PTransfer) ->
    ID = construct_session_id(id(P2PTransfer)),
    {continue, [{session_started, ID}]}.

construct_session_id(ID) ->
    ID.

-spec construct_p_transfer_id(id()) -> id().
construct_p_transfer_id(ID) ->
    <<"ff/p2p_transfer/", ID/binary>>.

-spec process_session_poll(p2p_transfer()) ->
    process_result().
process_session_poll(P2PTransfer) ->
    SessionID = session_id(P2PTransfer),
    {continue, [{session_finished, {SessionID, ok}}]}.

-spec process_transfer_finish(p2p_transfer()) ->
    process_result().
process_transfer_finish(_P2PTransfer) ->
    {undefined, [{status_changed, succeeded}]}.

-spec process_transfer_fail(fail_type(), p2p_transfer()) ->
    process_result().
process_transfer_fail(FailType, P2PTransfer) ->
    Failure = build_failure(FailType, P2PTransfer),
    {undefined, [{status_changed, {failed, Failure}}]}.

-spec handle_child_result(process_result(), p2p_transfer()) -> process_result().
handle_child_result({undefined, Events} = Result, P2PTransfer) ->
    NextP2PTransfer = lists:foldl(fun(E, Acc) -> apply_event(E, Acc) end, P2PTransfer, Events),
    case is_active(NextP2PTransfer) of
        true ->
            {continue, Events};
        false ->
            Result
    end;
handle_child_result({_OtherAction, _Events} = Result, _P2PTransfer) ->
    Result.

-spec is_childs_active(p2p_transfer()) -> boolean().
is_childs_active(P2PTransfer) ->
    ff_adjustment_utils:is_active(adjustments_index(P2PTransfer)).

-spec make_final_cash_flow(p2p_transfer()) ->
    final_cash_flow().
make_final_cash_flow(P2PTransfer) ->
    Body = body(P2PTransfer),
    Route = route(P2PTransfer),
    DomainRevision = operation_domain_revision(P2PTransfer),
    ResourceSender = resource_full(P2PTransfer, sender),
    ResourceReceiver = resource_full(P2PTransfer, receiver),
    Identity = get_identity(identity_id(P2PTransfer)),
    PartyID = ff_identity:party(Identity),
    PartyRevision = operation_party_revision(P2PTransfer),
    ContractID = ff_identity:contract(Identity),
    Timestamp = operation_timestamp(P2PTransfer),
    VarsetParams = genlib_map:compact(#{
        body => body(P2PTransfer),
        party_id => PartyID,
        sender => ResourceSender,
        receiver => ResourceReceiver
    }),
    PartyVarset = build_party_varset(VarsetParams),

    {_Amount, CurrencyID} = Body,
    #{provider_id := ProviderID} = Route,
    {ok, Provider} = ff_payouts_provider:get(ProviderID),
    ProviderAccounts = ff_payouts_provider:accounts(Provider),
    ProviderAccount = maps:get(CurrencyID, ProviderAccounts, undefined),

    {ok, PaymentInstitutionID} = ff_party:get_identity_payment_institution_id(Identity),
    {ok, PaymentInstitution} = ff_payment_institution:get(PaymentInstitutionID, DomainRevision),
    {ok, SystemAccounts} = ff_payment_institution:compute_system_accounts(PaymentInstitution, PartyVarset),
    SystemAccount = maps:get(CurrencyID, SystemAccounts, #{}),
    SettlementAccount = maps:get(settlement, SystemAccount, undefined),
    SubagentAccount = maps:get(subagent, SystemAccount, undefined),

    ProviderFee = ff_payouts_provider:compute_fees(Provider, PartyVarset),

    {ok, Terms} = ff_party:get_contract_terms(
        PartyID, ContractID, PartyVarset, Timestamp, PartyRevision, DomainRevision
    ),
    {ok, WalletCashFlowPlan} = ff_party:get_p2p_transfer_cash_flow_plan(Terms),
    {ok, CashFlowPlan} = ff_cash_flow:add_fee(WalletCashFlowPlan, ProviderFee),
    Constants = #{
        operation_amount => Body
    },
    Accounts = genlib_map:compact(#{
        {system, settlement} => SettlementAccount,
        {system, subagent} => SubagentAccount,
        {provider, settlement} => ProviderAccount
    }),
    {ok, FinalCashFlow} = ff_cash_flow:finalize(CashFlowPlan, Accounts, Constants),
    FinalCashFlow.

-spec ensure_domain_revision_defined(domain_revision() | undefined) ->
    domain_revision().
ensure_domain_revision_defined(undefined) ->
    ff_domain_config:head();
ensure_domain_revision_defined(Revision) ->
    Revision.

-spec ensure_party_revision_defined(party_id(), party_revision() | undefined) ->
    domain_revision().
ensure_party_revision_defined(PartyID, undefined) ->
    {ok, Revision} = ff_party:get_revision(PartyID),
    Revision;
ensure_party_revision_defined(_PartyID, Revision) ->
    Revision.

-spec get_identity(identity_id()) ->
    identity() | no_return().
get_identity(IdentityID) ->
    IdentityMachine = unwrap(identity, ff_identity_machine:get(IdentityID)),
    ff_identity_machine:identity(IdentityMachine).

-spec build_party_varset(party_varset_params()) ->
    party_varset().
build_party_varset(#{
    body := Body, 
    party_id := PartyID, 
    sender := ResourceSender, 
    receiver := ResourceReceiver
}) ->
    {_, CurrencyID} = Body,
    TransferToolSender = construct_payment_tool(ResourceSender),
    TransferToolReceiver = construct_payment_tool(ResourceReceiver),
    genlib_map:compact(#{
        currency => ff_dmsl_codec:marshal(currency_ref, CurrencyID),
        cost => ff_dmsl_codec:marshal(cash, Body),
        party_id => PartyID,
        payout_method => #domain_PayoutMethodRef{id = wallet_info},
        transfer_tool_sender => TransferToolSender,
        transfer_tool_receiver => TransferToolReceiver
    }).

-spec construct_payment_tool(resource_full()) ->
    dmsl_domain_thrift:'PaymentTool'().
construct_payment_tool({raw_full, ResourceRaw}) ->
    {bank_card, #domain_BankCard{
        token           = maps:get(token, ResourceRaw),
        bin             = maps:get(bin, ResourceRaw),
        masked_pan      = maps:get(masked_pan, ResourceRaw),
        payment_system  = maps:get(payment_system, ResourceRaw),
        issuer_country  = maps:get(iso_country_code, ResourceRaw, undefined),
        bank_name       = maps:get(bank_name, ResourceRaw, undefined)
    }}.

%% Exchange helpers

exchange_resource_id_sender(undefined) ->
    undefined;
exchange_resource_id_sender(Data) ->
    maps:get(<<"resource_id_sender">>, Data, undefined).

exchange_resource_id_receiver(undefined) ->
    undefined;
exchange_resource_id_receiver(Data) ->
    maps:get(<<"resource_id_receiver">>, Data, undefined).

-spec exchange_timestamp(exchange() | undefined) ->
    ff_time:timestamp_ms() | undefined.
exchange_timestamp(undefined) ->
    undefined;
exchange_timestamp(Data) ->
    maps:get(<<"timestamp">>, Data, undefined).

-spec exchange_party_revision(exchange() | undefined) ->
    party_revision() | undefined.
exchange_party_revision(undefined) ->
    undefined;
exchange_party_revision(Data) ->
    maps:get(<<"party_revision">>, Data, undefined).

-spec exchange_domain_revision(exchange() | undefined) ->
    domain_revision() | undefined.
exchange_domain_revision(undefined) ->
    undefined;
exchange_domain_revision(Data) ->
    maps:get(<<"domain_revision">>, Data, undefined).

%% Session management

-spec session(p2p_transfer()) -> session() | undefined.
session(P2PTransfer) ->
    maps:get(session, P2PTransfer, undefined).

-spec session_id(p2p_transfer()) -> session_id() | undefined.
session_id(T) ->
    case session(T) of
        undefined ->
            undefined;
        #{id := SessionID} ->
            SessionID
    end.

-spec session_result(p2p_transfer()) -> session_result() | unknown | undefined.
session_result(P2PTransfer) ->
    case session(P2PTransfer) of
        undefined ->
            undefined;
        #{result := Result} ->
            Result;
        #{} ->
            unknown
    end.

-spec session_processing_status(p2p_transfer()) ->
    undefined | pending | succeeded | failed.
session_processing_status(P2PTransfer) ->
    case session_result(P2PTransfer) of
        undefined ->
            undefined;
        unknown ->
            pending;
        {success, _TrxInfo} ->
            succeeded;
        {failed, _Failure} ->
            failed
    end.

%% P2PTransfer validators

-spec validate_p2p_transfer_creation(terms(), body(), resource_full(), resource_full()) ->
    {ok, valid} |
    {error, create_error()}.
validate_p2p_transfer_creation(Terms, Body, Sender, Receiver) ->
    do(fun() ->
        valid = unwrap(terms, ff_party:validate_p2p_transfer_creation(Terms, Body)),
        valid = unwrap(validate_p2p_transfer_currency(Body, Sender, Receiver))
    end).

-spec validate_p2p_transfer_currency(body(), resource_full(), resource_full()) ->
    {ok, valid} |
    {error, {inconsistent_currency, {currency_id(), currency_id(), currency_id()}}}.
validate_p2p_transfer_currency(Body, Sender, Receiver) ->
    CurrencyIDSender = currency(Sender),
    CurrencyIDReceiver = currency(Receiver),
    case Body of
        {_Amount, P2PTransferCurencyID} when
            P2PTransferCurencyID =:= CurrencyIDSender andalso
            P2PTransferCurencyID =:= CurrencyIDReceiver
        ->
            {ok, valid};
        {_Amount, P2PTransferCurencyID} ->
            {error, {inconsistent_currency, {P2PTransferCurencyID, CurrencyIDSender, CurrencyIDReceiver}}}
    end.

-spec currency(resource_full()) ->
    currency_id().

currency({raw_full, #{iso_country_code := ISO}}) ->
    ff_currency:from_iso_country(ISO).

%% Adjustment validators

-spec validate_adjustment_start(adjustment_params(), p2p_transfer()) ->
    {ok, valid} |
    {error, start_adjustment_error()}.
validate_adjustment_start(Params, P2PTransfer) ->
    do(fun() ->
        valid = unwrap(validate_no_pending_adjustment(P2PTransfer)),
        valid = unwrap(validate_p2p_transfer_finish(P2PTransfer)),
        valid = unwrap(validate_status_change(Params, P2PTransfer))
    end).

-spec validate_p2p_transfer_finish(p2p_transfer()) ->
    {ok, valid} |
    {error, {invalid_p2p_transfer_status, status()}}.
validate_p2p_transfer_finish(P2PTransfer) ->
    case is_finished(P2PTransfer) of
        true ->
            {ok, valid};
        false ->
            {error, {invalid_p2p_transfer_status, status(P2PTransfer)}}
    end.

-spec validate_no_pending_adjustment(p2p_transfer()) ->
    {ok, valid} |
    {error, {another_adjustment_in_progress, adjustment_id()}}.
validate_no_pending_adjustment(P2PTransfer) ->
    case ff_adjustment_utils:get_not_finished(adjustments_index(P2PTransfer)) of
        error ->
            {ok, valid};
        {ok, AdjustmentID} ->
            {error, {another_adjustment_in_progress, AdjustmentID}}
    end.

-spec validate_status_change(adjustment_params(), p2p_transfer()) ->
    {ok, valid} |
    {error, invalid_status_change_error()}.
validate_status_change(#{change := {change_status, Status}}, P2PTransfer) ->
    do(fun() ->
        valid = unwrap(invalid_status_change, validate_target_status(Status)),
        valid = unwrap(invalid_status_change, validate_change_same_status(Status, status(P2PTransfer)))
    end);
validate_status_change(_Params, _P2PTransfer) ->
    {ok, valid}.

-spec validate_target_status(status()) ->
    {ok, valid} |
    {error, {unavailable_status, status()}}.
validate_target_status(succeeded) ->
    {ok, valid};
validate_target_status({failed, _Failure}) ->
    {ok, valid};
validate_target_status(Status) ->
    {error, {unavailable_status, Status}}.

-spec validate_change_same_status(status(), status()) ->
    {ok, valid} |
    {error, {already_has_status, status()}}.
validate_change_same_status(NewStatus, OldStatus) when NewStatus =/= OldStatus ->
    {ok, valid};
validate_change_same_status(Status, Status) ->
    {error, {already_has_status, Status}}.

%% Adjustment helpers

-spec apply_adjustment_event(wrapped_adjustment_event(), p2p_transfer()) -> p2p_transfer().
apply_adjustment_event(WrappedEvent, P2PTransfer) ->
    Adjustments0 = adjustments_index(P2PTransfer),
    Adjustments1 = ff_adjustment_utils:apply_event(WrappedEvent, Adjustments0),
    set_adjustments_index(Adjustments1, P2PTransfer).

-spec make_adjustment_params(adjustment_params(), p2p_transfer()) ->
    ff_adjustment:params().
make_adjustment_params(Params, P2PTransfer) ->
    #{id := ID, change := Change} = Params,
    genlib_map:compact(#{
        id => ID,
        changes_plan => make_adjustment_change(Change, P2PTransfer),
        external_id => genlib_map:get(external_id, Params),
        domain_revision => operation_domain_revision(P2PTransfer),
        party_revision => operation_party_revision(P2PTransfer),
        operation_timestamp => operation_timestamp(P2PTransfer)
    }).

-spec make_adjustment_change(adjustment_change(), p2p_transfer()) ->
    ff_adjustment:changes().
make_adjustment_change({change_status, NewStatus}, P2PTransfer) ->
    CurrentStatus = status(P2PTransfer),
    make_change_status_params(CurrentStatus, NewStatus, P2PTransfer).

-spec make_change_status_params(status(), status(), p2p_transfer()) ->
    ff_adjustment:changes().
make_change_status_params(succeeded, {failed, _} = NewStatus, P2PTransfer) ->
    CurrentCashFlow = effective_final_cash_flow(P2PTransfer),
    NewCashFlow = ff_cash_flow:make_empty_final(),
    #{
        new_status => NewStatus,
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        }
    };
make_change_status_params({failed, _}, succeeded = NewStatus, P2PTransfer) ->
    CurrentCashFlow = effective_final_cash_flow(P2PTransfer),
    NewCashFlow = make_final_cash_flow(P2PTransfer),
    #{
        new_status => NewStatus,
        new_cash_flow => #{
            old_cash_flow_inverted => ff_cash_flow:inverse(CurrentCashFlow),
            new_cash_flow => NewCashFlow
        }
    };
make_change_status_params({failed, _}, {failed, _} = NewStatus, _P2PTransfer) ->
    #{
        new_status => NewStatus
    }.

-spec save_adjustable_info(event(), p2p_transfer()) -> p2p_transfer().
save_adjustable_info({status_changed, Status}, P2PTransfer) ->
    update_adjusment_index(fun ff_adjustment_utils:set_status/2, Status, P2PTransfer);
save_adjustable_info({p_transfer, {status_changed, committed}}, P2PTransfer) ->
    CashFlow = ff_postings_transfer:final_cash_flow(p_transfer(P2PTransfer)),
    update_adjusment_index(fun ff_adjustment_utils:set_cash_flow/2, CashFlow, P2PTransfer);
save_adjustable_info(_Ev, P2PTransfer) ->
    P2PTransfer.

-spec update_adjusment_index(Updater, Value, p2p_transfer()) -> p2p_transfer() when
    Updater :: fun((Value, adjustments_index()) -> adjustments_index()),
    Value :: any().
update_adjusment_index(Updater, Value, P2PTransfer) ->
    Index = adjustments_index(P2PTransfer),
    set_adjustments_index(Updater(Value, Index), P2PTransfer).

%% Failure helpers

-spec build_failure(fail_type(), p2p_transfer()) -> failure().
build_failure(risk_score_is_too_high, _P2PTransfer) ->
    #{
        code => <<"risk_score_is_too_high">>
    };
build_failure(route_not_found, _P2PTransfer) ->
    #{
        code => <<"no_route_found">>
    };
build_failure({invalid_exchange, Details}, _P2PTransfer) ->
    #{
        code => <<"unknown">>,
        reason => genlib:format(Details)
    };
build_failure(session, P2PTransfer) ->
    Result = session_result(P2PTransfer),
    {failed, Failure} = Result,
    Failure.

%%

-spec apply_event(event() | legacy_event(), ff_maybe:maybe(p2p_transfer())) ->
    p2p_transfer().
apply_event(Ev, T0) ->
    Migrated = maybe_migrate(Ev),
    T1 = apply_event_(Migrated, T0),
    T2 = save_adjustable_info(Migrated, T1),
    T2.

-spec apply_event_(event(), ff_maybe:maybe(p2p_transfer())) ->
    p2p_transfer().
apply_event_({created, T}, undefined) ->
    T;
apply_event_({status_changed, Status}, T) ->
    maps:put(status, Status, T);
apply_event_({resource_got, Sender, Receiver}, T0) ->
    T1 = maps:put(sender_resource, Sender, T0),
    maps:put(receiver_resource, Receiver, T1);
apply_event_({p_transfer, Ev}, T) ->
    T#{p_transfer => ff_postings_transfer:apply_event(Ev, p_transfer(T))};
apply_event_({session_started, SessionID}, T) ->
    Session = #{id => SessionID},
    maps:put(session, Session, T);
apply_event_({session_finished, {SessionID, Result}}, T) ->
    #{id := SessionID} = Session = session(T),
    maps:put(session, Session#{result => Result}, T);
apply_event_({risk_score_changed, RiskScore}, T) ->
    maps:put(risk_score, RiskScore, T);
apply_event_({route_changed, Route}, T) ->
    maps:put(route, Route, T);
apply_event_({adjustment, _Ev} = Event, T) ->
    apply_adjustment_event(Event, T).

-spec maybe_migrate(event() | legacy_event()) ->
    event().
% Actual events
maybe_migrate(Ev) ->
    Ev.