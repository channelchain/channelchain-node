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

-export([start_link/0, add_tx/1, query/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").

%% ETS table names
-define(TX_TAGS_TABLE, channelchain_tx_tags).
-define(TX_INDEX_TABLE, channelchain_tx_index).
-define(APP_NAME, <<"ChannelChain">>).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Add a TX to the index (called when a new TX arrives).
add_tx(TX) when is_record(TX, tx) ->
    gen_server:cast(?MODULE, {add_tx, TX}).

%% @doc Query TXs by tag filters.
%% Filters is a map: #{"type" => "Board", "board_id" => "...", etc.}
query(Filters) ->
    gen_server:call(?MODULE, {query, Filters}, 10000).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    %% Create ETS tables (owned by this process)
    ets:new(?TX_TAGS_TABLE,
        [set, public, named_table, {read_concurrency, true}]),
    ets:new(?TX_INDEX_TABLE,
        [bag, public, named_table, {read_concurrency, true}]),
    %% Subscribe to tx events (new TX received by node)
    ar_events:subscribe(tx),
    %% Subscribe to block events (TX confirmed in block)
    ar_events:subscribe(block),
    %% Schedule initial index build from confirmed blocks
    gen_server:cast(self(), build_index),
    {ok, #{}}.

handle_call({query, Filters}, _From, State) ->
    Result = do_query(Filters),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({add_tx, TX}, State) ->
    maybe_index_tx(TX),
    {noreply, State};

handle_cast(build_index, State) ->
    %% Build index from confirmed TXs stored on disk.
    %% We scan the mempool and confirmed TX files.
    build_from_mempool(),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handle ar_events for new TXs
handle_info({event, tx, {new, TX, _Source}}, State) ->
    maybe_index_tx(TX),
    {noreply, State};

handle_info({event, tx, {ready_for_mining, TX}}, State) ->
    maybe_index_tx(TX),
    {noreply, State};

%% When a block is applied, index its confirmed TXs
handle_info({event, block, {new, B, _Source}}, State) ->
    lists:foreach(fun(TXID) ->
        case ar_storage:read_tx(TXID) of
            unavailable -> ok;
            TX -> maybe_index_tx(TX)
        end
    end, B#block.txs),
    {noreply, State};

handle_info({event, block, {orphaned, B}}, State) ->
    %% On orphan: remove TXs from the index
    lists:foreach(fun(TXID) ->
        remove_tx(TXID)
    end, B#block.txs),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Index a TX if it belongs to the ChannelChain app.
maybe_index_tx(TX) when is_record(TX, tx) ->
    Tags = TX#tx.tags,
    case get_tag_value(Tags, <<"App-Name">>) of
        ?APP_NAME ->
            TXID = TX#tx.id,
            %% Store {txid, tags}
            ets:insert(?TX_TAGS_TABLE, {TXID, Tags}),
            %% Build inverted index: {TagName, TagValue, TXID}
            lists:foreach(fun({Name, Value}) ->
                ets:insert(?TX_INDEX_TABLE, {{Name, Value}, TXID})
            end, Tags);
        _ ->
            ok
    end;
maybe_index_tx(_) ->
    ok.

%% @doc Remove a TX from the index.
remove_tx(TXID) ->
    case ets:lookup(?TX_TAGS_TABLE, TXID) of
        [] -> ok;
        [{TXID, Tags}] ->
            ets:delete(?TX_TAGS_TABLE, TXID),
            lists:foreach(fun({Name, Value}) ->
                ets:delete_object(?TX_INDEX_TABLE, {{Name, Value}, TXID})
            end, Tags)
    end.

%% @doc Build index from mempool (pending unconfirmed TXs).
build_from_mempool() ->
    PendingTXIDs = ar_mempool:get_all_txids(),
    lists:foreach(fun(TXID) ->
        case ar_mempool:get_tx(TXID) of
            not_found -> ok;
            TX -> maybe_index_tx(TX)
        end
    end, PendingTXIDs).

%% @doc Query the ETS index.
%% Returns a list of {TXID, Tags} matching all given filters.
do_query(Filters) ->
    TypeFilter = maps:get(<<"type">>, Filters, undefined),
    BoardId = maps:get(<<"board_id">>, Filters, undefined),
    ThreadId = maps:get(<<"thread_id">>, Filters, undefined),
    TargetTx = maps:get(<<"target_tx">>, Filters, undefined),
    First = maps:get(<<"first">>, Filters, 100),
    Sort = maps:get(<<"sort">>, Filters, <<"desc">>),

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
                txids_for_tag(<<"Type">>, <<"Moderator-Hide">>) ++
                txids_for_tag(<<"Type">>, <<"Moderator-Ban">>)
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

    %% Fetch tags for each TX ID
    WithTags = lists:filtermap(fun(TXID) ->
        case ets:lookup(?TX_TAGS_TABLE, TXID) of
            [{TXID, Tags}] -> {true, {TXID, Tags}};
            [] -> false
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
