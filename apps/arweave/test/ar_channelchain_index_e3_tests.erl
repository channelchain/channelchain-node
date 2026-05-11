%%% E3 — cross-bundle de-duplication of repeated item ids (U11).
%%%
%%% docs/l2-bundle-chain-spec.md §8-1 U11:
%%%   de-dup: 同 ItemID を含む 2 つ目の bundle → 2 つ目は drop
%%%
%%% This is realised by D1's SEEN_ITEMS check inside index_bundle_tx.
%%% Two carrier TXs (different ids) wrapping the same item binary
%%% produce identical item ids; the second carrier must leave the
%%% first carrier's bookkeeping intact.

-module(ar_channelchain_index_e3_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

-define(TX_TAGS_TABLE,        channelchain_tx_tags).
-define(TX_INDEX_TABLE,       channelchain_tx_index).
-define(DELETED_TXS_TABLE,    channelchain_deleted_txs).
-define(TX_RECORDS_TABLE,     channelchain_tx_records).
-define(REWRITTEN_TXS_TABLE,  channelchain_rewritten_txs).
-define(SEEN_ITEMS_TABLE,     channelchain_seen_items).
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item).

e3_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [fun second_carrier_with_same_items_is_dropped/0,
      fun bundle_of_item_points_to_first_carrier/0,
      fun inverted_index_has_no_duplicates/0]}.

setup() ->
    [ets:new(T, [set, public, named_table])
     || T <- [?TX_TAGS_TABLE, ?DELETED_TXS_TABLE, ?TX_RECORDS_TABLE,
              ?REWRITTEN_TXS_TABLE, ?SEEN_ITEMS_TABLE, ?BUNDLE_OF_ITEM_TABLE]],
    ets:new(?TX_INDEX_TABLE, [bag, public, named_table]),
    ok.

teardown(_) ->
    [catch ets:delete(T)
     || T <- [?TX_TAGS_TABLE, ?TX_INDEX_TABLE, ?DELETED_TXS_TABLE,
              ?TX_RECORDS_TABLE, ?REWRITTEN_TXS_TABLE,
              ?SEEN_ITEMS_TABLE, ?BUNDLE_OF_ITEM_TABLE]],
    ok.

%%%-------------------------------------------------------------------
%%% Tests
%%%-------------------------------------------------------------------

second_carrier_with_same_items_is_dropped() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    CarrierA = carrier(<<"u11-A">>, BundleBin),
    CarrierB = carrier(<<"u11-B">>, BundleBin),  %% identical payload

    ar_channelchain_index:maybe_index_tx(CarrierA, confirmed),
    InitialSeen = length(ets:tab2list(?SEEN_ITEMS_TABLE)),

    ar_channelchain_index:maybe_index_tx(CarrierB, confirmed),
    AfterSeen = length(ets:tab2list(?SEEN_ITEMS_TABLE)),

    %% SEEN_ITEMS gained 2 entries from carrier A and zero from B.
    ?assertEqual(2, InitialSeen),
    ?assertEqual(2, AfterSeen).

bundle_of_item_points_to_first_carrier() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    CarrierA = carrier(<<"u11-first">>, BundleBin),
    CarrierB = carrier(<<"u11-second">>, BundleBin),

    ar_channelchain_index:maybe_index_tx(CarrierA, confirmed),
    ar_channelchain_index:maybe_index_tx(CarrierB, confirmed),

    {ok, Items} = ar_bundle_parser:parse(BundleBin),
    [?assertEqual(CarrierA#tx.id,
                  ar_channelchain_index:bundle_of_item(ar_bundle_parser:item_id(I)))
     || I <- Items].

inverted_index_has_no_duplicates() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    CarrierA = carrier(<<"u11-A2">>, BundleBin),
    CarrierB = carrier(<<"u11-B2">>, BundleBin),

    ar_channelchain_index:maybe_index_tx(CarrierA, confirmed),
    ar_channelchain_index:maybe_index_tx(CarrierB, confirmed),

    PostHits = ets:lookup(?TX_INDEX_TABLE, {<<"Type">>, <<"Post">>}),
    Ids = [TxID || {{_, _}, TxID} <- PostHits],
    %% 2 items, each present exactly once
    ?assertEqual(2, length(Ids)),
    ?assertEqual(lists:sort(Ids), lists:sort(lists:usort(Ids))).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

carrier(IdSalt, BundleBin) ->
    #tx{
        id        = crypto:hash(sha256, IdSalt),
        tags      = [{<<"App-Name">>, <<"ChannelChain">>},
                     {<<"Type">>, <<"Bundle">>}],
        data      = BundleBin,
        data_size = byte_size(BundleBin)
    }.

read_fixture(Name) ->
    Path = case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end,
    {ok, Bin} = file:read_file(Path),
    Bin.
