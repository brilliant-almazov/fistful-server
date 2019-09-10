-module(ff_server_admin_handler).
-behaviour(woody_server_thrift_handler).

-include_lib("fistful_proto/include/ff_proto_fistful_admin_thrift.hrl").

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%%
%% woody_server_thrift_handler callbacks
%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().
handle_function(Func, Args, Context, Opts) ->
    scoper:scope(fistful, #{function => Func},
        fun() ->
            ok = ff_woody_ctx:set(Context),
            try
                handle_function_(Func, Args, Context, Opts)
            after
                ff_woody_ctx:unset()
            end
        end
    ).

%%
%% Internals
%%

handle_function_('CreateSource', [Params], Context, Opts) ->
    SourceID = Params#ff_admin_SourceParams.id,
    case ff_source:create(SourceID, #{
            identity => Params#ff_admin_SourceParams.identity_id,
            name     => Params#ff_admin_SourceParams.name,
            currency => ff_codec:unmarshal(currency_ref, Params#ff_admin_SourceParams.currency),
            resource => ff_source_codec:unmarshal(resource, Params#ff_admin_SourceParams.resource)
        }, ff_ctx:new())
    of
        ok ->
            handle_function_('GetSource', [SourceID], Context, Opts);
        {error, {identity, notfound}} ->
            woody_error:raise(business, #fistful_IdentityNotFound{});
        {error, {currency, notfound}} ->
            woody_error:raise(business, #fistful_CurrencyNotFound{});
        {error, Error} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Error)})
    end;
handle_function_('GetSource', [ID], _Context, _Opts) ->
    case ff_source:get_machine(ID) of
        {ok, Machine} ->
            Source = ff_source:get(Machine),
            {ok, ff_source_codec:marshal(source, Source)};
        {error, notfound} ->
            woody_error:raise(business, #fistful_SourceNotFound{})
    end;
handle_function_('CreateDeposit', [Params], Context, Opts) ->
    DepositID = Params#ff_admin_DepositParams.id,
    DepositParams = #{
        id          => DepositID,
        source_id   => Params#ff_admin_DepositParams.source,
        wallet_id   => Params#ff_admin_DepositParams.destination,
        body        => ff_codec:unmarshal(cash, Params#ff_admin_DepositParams.body)
    },
    case handle_create_result(ff_deposit_machine:create(DepositParams, ff_ctx:new())) of
        ok ->
            handle_function_('GetDeposit', [DepositID], Context, Opts);
        {error, {source, notfound}} ->
            woody_error:raise(business, #fistful_SourceNotFound{});
        {error, {source, unauthorized}} ->
            woody_error:raise(business, #fistful_SourceUnauthorized{});
        {error, {wallet, notfound}} ->
            woody_error:raise(business, #fistful_DestinationNotFound{});
        {error, {terms_violation, {not_allowed_currency, _More}}} ->
            woody_error:raise(business, #fistful_DepositCurrencyInvalid{});
        {error, {bad_deposit_amount, _Amount}} ->
            woody_error:raise(business, #fistful_DepositAmountInvalid{});
        {error, Error} ->
            woody_error:raise(system, {internal, result_unexpected, woody_error:format_details(Error)})
    end;
handle_function_('GetDeposit', [ID], _Context, _Opts) ->
    case ff_deposit_machine:get(ID) of
        {ok, Machine} ->
            Deposit = ff_deposit_machine:deposit(Machine),
            {ok, ff_deposit_codec:marshal(deposit, Deposit)};
        {error, {unknown_deposit, _}} ->
            woody_error:raise(business, #fistful_DepositNotFound{})
    end.

handle_create_result(ok) ->
    ok;
handle_create_result({error, exists}) ->
    ok;
handle_create_result({error, _Reason} = Error) ->
    Error.
