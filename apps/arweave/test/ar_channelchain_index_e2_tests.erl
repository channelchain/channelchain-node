%%% E2 integration tests: orphan handler unindexes bundle items (I5).
%%%
%%% docs/l2-bundle-chain-spec.md §8-2 I5:
%%%   reorg で bundle が orphan 化 → item が ETS から消える
%%%
%%% The orphan handler iterates over each TXID in the orphaned block
%%% and calls unindex_carrier/1 + remove_tx/1. unindex_carrier/1 uses
%%% the reverse BUNDLE_OF_ITEM index to discover every item delivered
%%% by the carrier and clears both the per-item tag/inverted entries
%%% and the bundle bookkeeping.

-module(ar_channelchain_index_e2_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

-define(TX_TAGS_TABLE,        channelchain_tx_tags).
-define(TX_INDEX_TABLE,       channelchain_tx_index).
-define(DELETED_TXS_TABLE,    channelchain_deleted_txs).
-define(TX_RECORDS_TABLE,     channelchain_tx_records).
-define(REWRITTEN_TXS_TABLE,  channelchain_rewritten_txs).
-define(SEEN_ITEMS_TABLE,     channelchain_seen_items).
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item).

-define(THREAD_ID, <<"11111111-1111-1111-1111-111111111111">>).

e2_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [fun orphan_removes_bundle_items_from_index/0,
      fun orphan_clears_seen_items_and_bundle_of_item/0,
      fun orphan_leaves_other_carrier_items_alone/0,
      fun unindex_carrier_noop_on_unknown_tx/0]}.

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

orphan_removes_bundle_items_from_index() ->
    Carrier = bundle_carrier_tx(<<"e2-c1">>),
    ar_channelchain_index:maybe_index_tx(Carrier, confirmed),
    Items = item_ids(Carrier),

    %% Pre-condition: items are queryable.
    [?assertNotEqual([], ets:lookup(?TX_TAGS_TABLE, Id)) || Id <- Items],

    %% Simulate the orphan path.
    ar_channelchain_index:unindex_carrier(Carrier#tx.id),

    %% Post-condition: per-item entries are gone from tag + inverted
    %% tables.
    [?assertEqual([], ets:lookup(?TX_TAGS_TABLE, Id)) || Id <- Items],
    PostHits = ets:lookup(?TX_INDEX_TABLE, {<<"Type">>, <<"Post">>}),
    HitIDs = [TxID || {{_, _}, TxID} <- PostHits],
    [?assertNot(lists:member(Id, HitIDs)) || Id <- Items],

    ThreadHits = ets:lookup(?TX_INDEX_TABLE, {<<"Thread-Id">>, ?THREAD_ID}),
    ThreadIDs = [TxID || {{_, _}, TxID} <- ThreadHits],
    [?assertNot(lists:member(Id, ThreadIDs)) || Id <- Items].

orphan_clears_seen_items_and_bundle_of_item() ->
    Carrier = bundle_carrier_tx(<<"e2-c2">>),
    ar_channelchain_index:maybe_index_tx(Carrier, confirmed),
    Items = item_ids(Carrier),
    [?assert(ar_channelchain_index:is_seen_item(Id)) || Id <- Items],

    ar_channelchain_index:unindex_carrier(Carrier#tx.id),

    [?assertNot(ar_channelchain_index:is_seen_item(Id)) || Id <- Items],
    [?assertEqual(undefined, ar_channelchain_index:bundle_of_item(Id))
     || Id <- Items].

%% Two carriers delivering the same fixture binary would produce the
%% same item ids, so we cannot use the same bundle. Instead we drive
%% the orphan path on a carrier with no items mapped to it and verify
%% another carrier's items survive.
orphan_leaves_other_carrier_items_alone() ->
    Survivor = bundle_carrier_tx(<<"e2-survivor">>),
    ar_channelchain_index:maybe_index_tx(Survivor, confirmed),
    SurvivorItems = item_ids(Survivor),

    %% Orphan an unrelated carrier id — items mapped to Survivor must
    %% NOT be touched.
    UnknownCarrier = crypto:hash(sha256, <<"unrelated-carrier-id">>),
    ar_channelchain_index:unindex_carrier(UnknownCarrier),

    [?assert(ar_channelchain_index:is_seen_item(Id)) || Id <- SurvivorItems],
    [?assertNotEqual([], ets:lookup(?TX_TAGS_TABLE, Id))
     || Id <- SurvivorItems].

unindex_carrier_noop_on_unknown_tx() ->
    UnknownTX = crypto:hash(sha256, <<"definitely-not-a-carrier">>),
    %% Must not crash, must not affect any table.
    ar_channelchain_index:unindex_carrier(UnknownTX),
    ?assertEqual([], ets:tab2list(?TX_TAGS_TABLE)),
    ?assertEqual([], ets:tab2list(?BUNDLE_OF_ITEM_TABLE)),
    ?assertEqual([], ets:tab2list(?SEEN_ITEMS_TABLE)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

bundle_carrier_tx(IdSalt) ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    #tx{
        id        = crypto:hash(sha256, IdSalt),
        tags      = [{<<"App-Name">>, <<"ChannelChain">>},
                     {<<"Type">>, <<"Bundle">>}],
        data      = BundleBin,
        data_size = byte_size(BundleBin)
    }.

item_ids(#tx{data = BundleBin}) ->
    {ok, Items} = ar_bundle_parser:parse(BundleBin),
    [ar_bundle_parser:item_id(I) || I <- Items].

read_fixture(Name) ->
    Path = case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end,
    {ok, Bin} = file:read_file(Path),
    Bin.
