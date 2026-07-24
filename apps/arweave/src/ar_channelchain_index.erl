%%% @doc ChannelChain TX タグインデックス
%%%
%%% ETSベースのインメモリタグインデックスを維持するgen_server。
%%% ノード起動時に既存TXをスキャンしてインデックスを構築し、
%%% ar_events経由で新着TXを受信してリアルタイムにインデックスを更新する。
%%%
%%% 提供するHTTPエンドポイント:
%%%   GET /channelchain/txs?type=Board&board_id=xxx&thread_id=xxx&first=N&sort=desc|asc
%%%   GET /channelchain/tx/{txid}/data

-module(ar_channelchain_index).

-behaviour(gen_server).

-export([start_link/0, add_tx/1, add_confirmed_tx/1, query/1, is_deleted/1, is_rewritten/1,
         resolve_effective_tx/1, get_replacement_tx/1,
         board_stats/1, thread_stats/1, is_build_index_complete/0,
         is_seen_item/1, bundle_of_item/1]).
%% Internal but exposed for tests so callers can exercise the bundle
%% expansion / orphan paths without spinning up the gen_server.
-export([maybe_index_tx/2, unindex_carrier/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").

%% ETS table names
-define(TX_TAGS_TABLE, channelchain_tx_tags).
-define(TX_INDEX_TABLE, channelchain_tx_index).
-define(DELETED_TXS_TABLE, channelchain_deleted_txs).
-define(TX_RECORDS_TABLE, channelchain_tx_records).  %% Full TX records for admin TXs
-define(REWRITTEN_TXS_TABLE, channelchain_rewritten_txs). %% {OldTXID, ReplacementTXID}
-define(STATE_TABLE, channelchain_index_state). %% Build-state flags consumed by callers
%% e.g. ar_http_iface_client's tombstone trust gate
-define(SEEN_ITEMS_TABLE, channelchain_seen_items).         %% ItemID → first-seen ts (ms)
-define(BUNDLE_OF_ITEM_TABLE, channelchain_bundle_of_item). %% ItemID → carrier TXID
-define(RECENT_TX_TABLE, channelchain_recent_tx_window).    %% TXID → indexed-at monotonic ms; feeds ar_pow_verify:count_recent_txs/0
-define(RECENT_TX_SWEEP_INTERVAL_MS, 300000).               %% 5 min — hygiene, not correctness
-define(RECENT_TX_MAX_AGE_MS, 1800000).                     %% 30 min — 3× the ar_pow_verify window; anything older is unambiguously expired
-define(APP_NAME, <<"ChannelChain">>).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Add a TX to the index (called when a new TX arrives).
add_tx(TX) when is_record(TX, tx) ->
    gen_server:cast(?MODULE, {add_tx, TX}).

%% @doc Add a confirmed TX to the index. Used by ar_header_sync when it
%% backfills a block that the post-JOIN build_index pass missed (the
%% block wasn't on disk yet when build_from_chain ran). Without this
%% incremental hook, an Admin-Delete tx in a backfilled block would
%% stay out of ?DELETED_TXS_TABLE and the legacy tombstone gate would
%% reject any tombstone for one of that block's other txs forever,
%% stalling the backfill.
add_confirmed_tx(TX) when is_record(TX, tx) ->
    gen_server:cast(?MODULE, {add_confirmed_tx, TX}).

%% @doc Query TXs by tag filters.
%% Filters is a map: #{"type" => "Board", "board_id" => "...", etc.}
query(Filters) ->
    gen_server:call(?MODULE, {query, Filters}, 10000).

%% @doc Check if a TX is marked as deleted.
is_deleted(TXID) ->
    ets:member(?DELETED_TXS_TABLE, TXID).

%% @doc Has build_index finished at least once since startup? Callers use
%% this as a race-free signal to switch their behaviour after the
%% channelchain replay populates the deletion / blacklist sets.
%% Returns false during early startup before the ets table exists.
is_build_index_complete() ->
    try ets:lookup(?STATE_TABLE, build_index_complete) of
        [{build_index_complete, true}] -> true;
        _ -> false
    catch _:_ -> false end.

%% @doc Check if a TX has been rewritten (replaced).
is_rewritten(TXID) ->
    ets:member(?REWRITTEN_TXS_TABLE, TXID).

%% @doc Resolve a TXID to its effective (replacement) TXID.
%% If the TX has been rewritten, returns the replacement TXID.
%% Otherwise returns the original TXID.
resolve_effective_tx(TXID) ->
    case ets:lookup(?REWRITTEN_TXS_TABLE, TXID) of
        [{TXID, ReplacementTXID}] -> ReplacementTXID;
        [] -> TXID
    end.

%% @doc Get the replacement TXID for a rewritten TX.
get_replacement_tx(TXID) ->
    case ets:lookup(?REWRITTEN_TXS_TABLE, TXID) of
        [{TXID, ReplacementTXID}] -> ReplacementTXID;
        [] -> undefined
    end.

%% @doc Has this bundle item ID already been accepted from any bundle?
-spec is_seen_item(binary()) -> boolean().
is_seen_item(ItemID) -> ets:member(?SEEN_ITEMS_TABLE, ItemID).

%% @doc Reverse lookup: which carrier bundle TX delivered this item?
-spec bundle_of_item(binary()) -> binary() | undefined.
bundle_of_item(ItemID) ->
    case ets:lookup(?BUNDLE_OF_ITEM_TABLE, ItemID) of
        [{ItemID, CarrierID}] -> CarrierID;
        []                    -> undefined
    end.

%% @doc Get stats (thread_count, post_count) for a board, filtering deleted/closed.
board_stats(BoardId) ->
    gen_server:call(?MODULE, {board_stats, BoardId}, 10000).

%% @doc Get post_count for a thread, filtering deleted.
thread_stats(ThreadId) ->
    gen_server:call(?MODULE, {thread_stats, ThreadId}, 10000).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    %% Create ETS tables (owned by this process)
    ets:new(?TX_TAGS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?TX_INDEX_TABLE,
        [bag, public, named_table, {read_concurrency, true}]),
    ets:new(?DELETED_TXS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?TX_RECORDS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?REWRITTEN_TXS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?STATE_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?SEEN_ITEMS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?BUNDLE_OF_ITEM_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    %% Fable Alpha-UX (2026-07-24): time-windowed successor to the
    %% "ETS table size proxy" that ar_pow_verify:count_recent_txs/0
    %% used to consult. Storing {TXID, MonotonicMs} lets the PoW
    %% classifier fall back from HIGH_LOAD to LOW_LOAD naturally
    %% once a burst ends, instead of latching high forever because
    %% the cumulative table size never shrinks. Hygiene sweeper
    %% (handle_info(recent_tx_sweep, ...)) prunes anything past
    %% RECENT_TX_MAX_AGE_MS so the table cannot grow without bound.
    ets:new(?RECENT_TX_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    erlang:send_after(?RECENT_TX_SWEEP_INTERVAL_MS, self(), recent_tx_sweep),
    %% Subscribe to tx events (new TX received by node)
    ar_events:subscribe(tx),
    %% Subscribe to block events (TX confirmed in block)
    ar_events:subscribe(block),
    %% Subscribe to node_state so we can rebuild the index after a JOIN
    %% finishes — blocks applied via ar_node_worker's join path do not
    %% fire {block, {new, _, _}}, so the Admin-Delete hook would miss
    %% every historical Admin-Delete tx in the trail otherwise.
    ar_events:subscribe(node_state),
    %% Schedule initial index build from confirmed blocks
    gen_server:cast(self(), build_index),
    {ok, #{}}.

handle_call({query, Filters}, _From, State) ->
    Result = do_query(Filters),
    {reply, Result, State};

handle_call({board_stats, BoardId}, _From, State) ->
    Result = do_board_stats(BoardId),
    {reply, Result, State};

handle_call({thread_stats, ThreadId}, _From, State) ->
    Result = do_thread_stats(ThreadId),
    {reply, Result, State};

handle_call({board_thread_post_counts, BoardId}, _From, State) ->
    Result = board_thread_post_counts(BoardId),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({add_tx, TX}, State) ->
    maybe_index_tx(TX, unconfirmed),
    {noreply, State};

handle_cast({add_confirmed_tx, TX}, State) ->
    maybe_index_tx(TX, confirmed),
    {noreply, State};

handle_cast(build_index, State) ->
    %% Build index from confirmed TXs stored on disk.
    %% We scan the mempool and confirmed TX files.
    build_from_mempool(),
    build_from_chain(),
    %% Mark replay as complete IFF we actually replayed a non-empty
    %% chain. The init/1 cast runs before JOIN downloads any blocks,
    %% so the very first invocation typically finds an empty
    %% block_index — flipping the flag at that point would let the
    %% post-JOIN tombstone gate switch from "defer" to "reject"
    %% before any blocks have been written, mis-rejecting trail
    %% tombstones for txs whose authorising Admin-Delete just
    %% hasn't been processed yet. We only mark complete once
    %% there is a chain to replay; the post-JOIN cast_after pair
    %% in handle_info({initialized,_}) ensures we re-enter here
    %% with a populated block_index.
    case ets:info(?TX_TAGS_TABLE, size) of
        N when is_integer(N), N > 0 ->
            ets:insert(?STATE_TABLE, {build_index_complete, true});
        _ ->
            ok
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handle ar_events for new TXs (unconfirmed — no rewrite/delete effects)
handle_info({event, tx, {new, TX, _Source}}, State) ->
    maybe_index_tx(TX, unconfirmed),
    {noreply, State};

handle_info({event, tx, {ready_for_mining, TX}}, State) ->
    maybe_index_tx(TX, unconfirmed),
    {noreply, State};

%% When a block is applied, index its confirmed TXs (with rewrite/delete effects)
handle_info({event, block, {new, B, _Source}}, State) ->
    lists:foreach(fun(TXID) ->
        case ar_storage:read_tx(TXID) of
            unavailable -> ok;
            TX -> maybe_index_tx(TX, confirmed)
        end
    end, B#block.txs),
    {noreply, State};

handle_info({event, block, {orphaned, B}}, State) ->
    %% On orphan: remove TXs from the index. Each TXID may be either
    %% a bundle carrier (in which case all of its expanded items need
    %% to be unindexed) or a regular TX. unindex_carrier/1 is a no-op
    %% when the TXID has no items mapped to it, so calling both is
    %% safe and uniform.
    lists:foreach(fun(TXID) ->
        unindex_carrier(TXID),
        remove_tx(TXID)
    end, B#block.txs),
    {noreply, State};

handle_info({event, node_state, {initialized, _B}}, State) ->
    %% The {initialized, _} event fires before block headers settle on
    %% disk after a JOIN — calling build_index here immediately finds
    %% an empty block index. Defer a few seconds.
    ar_util:cast_after(5000, self(), build_index),
    %% And again later, in case the chain was still backfilling.
    ar_util:cast_after(20000, self(), build_index),
    {noreply, State};

handle_info({event, node_state, _}, State) ->
    {noreply, State};

%% Fable Alpha-UX (2026-07-24): periodic hygiene sweep for the
%% recent-tx window ETS. Deletes entries older than
%% RECENT_TX_MAX_AGE_MS (30 min, 3× the 10-min ar_pow_verify
%% window) so the table cannot grow without bound in a long-lived
%% node. Reschedules itself so it survives crashes at the timer
%% level (each fire schedules the next).
handle_info(recent_tx_sweep, State) ->
    Cutoff = erlang:monotonic_time(millisecond) - ?RECENT_TX_MAX_AGE_MS,
    %% ets:select_delete/2 traversal, atomic per-entry. The '$2' is
    %% the MonotonicMs; matches entries with ts < Cutoff.
    Match = [{{'$1', '$2'}, [{'<', '$2', Cutoff}], [true]}],
    _Dropped = ets:select_delete(?RECENT_TX_TABLE, Match),
    erlang:send_after(?RECENT_TX_SWEEP_INTERVAL_MS, self(), recent_tx_sweep),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Index a TX if it belongs to the ChannelChain app.
%% Status: confirmed | unconfirmed. Deletion/rewrite effects only apply when confirmed.
%% Bundle carriers (Type=Bundle) are expanded into one pseudo TX per item;
%% each pseudo TX is indexed via the regular path so downstream queries
%% cannot tell bundle-derived posts apart from directly-submitted ones.
maybe_index_tx(TX, Status) when is_record(TX, tx) ->
    Tags = TX#tx.tags,
    case get_tag_value(Tags, <<"App-Name">>) of
        ?APP_NAME ->
            case get_tag_value(Tags, <<"Type">>) of
                <<"Bundle">> -> index_bundle_tx(TX, Status);
                _            -> index_single_tx(TX, Status)
            end;
        _ ->
            ok
    end;
maybe_index_tx(_, _) ->
    ok.

index_single_tx(TX, Status) ->
    Tags = TX#tx.tags,
    TXID = TX#tx.id,
    Type = get_tag_value(Tags, <<"Type">>),

    %% Deletion and rewrite effects only on confirmed TXs
    case Status of
        confirmed ->
            %% If it's a deletion TX, mark the target as deleted
            IsDeleteType = (Type =:= <<"Admin-Delete">> orelse
                           Type =:= <<"Moderator-Hide">> orelse
                           Type =:= <<"Board-Moderator-Hide">> orelse
                           Type =:= <<"Self-Delete">>),
            case IsDeleteType of
                true ->
                    case get_tag_value(Tags, <<"Target-TX">>) of
                        undefined -> ok;
                        TargetTXID ->
                            ets:insert(?DELETED_TXS_TABLE, {TargetTXID, true}),
                            case Type of
                                <<"Admin-Delete">> ->
                                    %% Target-TX is base64url-encoded;
                                    %% blacklist expects raw binary.
                                    case catch ar_util:decode(TargetTXID) of
                                        Decoded when is_binary(Decoded),
                                                     byte_size(Decoded) =:= 32 ->
                                            ar_tx_blacklist:blacklist_txs([Decoded]);
                                        _ ->
                                            ?LOG_WARNING([{event,
                                                    channelchain_admin_delete_bad_target},
                                                    {target, TargetTXID}])
                                    end;
                                _ ->
                                    ok
                            end
                    end;
                false ->
                    ok
            end,
            %% If it's a rewrite commit TX, map old TX → replacement TX
            case Type of
                <<"Admin-Rewrite-Commit">> ->
                    OldTxId = get_tag_value(Tags, <<"Target-TX">>),
                    NewTxId = get_tag_value(Tags, <<"Replacement-TX">>),
                    case OldTxId =/= undefined andalso NewTxId =/= undefined of
                        true -> ets:insert(?REWRITTEN_TXS_TABLE, {OldTxId, NewTxId});
                        false -> ok
                    end;
                _ ->
                    ok
            end;
        unconfirmed ->
            ok
    end,

    %% Store {txid, tags}
    ets:insert(?TX_TAGS_TABLE, {TXID, Tags}),
    %% Fable Alpha-UX (2026-07-24): record insertion time for
    %% ar_pow_verify:count_recent_txs/0's 10-min window. Deleted
    %% below when the TX is removed (unindex_tx).
    ets:insert(?RECENT_TX_TABLE, {TXID, erlang:monotonic_time(millisecond)}),
    %% Store full TX record for privileged TXs (needed by ar_admin state rebuild)
    case ar_admin:is_admin_tx(TX) of
        true -> ets:insert(?TX_RECORDS_TABLE, {TXID, TX});
        false -> ok
    end,
    %% Build inverted index: {TagName, TagValue, TXID}
    lists:foreach(fun({Name, Value}) ->
        ets:insert(?TX_INDEX_TABLE, {{Name, Value}, TXID})
    end, Tags).

%% Expand a bundle carrier TX into pseudo TXs and index each.
%% Validation has already happened upstream (ar_bbs_validator →
%% ar_bundle_validator) so we trust the binary at this point and only
%% need to parse it.
index_bundle_tx(CarrierTX, Status) ->
    case ar_bundle_parser:parse(CarrierTX#tx.data) of
        {ok, Items} ->
            CarrierID = CarrierTX#tx.id,
            lists:foreach(fun(Item) ->
                ItemID = ar_bundle_parser:item_id(Item),
                case ets:lookup(?SEEN_ITEMS_TABLE, ItemID) of
                    [] ->
                        ets:insert(?SEEN_ITEMS_TABLE,
                                   {ItemID, erlang:system_time(millisecond)}),
                        ets:insert(?BUNDLE_OF_ITEM_TABLE, {ItemID, CarrierID}),
                        PseudoTX = ar_bundle_validator:item_to_pseudo_tx(Item),
                        index_single_tx(PseudoTX, Status);
                    _ ->
                        %% De-dup: same ItemID already accepted from
                        %% an earlier bundle, ignore.
                        ok
                end
            end, Items);
        {error, _} ->
            %% Should not happen post-validation; tolerate gracefully
            %% (e.g. corrupted block re-import).
            ok
    end.

%% @doc Remove a TX from the index.
%% Also cleans up deletion markers and TX records created by the removed TX.
remove_tx(TXID) ->
    case ets:lookup(?TX_TAGS_TABLE, TXID) of
        [] -> ok;
        [{TXID, Tags}] ->
            %% If this TX was a deletion TX, remove the deletion marker it created
            Type = get_tag_value(Tags, <<"Type">>),
            IsDeleteType = (Type =:= <<"Admin-Delete">> orelse
                            Type =:= <<"Moderator-Hide">> orelse
                            Type =:= <<"Board-Moderator-Hide">> orelse
                            Type =:= <<"Self-Delete">>),
            case IsDeleteType of
                true ->
                    case get_tag_value(Tags, <<"Target-TX">>) of
                        undefined -> ok;
                        TargetTXID -> ets:delete(?DELETED_TXS_TABLE, TargetTXID)
                    end;
                false ->
                    ok
            end,
            %% If this TX was a rewrite commit, remove the rewrite mapping
            case Type of
                <<"Admin-Rewrite-Commit">> ->
                    case get_tag_value(Tags, <<"Target-TX">>) of
                        undefined -> ok;
                        RewriteTargetTXID -> ets:delete(?REWRITTEN_TXS_TABLE, RewriteTargetTXID)
                    end;
                _ ->
                    ok
            end,
            %% Remove admin TX record if stored
            ets:delete(?TX_RECORDS_TABLE, TXID),
            %% Remove tags and inverted index entries
            ets:delete(?TX_TAGS_TABLE, TXID),
            ets:delete(?RECENT_TX_TABLE, TXID),
            lists:foreach(fun({Name, Value}) ->
                ets:delete_object(?TX_INDEX_TABLE, {{Name, Value}, TXID})
            end, Tags)
    end.

%% @doc Reverse-lookup all bundle items whose carrier is `CarrierID`
%% and unindex each one. Removes per-item tag entries from the
%% regular tables and the bundle bookkeeping (SEEN_ITEMS,
%% BUNDLE_OF_ITEM). No-op when no items map to CarrierID.
-spec unindex_carrier(binary()) -> ok.
unindex_carrier(CarrierID) ->
    %% ets:match returns [[ItemID], ...] for the matching ItemID column.
    ItemIDs = case ets:info(?BUNDLE_OF_ITEM_TABLE) of
        undefined -> [];
        _ -> [Id || [Id] <- ets:match(?BUNDLE_OF_ITEM_TABLE, {'$1', CarrierID})]
    end,
    lists:foreach(fun(ItemID) ->
        remove_tx(ItemID),
        catch ets:delete(?SEEN_ITEMS_TABLE, ItemID),
        catch ets:delete(?BUNDLE_OF_ITEM_TABLE, ItemID)
    end, ItemIDs),
    ok.

%% @doc Build index from mempool (pending unconfirmed TXs).
build_from_mempool() ->
    PendingTXIDs = ar_mempool:get_all_txids(),
    lists:foreach(fun(TXID) ->
        case ar_mempool:get_tx(TXID) of
            not_found -> ok;
            TX -> maybe_index_tx(TX, unconfirmed)
        end
    end, PendingTXIDs).

%% @doc Build index from confirmed blocks.
build_from_chain() ->
    case catch ar_storage:read_block_index() of
        {'EXIT', _} -> ok;
        not_found -> ok;
        BlockIndex when is_list(BlockIndex) ->
            lists:foreach(
                fun(BlockRef) ->
                    case ar_storage:read_block(BlockRef) of
                        unavailable -> ok;
                        #block{txs = TXs} ->
                            lists:foreach(fun(TXID) ->
                                case ar_storage:read_tx(TXID) of
                                    unavailable -> ok;
                                    TX -> maybe_index_tx(TX, confirmed)
                                end
                            end, TXs)
                    end
                end,
                lists:reverse(BlockIndex)
            )
    end.

%% @doc Query the ETS index.
%% Returns a list of {TXID, Tags} matching all given filters.
do_query(Filters) ->
    TypeFilter = maps:get(<<"type">>, Filters, undefined),
    BoardId = maps:get(<<"board_id">>, Filters, undefined),
    ThreadId = maps:get(<<"thread_id">>, Filters, undefined),
    TargetTx = maps:get(<<"target_tx">>, Filters, undefined),
    First = maps:get(<<"first">>, Filters, 100),
    Sort = maps:get(<<"sort">>, Filters, <<"desc">>),
    IncludeClosed = maps:get(<<"include_closed">>, Filters, false),

    %% Start from the smallest result set (most selective filter first)
    InitialSet = case TypeFilter of
        undefined ->
            %% Return all ChannelChain TXs
            all_txids();
        <<"Admin-Op">> ->
            lists:usort(
                txids_for_tag(<<"Type">>, <<"Admin-Delete">>) ++
                txids_for_tag(<<"Type">>, <<"Admin-Ban">>) ++
                txids_for_tag(<<"Type">>, <<"Admin-Grant">>) ++
                txids_for_tag(<<"Type">>, <<"Admin-Revoke">>) ++
                txids_for_tag(<<"Type">>, <<"Admin-Board-Close">>) ++
                txids_for_tag(<<"Type">>, <<"Moderator-Hide">>) ++
                txids_for_tag(<<"Type">>, <<"Moderator-Ban">>) ++
                txids_for_tag(<<"Type">>, <<"Board-Moderator-Hide">>) ++
                txids_for_tag(<<"Type">>, <<"Board-Moderator-Ban">>) ++
                txids_for_tag(<<"Type">>, <<"User-Grant">>) ++
                txids_for_tag(<<"Type">>, <<"User-Revoke">>) ++
                txids_for_tag(<<"Type">>, <<"Self-Delete">>)
            );
        <<"Moderator-Op">> ->
            lists:usort(
                txids_for_tag(<<"Type">>, <<"Moderator-Hide">>) ++
                txids_for_tag(<<"Type">>, <<"Moderator-Ban">>)
            );
        Type ->
            txids_for_tag(<<"Type">>, Type)
    end,

    %% Apply additional filters
    Filtered1 = case BoardId of
        undefined -> InitialSet;
        BId ->
            BoardSet = txids_for_tag(<<"Board-Id">>, BId),
            sets:to_list(sets:intersection(
                sets:from_list(InitialSet),
                sets:from_list(BoardSet)
            ))
    end,

    Filtered2 = case ThreadId of
        undefined -> Filtered1;
        TId ->
            ThreadSet = txids_for_tag(<<"Thread-Id">>, TId),
            sets:to_list(sets:intersection(
                sets:from_list(Filtered1),
                sets:from_list(ThreadSet)
            ))
    end,

    Filtered3 = case TargetTx of
        undefined -> Filtered2;
        Tgt ->
            TargetSet = txids_for_tag(<<"Target-TX">>, Tgt),
            sets:to_list(sets:intersection(
                sets:from_list(Filtered2),
                sets:from_list(TargetSet)
            ))
    end,

    %% Fetch tags for each TX ID.
    %% Priority: rewrite > delete. A rewritten TX is shown as its replacement
    %% even if the original was Admin-Deleted (delete → rewrite workflow).
    %% Replacement TXs appearing in their own position are excluded (no duplicates).
    ReplacementTXIDs = sets:from_list([
        RepId || {_OldId, RepId} <- ets:tab2list(?REWRITTEN_TXS_TABLE)
    ]),
    WithTags = lists:filtermap(fun(TXID) ->
        %% First check if this TX is a replacement TX in its own position → skip
        case sets:is_element(TXID, ReplacementTXIDs) of
            true -> false;
            false ->
                %% Check rewrite BEFORE delete — rewrite takes priority
                case ets:lookup(?REWRITTEN_TXS_TABLE, TXID) of
                    [{TXID, ReplacementTXID}] ->
                        %% Rewritten: substitute with replacement TX
                        case ets:lookup(?TX_TAGS_TABLE, ReplacementTXID) of
                            [{ReplacementTXID, Tags}] ->
                                EffTags = [{<<"Rewritten-From">>, TXID} | Tags],
                                apply_board_filter(TypeFilter, IncludeClosed, ReplacementTXID, Tags, EffTags);
                            [] -> false
                        end;
                    [] ->
                        %% Not rewritten: check if deleted
                        case ets:member(?DELETED_TXS_TABLE, TXID) of
                            true -> false;
                            false ->
                                case ets:lookup(?TX_TAGS_TABLE, TXID) of
                                    [{TXID, Tags}] ->
                                        apply_board_filter(TypeFilter, IncludeClosed, TXID, Tags, Tags);
                                    [] -> false
                                end
                        end
                end
        end
    end, Filtered3),

    %% Sort by insertion order (we use a simple ordering based on ETS)
    %% For now, preserve the found order and apply sort+limit
    Sorted = case Sort of
        <<"asc">> -> lists:reverse(WithTags);
        _ -> WithTags
    end,

    lists:sublist(Sorted, First).

%% @doc Get all indexed TX IDs.
%% @doc Apply board-closed filter. Returns {true, {TXID, Tags}} or false.
apply_board_filter(TypeFilter, IncludeClosed, TXID, RawTags, EffTags) ->
    case TypeFilter of
        <<"Admin-Op">> -> {true, {TXID, EffTags}};
        <<"Moderator-Op">> -> {true, {TXID, EffTags}};
        _ ->
            case IncludeClosed of
                true -> {true, {TXID, EffTags}};
                false ->
                    BoardIdFromTags = get_tag_value(RawTags, <<"Board-Id">>),
                    case BoardIdFromTags =/= undefined andalso ar_admin:is_board_closed(BoardIdFromTags) of
                        true -> false;
                        false -> {true, {TXID, EffTags}}
                    end
            end
    end.

all_txids() ->
    [TXID || {TXID, _Tags} <- ets:tab2list(?TX_TAGS_TABLE)].

%% @doc Get TX IDs that have a given tag name=value.
txids_for_tag(Name, Value) ->
    Matches = ets:lookup(?TX_INDEX_TABLE, {Name, Value}),
    [TXID || {{_N, _V}, TXID} <- Matches].

%% @doc Get a tag value by name from a tag list.
get_tag_value([], _Name) -> undefined;
get_tag_value([{Name, Value} | _], Name) -> Value;
get_tag_value([_ | Tags], Name) -> get_tag_value(Tags, Name).

%% @doc Compute board stats (thread_count, post_count) efficiently.
%% Filters out deleted and closed-board items.
do_board_stats(BoardId) ->
    BoardTXIDs = txids_for_tag(<<"Board-Id">>, BoardId),
    ThreadCount = count_active(BoardTXIDs, <<"Thread">>),
    PostCount = count_active(BoardTXIDs, <<"Post">>),
    #{thread_count => ThreadCount, post_count => PostCount}.

count_active(BoardTXIDs, Type) ->
    TypeTXIDs = txids_for_tag(<<"Type">>, Type),
    Intersection = sets:to_list(sets:intersection(
        sets:from_list(BoardTXIDs), sets:from_list(TypeTXIDs))),
    %% Collect replacement TXIDs to exclude from count (avoid double-counting)
    RepSet = sets:from_list([
        RepId || {_OldId, RepId} <- ets:tab2list(?REWRITTEN_TXS_TABLE)
    ]),
    lists:foldl(fun(TXID, Acc) ->
        case ets:member(?DELETED_TXS_TABLE, TXID) of
            true -> Acc;
            false ->
                %% Skip replacement TXs (they replace a rewritten TX, not a new post)
                case sets:is_element(TXID, RepSet) of
                    true -> Acc;
                    false -> Acc + 1
                end
        end
    end, 0, Intersection).

%% @doc Compute thread stats (post_count) efficiently.
do_thread_stats(ThreadId) ->
    ThreadTXIDs = txids_for_tag(<<"Thread-Id">>, ThreadId),
    PostCount = count_active(ThreadTXIDs, <<"Post">>),
    #{post_count => PostCount}.

%% @doc Compute post counts for all threads under a board.
%% Returns a map: #{ThreadId => PostCount}.
board_thread_post_counts(BoardId) ->
    BoardTXIDs = sets:from_list(txids_for_tag(<<"Board-Id">>, BoardId)),
    PostTXIDs = sets:from_list(txids_for_tag(<<"Type">>, <<"Post">>)),
    BoardPosts = sets:to_list(sets:intersection(BoardTXIDs, PostTXIDs)),
    RepSet2 = sets:from_list([
        RepId || {_OldId, RepId} <- ets:tab2list(?REWRITTEN_TXS_TABLE)
    ]),
    lists:foldl(fun(TXID, Acc) ->
        case ets:member(?DELETED_TXS_TABLE, TXID) of
            true -> Acc;
            false ->
                case sets:is_element(TXID, RepSet2) of
                    true -> Acc;
                    false ->
                        case ets:lookup(?TX_TAGS_TABLE, TXID) of
                            [{TXID, Tags}] ->
                                case get_tag_value(Tags, <<"Thread-Id">>) of
                                    undefined -> Acc;
                                    TId -> maps:put(TId, maps:get(TId, Acc, 0) + 1, Acc)
                                end;
                            [] -> Acc
                        end
                end
        end
    end, #{}, BoardPosts).
