%%% @doc Top-level validator for ChannelChain L2 bundle carrier TXs.
%%%
%%% validate_bundle/1 implements the §3 pipeline:
%%%
%%%   1. carrier tag check         (Bundle-Format / Bundle-Version /
%%%                                  App-Name / Type / Bundle-PoW-Nonce)
%%%   2. carrier PoW                (ar_bundle_verify:verify_carrier_pow)
%%%   3. parse                      (ar_bundle_parser:parse)
%%%   4. per-item verify            (ar_bundle_verify:verify_item)
%%%   5. pseudo TX synthesis        (#tx{} records compatible with the
%%%                                  rest of the chain)
%%%   6. ChannelChain semantic check (ar_bbs_validator:validate)
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

-define(DEFAULT_BUNDLE_POW_DIFFICULTY, 24).

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
            case lists:keyfind(<<"Bundle-PoW-Nonce">>, 1, Tags) of
                false ->
                    {error, missing_bundle_pow_nonce};
                {_, Nonce} ->
                    Difficulty = bundle_pow_difficulty(Opts),
                    case ar_bundle_verify:verify_carrier_pow(BundleBin, Nonce, Difficulty) of
                        ok -> {ok, BundleBin};
                        {error, _} = E -> E
                    end
            end
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
