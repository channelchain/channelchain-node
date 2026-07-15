%%% D3 integration tests for ar_channelchain_index.
%%%
%%% Spec scenarios:
%%%   I1  bundle TX → mine → ETS expansion: each item is queryable
%%%       through the regular tag inverted index.
%%%   I2  Standalone anonymous TXs and bundle-derived items appear
%%%       together in a Thread-Id query (i.e. callers cannot tell
%%%       them apart at the index level).
%%%
%%% These tests bypass the gen_server, mining, and ar_events plumbing
%%% (those require a full chain node). The point here is to verify
%%% the index transformation that happens once a bundle TX has been
%%% accepted: the per-item tag entries appear correctly.

-module(ar_channelchain_index_d3_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

-define(TX_TAGS_TABLE,        channelchain_tx_tags).
-define(TX_INDEX_TABLE,       channelchain_tx_index).
-define(DELETED_TXS_TABLE,    channelchain_deleted_txs).
-define(TX_RECORDS_TABLE,     channelchain_tx_records).
-define(REWRITTEN_TXS_TABLE,  channelchain_rewritten_txs).
-define(SEEN_ITEMS_TABLE,     channelchain_seen_items).
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item).

%% Bundle fixture is signed against this Thread-Id; see
%% test/fixtures/bundle_v2_gen.mjs.
-define(THREAD_ID, <<"11111111-1111-1111-1111-111111111111">>).
-define(BOARD_ID,  <<"00000000-0000-0000-0000-000000000001">>).

d3_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [fun i1_confirmed_bundle_indexed/0,
      fun i2_mixed_thread_query/0,
      fun carrier_not_indexed_as_post/0]}.

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
%%% I1: confirmed bundle expands into the ETS index
%%%-------------------------------------------------------------------

i1_confirmed_bundle_indexed() ->
    Carrier = bundle_carrier_tx(),
    %% Mining is the production trigger for confirmed status; here we
    %% short-circuit by passing confirmed directly.
    ar_channelchain_index:maybe_index_tx(Carrier, confirmed),

    ItemIDs = item_ids(Carrier),
    ?assertEqual(2, length(ItemIDs)),

    %% Each item is queryable by Thread-Id (the index that drives
    %% thread page rendering).
    ThreadHits = ets:lookup(?TX_INDEX_TABLE, {<<"Thread-Id">>, ?THREAD_ID}),
    HitTXIDs = [TXID || {{_, _}, TXID} <- ThreadHits],
    [?assert(lists:member(Id, HitTXIDs)) || Id <- ItemIDs].

%%%-------------------------------------------------------------------
%%% I2: bundle items + standalone TX in the same thread
%%%-------------------------------------------------------------------

i2_mixed_thread_query() ->
    StandaloneTX = standalone_post_tx(),
    Carrier      = bundle_carrier_tx(),

    %% Index both — order should not matter.
    ar_channelchain_index:maybe_index_tx(StandaloneTX, unconfirmed),
    ar_channelchain_index:maybe_index_tx(Carrier,      unconfirmed),

    ThreadHits = ets:lookup(?TX_INDEX_TABLE, {<<"Thread-Id">>, ?THREAD_ID}),
    HitTXIDs = [TXID || {{_, _}, TXID} <- ThreadHits],

    %% Standalone + 2 bundle items = 3 unique TXIDs under the
    %% Thread-Id inverted index.
    ?assertEqual(3, length(lists:usort(HitTXIDs))),
    ?assert(lists:member(StandaloneTX#tx.id, HitTXIDs)),
    [?assert(lists:member(Id, HitTXIDs)) || Id <- item_ids(Carrier)],

    %% Standalone is NOT recorded as a bundle item.
    ?assertNot(ar_channelchain_index:is_seen_item(StandaloneTX#tx.id)),
    %% Each bundle item's reverse lookup points at the carrier.
    [?assertEqual(Carrier#tx.id,
                  ar_channelchain_index:bundle_of_item(Id))
     || Id <- item_ids(Carrier)].

%%%-------------------------------------------------------------------
%%% The carrier itself must not appear as a Post — it is a Bundle.
%%%-------------------------------------------------------------------

carrier_not_indexed_as_post() ->
    Carrier = bundle_carrier_tx(),
    ar_channelchain_index:maybe_index_tx(Carrier, confirmed),

    PostHits = [TXID || {{_, _}, TXID}
                        <- ets:lookup(?TX_INDEX_TABLE,
                                      {<<"Type">>, <<"Post">>})],
    ?assertNot(lists:member(Carrier#tx.id, PostHits)),
    %% The carrier's id should not even be in TX_TAGS — bundle TX
    %% carriers leave no per-item-shaped entry in the regular tables.
    ?assertEqual([], ets:lookup(?TX_TAGS_TABLE, Carrier#tx.id)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

bundle_carrier_tx() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    #tx{
        id        = crypto:hash(sha256, <<"d3-test-carrier">>),
        tags      = [{<<"App-Name">>, <<"ChannelChain">>},
                     {<<"Type">>, <<"Bundle">>}],
        data      = BundleBin,
        data_size = byte_size(BundleBin)
    }.

%% A regular anonymous Post TX (the kind ChannelChain accepts directly
%% via ar_pow_verify) sharing the same thread as the bundle items.
standalone_post_tx() ->
    #tx{
        id        = crypto:hash(sha256, <<"d3-standalone-post">>),
        tags      = [{<<"App-Name">>,    <<"ChannelChain">>},
                     {<<"Type">>,        <<"Post">>},
                     {<<"Board-Id">>,    ?BOARD_ID},
                     {<<"Thread-Id">>,   ?THREAD_ID},
                     {<<"PoW-Nonce">>,   <<"0">>}],
        data      = <<"{\"body\":\"standalone\",\"name\":\"\"}">>,
        data_size = 32
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
