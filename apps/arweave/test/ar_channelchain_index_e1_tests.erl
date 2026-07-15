%%% E1 integration tests: admin / moderator operations on bundle items.
%%%
%%% Spec scenario I4:
%%%   admin delete を bundle 由来 item に対して実行 → 削除フラグが立つ
%%%
%%% Because D1 expands bundle items into the regular ETS index as
%%% pseudo TXs, the existing Admin-Delete / Moderator-Hide /
%%% Admin-Rewrite-Commit dispatch in index_single_tx triggers
%%% uniformly when the target TXID happens to be a bundle item id.
%%% These tests pin that invariant in place — any future regression
%%% would break admin moderation of bundle-delivered posts.

-module(ar_channelchain_index_e1_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

-define(TX_TAGS_TABLE,        channelchain_tx_tags).
-define(TX_INDEX_TABLE,       channelchain_tx_index).
-define(DELETED_TXS_TABLE,    channelchain_deleted_txs).
-define(TX_RECORDS_TABLE,     channelchain_tx_records).
-define(REWRITTEN_TXS_TABLE,  channelchain_rewritten_txs).
-define(SEEN_ITEMS_TABLE,     channelchain_seen_items).
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item).

e1_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [fun admin_delete_marks_bundle_item_deleted/0,
      fun moderator_hide_marks_bundle_item_deleted/0,
      fun board_moderator_hide_marks_bundle_item_deleted/0,
      fun admin_rewrite_redirects_bundle_item/0,
      fun delete_only_takes_effect_when_confirmed/0]}.

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

admin_delete_marks_bundle_item_deleted() ->
    ItemID = first_item_of_indexed_bundle(),
    ?assertNot(ar_channelchain_index:is_deleted(ItemID)),
    DeleteTX = admin_op_tx(<<"Admin-Delete">>, ItemID, <<"d1">>),
    ar_channelchain_index:maybe_index_tx(DeleteTX, confirmed),
    ?assert(ar_channelchain_index:is_deleted(ItemID)).

moderator_hide_marks_bundle_item_deleted() ->
    ItemID = first_item_of_indexed_bundle(),
    HideTX = admin_op_tx(<<"Moderator-Hide">>, ItemID, <<"m1">>),
    ar_channelchain_index:maybe_index_tx(HideTX, confirmed),
    ?assert(ar_channelchain_index:is_deleted(ItemID)).

board_moderator_hide_marks_bundle_item_deleted() ->
    ItemID = first_item_of_indexed_bundle(),
    HideTX = admin_op_tx(<<"Board-Moderator-Hide">>, ItemID, <<"bm1">>),
    ar_channelchain_index:maybe_index_tx(HideTX, confirmed),
    ?assert(ar_channelchain_index:is_deleted(ItemID)).

admin_rewrite_redirects_bundle_item() ->
    ItemID = first_item_of_indexed_bundle(),
    NewTxID = crypto:hash(sha256, <<"replacement-tx-for-bundle-item">>),
    CommitTX = #tx{
        id   = crypto:hash(sha256, <<"rewrite-commit-1">>),
        tags = [{<<"App-Name">>,        <<"ChannelChain">>},
                {<<"Type">>,            <<"Admin-Rewrite-Commit">>},
                {<<"Target-TX">>,       ItemID},
                {<<"Replacement-TX">>,  NewTxID}],
        data = <<>>
    },
    ar_channelchain_index:maybe_index_tx(CommitTX, confirmed),
    ?assert(ar_channelchain_index:is_rewritten(ItemID)),
    ?assertEqual(NewTxID, ar_channelchain_index:resolve_effective_tx(ItemID)).

%% Production gates delete/rewrite effects behind confirmed status.
%% An unconfirmed Admin-Delete must NOT yet mark the target deleted.
delete_only_takes_effect_when_confirmed() ->
    ItemID = first_item_of_indexed_bundle(),
    DeleteTX = admin_op_tx(<<"Admin-Delete">>, ItemID, <<"d-pending">>),
    ar_channelchain_index:maybe_index_tx(DeleteTX, unconfirmed),
    ?assertNot(ar_channelchain_index:is_deleted(ItemID)),
    ar_channelchain_index:maybe_index_tx(DeleteTX, confirmed),
    ?assert(ar_channelchain_index:is_deleted(ItemID)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

first_item_of_indexed_bundle() ->
    Carrier = bundle_carrier_tx(),
    ar_channelchain_index:maybe_index_tx(Carrier, confirmed),
    {ok, [I1, _I2]} = ar_bundle_parser:parse(Carrier#tx.data),
    ar_bundle_parser:item_id(I1).

bundle_carrier_tx() ->
    BundleBin = read_fixture("bundle_v2_cc.bin"),
    #tx{
        id        = crypto:hash(sha256, <<"e1-carrier">>),
        tags      = [{<<"App-Name">>, <<"ChannelChain">>},
                     {<<"Type">>, <<"Bundle">>}],
        data      = BundleBin,
        data_size = byte_size(BundleBin)
    }.

admin_op_tx(Type, TargetTxID, Salt) ->
    #tx{
        id   = crypto:hash(sha256, <<Type/binary, "-", Salt/binary>>),
        tags = [{<<"App-Name">>,  <<"ChannelChain">>},
                {<<"Type">>,      Type},
                {<<"Target-TX">>, TargetTxID}],
        data = <<>>
    }.

read_fixture(Name) ->
    Path = case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end,
    {ok, Bin} = file:read_file(Path),
    Bin.
