-module(ff_dmsl_codec).

-include_lib("damsel/include/dmsl_domain_thrift.hrl").
-include_lib("damsel/include/dmsl_user_interaction_thrift.hrl").

-export([unmarshal/2]).
-export([marshal/2]).

%% Types

-type type_name() :: atom() | {list, atom()}.
-type codec() :: module().

-type encoded_value() :: encoded_value(any()).
-type encoded_value(T) :: T.

-type decoded_value() :: decoded_value(any()).
-type decoded_value(T) :: T.

-export_type([codec/0]).
-export_type([type_name/0]).
-export_type([encoded_value/0]).
-export_type([encoded_value/1]).
-export_type([decoded_value/0]).
-export_type([decoded_value/1]).


-spec unmarshal(ff_dmsl_codec:type_name(), ff_dmsl_codec:encoded_value()) ->
    ff_dmsl_codec:decoded_value().

unmarshal(transaction_info, #domain_TransactionInfo{
    id   = ID,
    timestamp = Timestamp,
    extra = Extra,
    additional_info = AddInfo
}) ->
    genlib_map:compact(#{
        id => unmarshal(string, ID),
        timestamp => maybe_unmarshal(string, Timestamp),
        extra => Extra,
        additional_info => maybe_unmarshal(additional_transaction_info, AddInfo)
    });

unmarshal(additional_transaction_info, #domain_AdditionalTransactionInfo{
    rrn = RRN,
    approval_code = ApprovalCode,
    acs_url = AcsURL,
    pareq = Pareq,
    md = MD,
    term_url = TermURL,
    pares = Pares,
    eci = ECI,
    cavv = CAVV,
    xid = XID,
    cavv_algorithm = CAVVAlgorithm,
    three_ds_verification = ThreeDSVerification
}) ->
    genlib_map:compact(#{
        rrn => maybe_unmarshal(string, RRN),
        approval_code => maybe_unmarshal(string, ApprovalCode),
        acs_url => maybe_unmarshal(string, AcsURL),
        pareq => maybe_unmarshal(string, Pareq),
        md => maybe_unmarshal(string, MD),
        term_url => maybe_unmarshal(string, TermURL),
        pares => maybe_unmarshal(string, Pares),
        eci => maybe_unmarshal(string, ECI),
        cavv => maybe_unmarshal(string, CAVV),
        xid => maybe_unmarshal(string, XID),
        cavv_algorithm => maybe_unmarshal(string, CAVVAlgorithm),
        three_ds_verification => maybe_unmarshal(three_ds_verification, ThreeDSVerification)
    });

unmarshal(three_ds_verification, Value) when
    Value =:= authentication_successful orelse
    Value =:= attempts_processing_performed orelse
    Value =:= authentication_failed orelse
    Value =:= authentication_could_not_be_performed
->
    Value;

unmarshal(failure, #domain_Failure{
    code = Code,
    reason = Reason,
    sub = SubFailure
}) ->
    genlib_map:compact(#{
        code => unmarshal(string, Code),
        reason => maybe_unmarshal(string, Reason),
        sub => maybe_unmarshal(sub_failure, SubFailure)
    });
unmarshal(sub_failure, #domain_SubFailure{
    code = Code,
    sub = SubFailure
}) ->
    genlib_map:compact(#{
        code => unmarshal(string, Code),
        sub => maybe_unmarshal(sub_failure, SubFailure)
    });

unmarshal(cash, #domain_Cash{
    amount   = Amount,
    currency = CurrencyRef
}) ->
    {unmarshal(amount, Amount), unmarshal(currency_ref, CurrencyRef)};

unmarshal(cash_range, #domain_CashRange{
    lower = {BoundLower, CashLower},
    upper = {BoundUpper, CashUpper}
}) ->
    {
        {BoundLower, unmarshal(cash, CashLower)},
        {BoundUpper, unmarshal(cash, CashUpper)}
    };

unmarshal(currency_ref, #domain_CurrencyRef{
    symbolic_code = SymbolicCode
}) ->
    unmarshal(string, SymbolicCode);

unmarshal(currency, #domain_Currency{
    name          = Name,
    symbolic_code = Symcode,
    numeric_code  = Numcode,
    exponent      = Exponent
}) ->
    #{
        name     => Name,
        symcode  => Symcode,
        numcode  => Numcode,
        exponent => Exponent
    };

unmarshal(user_interaction, {redirect, {get_request,
    #'BrowserGetRequest'{uri = URI}
}}) ->
    #{type => redirect, content => {get, URI}};
unmarshal(user_interaction, {redirect, {post_request,
    #'BrowserPostRequest'{uri = URI, form = Form}
}}) ->
    #{type => redirect, content => {post, URI, Form}};


unmarshal(amount, V) ->
    unmarshal(integer, V);
unmarshal(string, V) when is_binary(V) ->
    V;
unmarshal(integer, V) when is_integer(V) ->
    V.

maybe_unmarshal(_Type, undefined) ->
    undefined;
maybe_unmarshal(Type, V) ->
    unmarshal(Type, V).

-spec marshal(ff_dmsl_codec:type_name(), ff_dmsl_codec:decoded_value()) ->
    ff_dmsl_codec:encoded_value().

marshal(cash, {Amount, CurrencyRef}) ->
    #domain_Cash{
        amount   = marshal(amount, Amount),
        currency = marshal(currency_ref, CurrencyRef)
    };
marshal(cash_range, {{BoundLower, CashLower}, {BoundUpper, CashUpper}}) ->
    #domain_CashRange{
        lower = {BoundLower, marshal(cash, CashLower)},
        upper = {BoundUpper, marshal(cash, CashUpper)}
    };
marshal(currency_ref, CurrencyID) when is_binary(CurrencyID) ->
    #domain_CurrencyRef{
        symbolic_code = CurrencyID
    };

marshal(currency, #{
    name     := Name,
    symcode  := Symcode,
    numcode  := Numcode,
    exponent := Exponent
}) ->
    #domain_Currency{
        name          = Name,
        symbolic_code = Symcode,
        numeric_code  = Numcode,
        exponent      = Exponent
    };

marshal(amount, V) ->
    marshal(integer, V);
marshal(string, V) when is_binary(V) ->
    V;
marshal(integer, V) when is_integer(V) ->
    V;

marshal(_, Other) ->
    Other.
