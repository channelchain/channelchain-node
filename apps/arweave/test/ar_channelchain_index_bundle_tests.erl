%%% Tests for ar_channelchain_index bundle expansion (D1).
%%%
%%% Walks bundle carrier TXs through maybe_index_tx/2 and verifies:
%%%   - each item is registered in the regular tag/inverted tables,
%%%     so existing tag-based queries see bundle-derived posts as
%%%     equal citizens (I2 prerequisite);
%%%   - SEEN_ITEMS contains every accepted ItemID;
%%%   - BUNDLE_OF_ITEM stores the carrier id for each item (reverse
%%%     lookup needed by the admin layer in a later phase);
%%%   - re-applying the same carrier is idempotent (de-dup).

-module(ar_channelchain_index_bundle_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

-define(TX_TAGS_TABLE,        channelchain_tx_tags).
-define(TX_INDEX_TABLE,       channelchain_tx_index).
-define(DELETED_TXS_TABLE,    channelchain_deleted_txs).
-define(TX_RECORDS_TABLE,     channelchain_tx_records).
-define(REWRITTEN_TXS_TABLE,  channelchain_rewritten_txs).
-define(SEEN_ITEMS_TABLE,     channelchain_seen_items).
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item).

bundle_index_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [fun bundle_items_indexed/0,
      fun bundle_items_seen/0,
      fun bundle_of_item_reverse_lookup/0,
      fun bundle_dedup_on_reapply/0,
      fun non_bundle_tx_still_indexed/0]}.

setup() ->
    %% Mirror init/1's ETS layout — tests bypass the gen_server.
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

bundle_items_indexed() ->
    Carrier = bundle_carrier_tx(),
    ar_channelchain_index:maybe_index_tx(Carrier, unconfirmed),
    %% Both fixture items have App-Name = ChannelChain → 2 entries
    %% under {<<"App-Name">>, <<"ChannelChain">>} in the inverted index.
    AppNameMatches = ets:lookup(?TX_INDEX_TABLE,
                                {<<"App-Name">>, <<"ChannelChain">>}),
    ?assertEqual(2, length(AppNameMatches)),
    %% Both items are Posts.
    PostMatches = ets:lookup(?TX_INDEX_TABLE, {<<"Type">>, <<"Post">>}),
    ?assertEqual(2, length(PostMatches)),
    %% TX_TAGS_TABLE has the 2 item TXIDs (not the carrier).
    ItemIDs = item_ids(Carrier),
    [?assertNotEqual([], ets:lookup(?TX_TAGS_TABLE, Id)) || Id <- ItemIDs].

bundle_items_seen() ->
    Carrier = bundle_carrier_tx(),
    ar_channelchain_index:maybe_index_tx(Carrier, unconfirmed),
    [?assert(ar_channelchain_index:is_seen_item(Id))
     || Id <- item_ids(Carrier)].

bundle_of_item_reverse_lookup() ->
    Carrier = bundle_carrier_tx(),
    CarrierID = Carrier#tx.id,
    ar_channelchain_index:maybe_index_tx(Carrier, unconfirmed),
    [?assertEqual(CarrierID, ar_channelchain_index:bundle_of_item(Id))
     || Id <- item_ids(Carrier)].

bundle_dedup_on_reapply() ->
    Carrier = bundle_carrier_tx(),
    ar_channelchain_index:maybe_index_tx(Carrier, unconfirmed),
    InitialPosts = length(ets:lookup(?TX_INDEX_TABLE, {<<"Type">>, <<"Post">>})),
    %% Re-apply: SEEN_ITEMS already has the IDs, so no re-insertion.
    ar_channelchain_index:maybe_index_tx(Carrier, unconfirmed),
    AfterPosts = length(ets:lookup(?TX_INDEX_TABLE, {<<"Type">>, <<"Post">>})),
    ?assertEqual(InitialPosts, AfterPosts).

non_bundle_tx_still_indexed() ->
    %% Sanity: existing single-TX path is not regressed.
    TX = #tx{
        id = crypto:hash(sha256, <<"single-tx">>),
        tags = [{<<"App-Name">>, <<"ChannelChain">>},
                {<<"Type">>, <<"Post">>},
                {<<"Board-Id">>, <<"abc">>},
                {<<"Thread-Id">>, <<"def">>}],
        data = <<>>
    },
    ar_channelchain_index:maybe_index_tx(TX, unconfirmed),
    ?assertNotEqual([], ets:lookup(?TX_TAGS_TABLE, TX#tx.id)),
    %% Single TX should not be marked as a bundle item.
    ?assertNot(ar_channelchain_index:is_seen_item(TX#tx.id)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

bundle_carrier_tx() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    #tx{
        id        = crypto:hash(sha256, <<"d1-test-carrier">>),
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
