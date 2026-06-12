%%% @doc Top-level validator for ChannelChain L2 bundle carrier TXs.
%%%
%%% validate_bundle/1 implements the §3 pipeline:
%%%
%%%   1. carrier tag check          (Bundle-Format / Bundle-Version /
%%%                                   App-Name / Type)
%%%   2. acceptance path dispatch   (v1: Bundle-PoW-Nonce only)
%%%   3. carrier PoW                (ar_bundle_verify:verify_carrier_pow)
%%%   4. parse                      (ar_bundle_parser:parse)
%%%   5. per-item verify            (ar_bundle_verify:verify_item)
%%%   6. pseudo TX synthesis        (#tx{} records compatible with the
%%%                                  rest of the chain)
%%%   7. ChannelChain semantic check (ar_bbs_validator:validate)
%%%
%%% Any single item failure causes the whole carrier to be rejected
%%% (no partial acceptance, §3). The function returns {ok, [#tx{}]} on
%%% success — the caller (e.g. tx_validator hook in C2, index in D1)
%%% takes those pseudo TXs and treats them as if they had arrived
%%% individually.
%%%
%%% validate_bundle/2 takes Opts = [{difficulty, N},
%%%                                 {bundle_pow_difficulty, N},
%%%                                 {skip_bbs_validator, true}]
%%% to keep unit tests free of the live ETS difficulty / board-config
%%% dependencies.

-module(ar_bundle_validator).

-export([validate_bundle/1, validate_bundle/2, item_to_pseudo_tx/1]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_bundle.hrl").

-define(REQUIRED_CARRIER_TAGS, [
    {<<"App-Name">>,        <<"ChannelChain">>},
    {<<"Type">>,            <<"Bundle">>},
    {<<"Bundle-Format">>,   <<"binary">>},
    {<<"Bundle-Version">>,  <<"2.0.0">>}
]).

%% U1 default: 18. Lowered from 24 so the carrier-PoW cost per post,
%% even at a maxItems=1 sequencer batch, stays comparable to the
%% direct-submission item PoW (difficulty 20). A future revision can
%% scale difficulty with bundle size; for now the constant is the
%% knob.
-define(DEFAULT_BUNDLE_POW_DIFFICULTY, 18).
-define(RESERVED_CARRIER_TAGS, [
    <<"Committee-Cert">>,
    <<"Committee-Round">>,
    <<"Committee-Members">>
]).

-type opt() :: {difficulty, non_neg_integer()}              %% per-item PoW override
             | {bundle_pow_difficulty, non_neg_integer()}    %% carrier PoW override
             | {skip_bbs_validator, boolean()}.              %% test-only

-spec validate_bundle(#tx{}) -> {ok, [#tx{}]} | {error, term()}.
validate_bundle(Carrier) -> validate_bundle(Carrier, []).

-spec validate_bundle(#tx{}, [opt()]) -> {ok, [#tx{}]} | {error, term()}.
validate_bundle(#tx{} = Carrier, Opts) ->
    case verify_carrier(Carrier, Opts) of
        {error, _} = E -> E;
        {ok, BundleBin} ->
            case ar_bundle_parser:parse(BundleBin) of
                {error, Reason} ->
                    {error, {parse_failed, Reason}};
                {ok, Items} ->
                    process_items(Items, Opts)
            end
    end.

%%%-------------------------------------------------------------------
%%% Carrier-level checks
%%%-------------------------------------------------------------------

verify_carrier(#tx{tags = Tags, data = BundleBin}, Opts) ->
    case missing_required_tag(Tags) of
        {missing, T} -> {error, {carrier_missing_tag, T}};
        {wrong_value, T, V} -> {error, {carrier_wrong_tag_value, T, V}};
        ok ->
            case reserved_tag(Tags) of
                undefined ->
                    validate_acceptance_path(Tags, BundleBin, Opts);
                Tag ->
                    {error, {reserved_tag_used, Tag}}
            end
    end.

validate_acceptance_path(Tags, BundleBin, Opts) ->
    case acceptance_path(Tags) of
        {pow, Nonce} ->
            Difficulty = bundle_pow_difficulty(Opts),
            case ar_bundle_verify:verify_carrier_pow(BundleBin, Nonce, Difficulty) of
                ok -> {ok, BundleBin};
                {error, _} = E -> E
            end;
        {cert, _Cert} ->
            {error, cert_path_not_implemented_v1};
        none ->
            {error, no_acceptance_path}
    end.

missing_required_tag(Tags) ->
    missing_required_tag(?REQUIRED_CARRIER_TAGS, Tags).

missing_required_tag([], _Tags) -> ok;
missing_required_tag([{Name, Expected} | Rest], Tags) ->
    case lists:keyfind(Name, 1, Tags) of
        false              -> {missing, Name};
        {_, Expected}      -> missing_required_tag(Rest, Tags);
        {_, Other}         -> {wrong_value, Name, Other}
    end.

bundle_pow_difficulty(Opts) ->
    proplists:get_value(bundle_pow_difficulty, Opts, ?DEFAULT_BUNDLE_POW_DIFFICULTY).

acceptance_path(Tags) ->
    case {get_tag(<<"Bundle-PoW-Nonce">>, Tags),
          get_tag(<<"Committee-Cert">>, Tags)} of
        {Nonce, undefined} when Nonce =/= undefined -> {pow, Nonce};
        {_, Cert} when Cert =/= undefined -> {cert, Cert};
        {undefined, undefined} -> none
    end.

get_tag(Name, Tags) ->
    case lists:keyfind(Name, 1, Tags) of
        false -> undefined;
        {_, Value} -> Value
    end.

reserved_tag(Tags) ->
    reserved_tag(?RESERVED_CARRIER_TAGS, Tags).

reserved_tag([], _Tags) -> undefined;
reserved_tag([Name | Rest], Tags) ->
    case lists:keymember(Name, 1, Tags) of
        true -> Name;
        false -> reserved_tag(Rest, Tags)
    end.

%%%-------------------------------------------------------------------
%%% Item processing (§3 part 4..6)
%%%-------------------------------------------------------------------

process_items(Items, Opts) ->
    process_items(Items, Opts, []).

process_items([], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};
process_items([Item | Rest], Opts, Acc) ->
    case ar_bundle_verify:verify_item(Item, Opts) of
        {error, Reason} ->
            {error, {item_verify_failed, Item#bundle_item.id, Reason}};
        ok ->
            PseudoTX = item_to_pseudo_tx(Item),
            case maybe_run_bbs_validator(PseudoTX, Opts) of
                ok -> process_items(Rest, Opts, [PseudoTX | Acc]);
                {error, Reason} ->
                    {error, {bbs_validator_failed, Item#bundle_item.id, Reason}}
            end
    end.

maybe_run_bbs_validator(_PseudoTX, Opts) ->
    case proplists:get_value(skip_bbs_validator, Opts, false) of
        true  -> ok;
        false -> ar_bbs_validator:validate(_PseudoTX)
    end.

%%%-------------------------------------------------------------------
%%% Pseudo TX synthesis
%%%
%%% The synthesized #tx{} mirrors what a standalone format-2 TX
%%% carrying the same payload would look like — so downstream code
%%% (ar_bbs_validator, ar_channelchain_index, ar_admin) can treat
%%% bundle-derived items uniformly with directly-submitted TXs.
%%%-------------------------------------------------------------------

-spec item_to_pseudo_tx(#bundle_item{}) -> #tx{}.
item_to_pseudo_tx(#bundle_item{
        id        = Id,
        signature = Sig,
        owner     = Owner,
        target    = Target,
        tags      = Tags,
        data      = Data}) ->
    #tx{
        format     = 2,
        id         = Id,
        owner      = Owner,
        tags       = Tags,
        target     = case Target of undefined -> <<>>; _ -> Target end,
        data       = Data,
        data_size  = byte_size(Data),
        signature  = Sig
    }.
