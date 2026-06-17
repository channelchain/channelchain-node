-module(ar_join).

-export([start/1]).

%% Test helpers — exported so EUnit + ad-hoc verification can drive the
%% tombstone trust gate without spinning up a full JOIN.
-export([collect_trusted_deletions/2, is_admin_delete_authorising/2]).

-include("ar.hrl").
-include_lib("arweave_config/include/arweave_config.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Represents a process that handles downloading the block index and the latest
%%% blocks from the trusted peers, to initialize the node state.

%% The number of block index elements to fetch per request.
%% Must not exceed ?MAX_BLOCK_INDEX_RANGE_SIZE defined in ar_http_iface_middleware.erl.
%% ChannelChain runs production with AR_TEST defined for adjusted PoW parameters,
%% so we can't use upstream's tiny "2 per request" test value -- a fresh peer
%% joining a chain at height 10000+ would need 5000 round-trips and the gun
%% HTTP/2 client tends to drop the connection partway through. Use 1000, which
%% exercises pagination in tests while remaining usable for real joins.
-ifdef(AR_TEST).
-define(REQUEST_BLOCK_INDEX_RANGE_SIZE, 1000).
-else.
-define(REQUEST_BLOCK_INDEX_RANGE_SIZE, 10000).
-endif.

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start a process that will attempt to download the block index and the latest blocks.
start(Peers) ->
	spawn(fun() -> process_flag(trap_exit, true), start2(filter_peers(Peers)) end).

%%%===================================================================
%%% Private functions.
%%%===================================================================

filter_peers(Peers) ->
	filter_peers(Peers, []).

filter_peers([Peer | Peers], Peers2) ->
	case ar_http_iface_client:get_info(Peer, height) of
		info_unavailable ->
			?LOG_WARNING([{event, trusted_peer_unavailable},
					{peer, ar_util:format_peer(Peer)}]),
			filter_peers(Peers, Peers2);
		Height ->
			filter_peers(Peers, [{Height, Peer} | Peers2])
	end;
filter_peers([], []) ->
	[];
filter_peers([], Peers2) ->
	MaxHeight = lists:max([Height || {Height, _Peer} <- Peers2]),
	filter_peers2(Peers2, MaxHeight).

filter_peers2([], _MaxHeight) ->
	[];
filter_peers2([{Height, Peer} | Peers], MaxHeight) when MaxHeight - Height >= 5 ->
	?LOG_WARNING([{event, trusted_peer_five_or_more_blocks_behind},
			{peer, ar_util:format_peer(Peer)}]),
	filter_peers2(Peers, MaxHeight);
filter_peers2([{_Height, Peer} | Peers], MaxHeight) ->
	[Peer | filter_peers2(Peers, MaxHeight)].

start2([]) ->
	ar:console("~nTrusted peers are not available.~n", []),
	?LOG_WARNING([{event, not_joining}, {reason, trusted_peers_not_available}]),
	timer:sleep(1000),
	init:stop(1);
start2(Peers) ->
	ar:console("Joining the Arweave network...~n"),
	[{H, _, _} | _] = BI = get_block_index(Peers, ?REJOIN_RETRIES),
	ar:console("Downloaded the block index successfully.~n", []),
	B = get_block(Peers, H),
	ExpectedBIMerkleH = ar_unbalanced_merkle:block_index_to_merkle_root(tl(BI)),
	case B#block.hash_list_merkle of
		ExpectedBIMerkleH ->
			do_join(Peers, B, BI);
		_ ->
			{ok, Config} = arweave_config:get_env(),
			ID = binary_to_list(ar_util:encode(crypto:strong_rand_bytes(16))),
			File = filename:join(Config#config.data_dir,
					"inconsistent_joining_data_dump_" ++ ID),
			file:write_file(File, term_to_binary({B, Peers, BI})),
			ar:console("Inconsistent head block and block index. Error dump: ~s.", [File]),
			timer:sleep(2000),
			init:stop(1)
	end.

get_block_index(Peers, Retries) ->
	case get_block_index(Peers) of
		unavailable ->
			case Retries > 0 of
				true ->
					ar:console(
						"Failed to fetch the block index from any of the peers."
						" Retrying..~n"
					),
					?LOG_WARNING([{event, failed_to_fetch_block_index}]),
					timer:sleep(?REJOIN_TIMEOUT),
					get_block_index(Peers, Retries - 1);
				false ->
					ar:console(
						"Failed to fetch the block index from any of the peers. Giving up.."
						" Consider changing the peers.~n"
					),
					?LOG_ERROR([{event, failed_to_fetch_block_index}]),
					timer:sleep(1000),
					init:stop(1)
			end;
		BI ->
			BI
	end.

get_block_index([]) ->
	unavailable;
get_block_index([Peer | Peers]) ->
	case get_block_index2(Peer) of
		unavailable ->
			get_block_index(Peers);
		BI ->
			BI
	end.

get_block_index2(Peer) ->
	Height = ar_http_iface_client:get_info(Peer, height),
	get_block_index2(Peer, 0, Height, []).

get_block_index2(Peer, Start, Height, BI) ->
	N = ?REQUEST_BLOCK_INDEX_RANGE_SIZE,
	case ar_http_iface_client:get_block_index(Peer, min(Start, Height),
			min(Height, Start + N - 1)) of
		{ok, Range} when length(Range) < N ->
			case Start of
				0 ->
					Range;
				_ ->
					case lists:last(Range) == hd(BI) of
						true ->
							Range ++ tl(BI);
						false ->
							unavailable
					end
			end;
		{ok, Range} when length(Range) == N ->
			case Start of
				0 ->
					get_block_index2(Peer, Start + N - 1, Height, Range);
				_ ->
					case lists:last(Range) == hd(BI) of
						true ->
							get_block_index2(Peer, Start + N - 1, Height,
									Range ++ tl(BI));
						false ->
							unavailable
					end
			end;
		_ ->
			unavailable
	end.

get_block(Peers, H) ->
	case ar_storage:read_block(H) of
		unavailable ->
			get_block(Peers, H, 10);
		BShadow ->
			get_block(Peers, BShadow, BShadow#block.txs, [], 10)
	end.

get_block(Peers, H, Retries) ->
	ar:console("Downloading joining block ~s.~n", [ar_util:encode(H)]),
	case ar_http_iface_client:get_block_shadow(Peers, H) of
		{_Peer, #block{} = BShadow, _Time, _Size} ->
			get_block(Peers, BShadow, BShadow#block.txs, [], Retries);
		_ ->
			case Retries > 0 of
				true ->
					ar:console(
						"Failed to fetch a joining block ~s from any of the peers."
						" Retrying..~n", [ar_util:encode(H)]
					),
					?LOG_WARNING([
						{event, failed_to_fetch_joining_block},
						{block, ar_util:encode(H)}
					]),
					timer:sleep(1000),
					get_block(Peers, H, Retries - 1);
				false ->
					ar:console(
						"Failed to fetch a joining block ~s from any of the peers. Giving up.."
						" Consider changing the peers.~n", [ar_util:encode(H)]
					),
					?LOG_ERROR([
						{event, failed_to_fetch_joining_block},
						{block, ar_util:encode(H)}
					]),
					timer:sleep(1000),
					init:stop(1)
			end
	end.

get_block(_Peers, BShadow, [], TXs, _Retries) ->
	BShadow#block{ txs = lists:reverse(TXs) };
get_block(Peers, BShadow, [TXID | TXIDs], TXs, Retries) ->
	case ar_http_iface_client:get_tx(Peers, TXID) of
		#tx{} = TX ->
			get_block(Peers, BShadow, TXIDs, [TX | TXs], Retries);
		_ ->
			case Retries > 0 of
				true ->
					ar:console(
						"Failed to fetch a joining transaction ~s from any of the peers."
						" Retrying..~n", [ar_util:encode(TXID)]
					),
					?LOG_WARNING([
						{event, failed_to_fetch_joining_tx},
						{tx, ar_util:encode(TXID)}
					]),
					timer:sleep(1000),
					get_block(Peers, BShadow, [TXID | TXIDs], TXs, Retries - 1);
				false ->
					ar:console(
						"Failed to fetch a joining tx ~s from any of the peers. Giving up.."
						" Consider changing the peers.~n", [ar_util:encode(TXID)]
					),
					?LOG_ERROR([
						{event, failed_to_fetch_joining_tx},
						{block, ar_util:encode(TXID)}
					]),
					timer:sleep(1000),
					init:stop(1)
			end
	end.

%% @doc Perform the joining process.
do_join(Peers, B, BI) ->
	ar:console("Downloading the block trail.~n", []),
	{ok, Config} = arweave_config:get_env(),
	WorkerQ = queue:from_list([spawn(fun() -> worker() end)
			|| _ <- lists:seq(1, Config#config.join_workers)]),
	PeerQ = queue:from_list(Peers),
	Trail = lists:sublist(tl(BI), 2 * ar_block:get_max_tx_anchor_depth()),
	SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(B#block.txs, B#block.height),
	Retries = lists:foldl(fun(Peer, Acc) -> maps:put(Peer, 5, Acc) end, #{}, Peers),
	Blocks =
		try
			[B#block{ size_tagged_txs = SizeTaggedTXs }
					| get_block_trail(WorkerQ, PeerQ, Trail, Retries, B)]
		catch
			throw:{unauthorised_tombstone, _TXID} ->
				ar:console(
					"JOIN refused — one or more peers served a tombstone "
					"that no Admin-Delete tx in the trail authorises. "
					"Trying a different peer set is the recovery path.~n",
					[]),
				timer:sleep(1000),
				init:stop(1),
				receive after infinity -> ok end
		end,
	ar:console("Downloaded the block trail successfully.~n", []),
	Blocks2 = maybe_set_reward_history(Blocks, Peers),
	Blocks3 = maybe_set_block_time_history(Blocks2, Peers),
	ar_node_worker ! {join, B#block.height, BI, Blocks3},
	join_peers(Peers).

%% @doc Get the 2 * ar_block:get_max_tx_anchor_depth() blocks preceding the head block.
%% If the block list is shorter than 2 * ar_block:get_max_tx_anchor_depth(), simply
%% get all existing blocks.
%%
%% The node needs 2 * ar_block:get_max_tx_anchor_depth() block anchors so that it
%% can validate transactions even if it enters a ar_block:get_max_tx_anchor_depth()-deep
%% fork recovery (which is the deepest fork recovery possible) immediately after
%% joining the network.
get_block_trail(_WorkerQ, _PeerQ, [], _Retries, _TipBlock) ->
	[];
get_block_trail(WorkerQ, PeerQ, Trail, Retries, TipBlock) ->
	{WorkerQ2, PeerQ2} = request_blocks(Trail, WorkerQ, PeerQ),
	%% Carry the tip block in FetchState so collect_trusted_deletions
	%% can include its Admin-Delete txs in the trusted set without
	%% threading a new parameter through every receive clause.
	FetchState = #{ awaiting_block_count => length(Trail),
			tip_block => TipBlock },
	get_block_trail_loop(WorkerQ2, PeerQ2, Retries, Trail, FetchState).

request_blocks([], WorkerQ, PeerQ) ->
	{WorkerQ, PeerQ};
request_blocks([{H, _, _} | Trail], WorkerQ, PeerQ) ->
	{{value, W}, WorkerQ2} = queue:out(WorkerQ),
	{{value, Peer}, PeerQ2} = queue:out(PeerQ),
	W ! {get_block_shadow, H, Peer, self()},
	request_blocks(Trail, queue:in(W, WorkerQ2), queue:in(Peer, PeerQ2)).

get_block_trail_loop(WorkerQ, PeerQ, Retries, Trail, FetchState) ->
	receive
		{block_response, H, _Peer, #block{} = BShadow, Origin} ->
			case Origin of
				storage ->
					ok;
				_ ->
					ar_disk_cache:write_block_shadow(BShadow)
			end,
			TXCount = length(BShadow#block.txs),
			FetchState2 = maps:put(H, {BShadow, #{}, TXCount}, FetchState),
			AwaitingBlockCount = maps:get(awaiting_block_count, FetchState2),
			AwaitingBlockCount2 =
				case TXCount of
					0 ->
						?LOG_INFO([{event, join_remaining_blocks_to_fetch},
							{remaining_blocks_count, AwaitingBlockCount - 1}]),
						AwaitingBlockCount - 1;
					_ ->
						AwaitingBlockCount
				end,
			FetchState3 = maps:put(awaiting_block_count, AwaitingBlockCount2, FetchState2),
			{WorkerQ2, PeerQ2} = request_txs(H, BShadow#block.txs, WorkerQ, PeerQ),
			case AwaitingBlockCount2 of
				0 ->
					get_blocks(Trail, FetchState3);
				_ ->
					get_block_trail_loop(WorkerQ2, PeerQ2, Retries, Trail, FetchState3)
			end;
		{block_response, H, Peer, Response, peer} ->
			PeerRetries = maps:get(Peer, Retries),
			case PeerRetries > 0 of
				true ->
					ar:console("Failed to fetch a joining block ~s from ~s."
							" Retrying..~n", [ar_util:encode(H), ar_util:format_peer(Peer)]),
					?LOG_WARNING([
						{event, failed_to_fetch_joining_block},
						{block, ar_util:encode(H)},
						{peer, ar_util:format_peer(Peer)},
						{response, io_lib:format("~p", [Response])}
					]),
					timer:sleep(1000),
					Retries2 = maps:put(Peer, PeerRetries - 1, Retries),
					{WorkerQ2, PeerQ2} = request_block(H, WorkerQ, PeerQ),
					get_block_trail_loop(WorkerQ2, PeerQ2, Retries2, Trail, FetchState);
				false ->
					case queue:to_list(PeerQ) of
						[Peer] -> % The last peer left and it is out of attempts.
							ar:console(
								"Failed to fetch the joining headers from any of the peers, "
								"consider trying some other trusted peers.", []),
							?LOG_ERROR([{event, failed_to_join}]),
							timer:sleep(1000),
							init:stop(1);
						_ ->
							case queue:member(Peer, PeerQ) of
								false ->
									{WorkerQ2, PeerQ2} = request_block(H, WorkerQ, PeerQ),
									get_block_trail_loop(WorkerQ2, PeerQ2, Retries, Trail,
											FetchState);
								true ->
									PeerQ2 = queue:delete(Peer, PeerQ),
									ar:console("Failed to fetch a joining block ~s from ~s. "
											"Removing the peer from the queue..",
											[ar_util:encode(H), ar_util:format_peer(Peer)]),
									?LOG_ERROR([
										{event, failed_to_fetch_joining_block},
										{block, ar_util:encode(H)},
										{peer, ar_util:format_peer(Peer)},
										{response, io_lib:format("~p", [Response])}
									]),
									{WorkerQ2, PeerQ3} = request_block(H, WorkerQ, PeerQ2),
									get_block_trail_loop(WorkerQ2, PeerQ3, Retries, Trail,
											FetchState)
							end
					end
			end;
		{tx_response, H, TXID, _Peer, #tx{} = TX, Origin} ->
			case Origin of
				storage ->
					ok;
				_ ->
					ar_disk_cache:write_tx(TX)
			end,
			{BShadow, TXMap, AwaitingTXCount} = maps:get(H, FetchState),
			TXMap2 = maps:put(TXID, TX, TXMap),
			AwaitingTXCount2 = AwaitingTXCount - 1,
			FetchState2 = maps:put(H, {BShadow, TXMap2, AwaitingTXCount2}, FetchState),
			AwaitingBlockCount = maps:get(awaiting_block_count, FetchState2),
			AwaitingBlockCount2 =
				case AwaitingTXCount2 of
					0 ->
						?LOG_INFO([{event, join_remaining_blocks_to_fetch},
								{remaining_blocks_count, AwaitingBlockCount - 1}]),
						AwaitingBlockCount - 1;
					_ ->
						AwaitingBlockCount
				end,
			FetchState3 = maps:put(awaiting_block_count, AwaitingBlockCount2, FetchState2),
			case AwaitingBlockCount2 of
				0 ->
					get_blocks(Trail, FetchState3);
				_ ->
					get_block_trail_loop(WorkerQ, PeerQ, Retries, Trail, FetchState3)
			end;
		{tx_response, H, TXID, _Peer, {pending_tombstone, #tx{} = Stub}, peer} ->
			%% Same accounting as a regular tx_response, but the stub
			%% is wrapped so get_blocks/2 can cross-check it against
			%% the trail's Admin-Delete txs before unwrapping.
			{BShadow, TXMap, AwaitingTXCount} = maps:get(H, FetchState),
			TXMap2 = maps:put(TXID, {pending_tombstone, Stub}, TXMap),
			AwaitingTXCount2 = AwaitingTXCount - 1,
			FetchState2 = maps:put(H, {BShadow, TXMap2, AwaitingTXCount2}, FetchState),
			AwaitingBlockCount = maps:get(awaiting_block_count, FetchState2),
			AwaitingBlockCount2 =
				case AwaitingTXCount2 of
					0 -> AwaitingBlockCount - 1;
					_ -> AwaitingBlockCount
				end,
			FetchState3 = maps:put(awaiting_block_count, AwaitingBlockCount2, FetchState2),
			case AwaitingBlockCount2 of
				0 ->
					get_blocks(Trail, FetchState3);
				_ ->
					get_block_trail_loop(WorkerQ, PeerQ, Retries, Trail, FetchState3)
			end;
		{tx_response, H, TXID, Peer, Response, peer} ->
			PeerRetries = maps:get(Peer, Retries),
			case PeerRetries > 0 of
				true ->
					ar:console("Failed to fetch a joining transaction ~s from ~s. "
							"Retrying..~n", [ar_util:encode(TXID), ar_util:format_peer(Peer)]),
					?LOG_WARNING([{event, failed_to_fetch_joining_tx},
							{block, ar_util:encode(H)},
							{tx, ar_util:encode(TXID)},
							{peer, ar_util:format_peer(Peer)},
							{response, io_lib:format("~p", [Response])}]),
					timer:sleep(1000),
					Retries2 = maps:put(Peer, PeerRetries - 1, Retries),
					{WorkerQ2, PeerQ2} = request_tx(H, TXID, WorkerQ, PeerQ),
					get_block_trail_loop(WorkerQ2, PeerQ2, Retries2, Trail, FetchState);
				false ->
					case queue:to_list(PeerQ) of
						[Peer] -> % The last peer left and it is out of attempts.
							ar:console(
								"Failed to fetch the joining headers from any of the peers, "
								"consider trying some other trusted peers.", []),
							?LOG_ERROR([{event, failed_to_join}]),
							timer:sleep(1000),
							init:stop(1);
						_ ->
							case queue:member(Peer, PeerQ) of
								false ->
									{WorkerQ2, PeerQ2} = request_tx(H, TXID, WorkerQ, PeerQ),
									get_block_trail_loop(WorkerQ2, PeerQ2, Retries, Trail,
											FetchState);
								true ->
									PeerQ2 = queue:delete(Peer, PeerQ),
									ar:console("Failed to fetch a joining tx ~s from ~s. "
											"Removing the peer from the queue..",
											[ar_util:encode(TXID), ar_util:format_peer(Peer)]),
									?LOG_ERROR([
										{event, failed_to_fetch_joining_tx},
										{block, ar_util:encode(H)},
										{tx, ar_util:encode(TXID)},
										{peer, ar_util:format_peer(Peer)},
										{response, io_lib:format("~p", [Response])}
									]),
									{WorkerQ2, PeerQ3} = request_tx(H, TXID, WorkerQ, PeerQ2),
									get_block_trail_loop(WorkerQ2, PeerQ3, Retries, Trail,
											FetchState)
							end
					end
			end
	end.

request_txs(_H, [], WorkerQ, PeerQ) ->
	{WorkerQ, PeerQ};
request_txs(H, [TXID | TXIDs], WorkerQ, PeerQ) ->
	{WorkerQ2, PeerQ2} = request_tx(H, TXID, WorkerQ, PeerQ),
	request_txs(H, TXIDs, WorkerQ2, PeerQ2).

request_tx(H, TXID, WorkerQ, PeerQ) ->
	{{value, W}, WorkerQ2} = queue:out(WorkerQ),
	{{value, Peer}, PeerQ2} = queue:out(PeerQ),
	W ! {get_tx, H, TXID, Peer, self()},
	{queue:in(W, WorkerQ2), queue:in(Peer, PeerQ2)}.

get_blocks(Trail, FetchState) ->
	%% Build the trusted-deletions set from Admin-Delete txs that appear
	%% anywhere in the trail or the tip block. verify_tx_id alone is NOT
	%% enough to trust the deletion claim — the anonymous-tx acceptance
	%% path (258aeb29) lets a peer post a PoW-valid tx tagged
	%% Type=Admin-Delete with an arbitrary Target-TX. We must therefore
	%% require the same gate ar_node_worker enforces on incoming admin
	%% txs: a non-empty RSA signature whose owner address is in
	%% admin_addresses. The peer can't fake that (admin private key is
	%% not in their possession), so collect_trusted_deletions reduces
	%% peer trust to "the admin actually authorised this deletion".
	AdminAddresses = ar_admin:get_join_time_admin_addresses(),
	TipTXMap =
		case maps:find(tip_block, FetchState) of
			{ok, #block{} = B} -> block_txs_to_txmap(B);
			_ -> #{}
		end,
	TrustedDeletions = collect_trusted_deletions(
			AdminAddresses, [TipTXMap | trail_txmaps(Trail, FetchState)]),
	do_get_blocks(Trail, FetchState, TrustedDeletions).

%% @doc Walk the trail and pull each block's TXMap out of FetchState. A
%% missing entry would otherwise badkey-crash the foldl and bypass the
%% throw:{unauthorised_tombstone,_} catch in do_join/3, taking the
%% whole node down via an uncaught error.
trail_txmaps(Trail, FetchState) ->
	lists:filtermap(
		fun({H, _, _}) ->
			case maps:find(H, FetchState) of
				{ok, {_, TXMap, _}} -> {true, TXMap};
				error -> false
			end
		end, Trail).

%% @doc Turn the tip block's already-fetched #tx{} list into the same
%% TXID → TX shape used in FetchState's TXMaps, so collect_trusted_deletions
%% can scan it uniformly. The tip block is fetched separately by start2/1
%% (it carries the head block's txs in B#tx{}-records form) and never
%% enters the trail's get_block_trail_loop pipeline.
block_txs_to_txmap(#block{ txs = TXs }) ->
	lists:foldl(
		fun (#tx{ id = ID } = TX, Acc) -> maps:put(ID, TX, Acc);
			(_, Acc) -> Acc
		end, #{}, TXs).

collect_trusted_deletions(AdminAddresses, TXMaps) ->
	lists:foldl(
		fun(TXMap, Acc) ->
			maps:fold(
				fun (_TXID, TX, A) when is_record(TX, tx) ->
						case is_admin_delete_authorising(TX, AdminAddresses) of
							{true, Target} -> sets:add_element(Target, A);
							false -> A
						end;
				    (_, _, A) ->
						A
				end, Acc, TXMap)
		end, sets:new(), TXMaps).

%% @doc Return {true, TargetTXID} only when TX is a genuine Admin-Delete
%% authorised by an admin: it has the Type=Admin-Delete tag, a
%% well-formed 32-byte Target-TX, a non-empty signature (rejects the
%% PoW-only anonymous path entirely for admin actions), and the
%% recovered owner address is in admin_addresses. verify_tx_id earlier
%% in the JOIN fetch already validated the RSA signature when present,
%% so owner ∈ admin_addresses + signature =/= <<>> is a sufficient
%% proof of authorisation.
is_admin_delete_authorising(#tx{ tags = Tags } = TX, AdminAddresses) ->
	case lists:keyfind(<<"Type">>, 1, Tags) of
		{_, <<"Admin-Delete">>} ->
			case TX#tx.signature of
				<<>> ->
					false;
				_ ->
					case lists:keyfind(<<"Target-TX">>, 1, Tags) of
						{_, Encoded} ->
							case catch ar_util:decode(Encoded) of
								D when is_binary(D), byte_size(D) =:= 32 ->
									OwnerAddr = ar_tx:get_owner_address(TX),
									case lists:member(OwnerAddr, AdminAddresses) of
										true -> {true, D};
										false -> false
									end;
								_ -> false
							end;
						_ -> false
					end
			end;
		_ -> false
	end.

do_get_blocks([], _FetchState, _TrustedDeletions) ->
	[];
do_get_blocks([{H, _, _} | Trail], FetchState, TrustedDeletions) ->
	{B, TXMap, _} = maps:get(H, FetchState),
	TXs = [unwrap_tx(maps:get(TXID, TXMap), TXID, TrustedDeletions)
			|| TXID <- B#block.txs],
	SizeTaggedTXs = ar_block:generate_size_tagged_list_from_txs(TXs, B#block.height),
	[B#block{ txs = TXs, size_tagged_txs = SizeTaggedTXs }
			| do_get_blocks(Trail, FetchState, TrustedDeletions)].

unwrap_tx({pending_tombstone, #tx{} = Stub}, TXID, TrustedDeletions) ->
	case sets:is_element(TXID, TrustedDeletions) of
		true ->
			?LOG_INFO([{event, accepted_trail_verified_tombstone},
					{tx, ar_util:encode(TXID)}]),
			catch ar_storage:write_tombstone(Stub),
			Stub;
		false ->
			ar:console("A peer served a tombstone for tx ~s without an "
					"authorising Admin-Delete tx in the trail. "
					"Aborting JOIN.~n", [ar_util:encode(TXID)]),
			?LOG_ERROR([{event, rejected_unauthorised_tombstone},
					{tx, ar_util:encode(TXID)}]),
			%% Throw — caught in do_join/3 below, which then calls
			%% init:stop synchronously. init:stop is async so calling
			%% it directly here would let the foldl in
			%% generate_size_tagged_list_from_txs run past the
			%% non-tx return value and crash with badrecord.
			throw({unauthorised_tombstone, TXID})
	end;
unwrap_tx(#tx{} = TX, _TXID, _TrustedDeletions) ->
	TX.

request_block(H, WorkerQ, PeerQ) ->
	{{value, W}, WorkerQ2} = queue:out(WorkerQ),
	{{value, Peer}, PeerQ2} = queue:out(PeerQ),
	W ! {get_block_shadow, H, Peer, self()},
	{queue:in(W, WorkerQ2), queue:in(Peer, PeerQ2)}.

maybe_set_reward_history(Blocks, Peers) ->
	HeadB = hd(Blocks),
	ExpectedHashesLen = ar_rewards:expected_hashes_length(HeadB#block.height),
	ExpectedHashes = [B#block.reward_history_hash
			|| B <- lists:sublist(Blocks, ExpectedHashesLen)],
	case ar_http_iface_client:get_reward_history(Peers, HeadB, ExpectedHashes) of
		{ok, RewardHistory} ->
			ar_rewards:set_reward_history(Blocks, RewardHistory);
		_ ->
			ar:console("Failed to fetch the reward history for the block ~s from "
					"any of the peers. Consider changing the peers.~n",
					[ar_util:encode((hd(Blocks))#block.indep_hash)]),
			?LOG_WARNING([{event, failed_to_fetch_reward_history}]),
			timer:sleep(1000),
			init:stop(1)
	end.

maybe_set_block_time_history([#block{ height = Height } | _] = Blocks, Peers) ->
	case Height >= ar_fork:height_2_7() of
		true ->
			case ar_http_iface_client:get_block_time_history(
					Peers, hd(Blocks), ar_block_time_history:get_hashes(Blocks)) of
				{ok, BlockTimeHistory} ->
					ar_block_time_history:set_history(Blocks, BlockTimeHistory);
				_ ->
					ar:console("Failed to fetch the block time history for the block ~s from "
							"any of the peers. Consider changing the peers.~n",
							[ar_util:encode((hd(Blocks))#block.indep_hash)]),
					timer:sleep(1000),
					init:stop(1)
			end;
		false ->
			Blocks
	end.

join_peers(Peers) ->
	lists:foreach(
		fun(Peer) ->
			ar_http_iface_client:add_peer(Peer)
		end,
		Peers
	).

worker() ->
	receive
		{get_block_shadow, H, Peer, From} ->
			case ar_storage:read_block(H) of
				#block{} = B ->
					From ! {block_response, H, Peer, B, storage};
				unavailable ->
					case ar_http_iface_client:get_block_shadow([Peer], H) of
						{_, B, _, _} ->
							From ! {block_response, H, Peer, B, peer};
						Error ->
							From ! {block_response, H, Peer, Error, peer}
					end
			end,
			worker();
		{get_tx, H, TXID, Peer, From} ->
			case ar_storage:read_tx(TXID) of
				#tx{} = TX ->
					From ! {tx_response, H, TXID, Peer, TX, storage};
				unavailable ->
					case ar_http_iface_client:get_tx_from_remote_peer(Peer, TXID, true) of
						{{tombstone, Stub}, _, _, _} ->
							%% Park the stub in TXMap under a guarded
							%% wrapper. The trail validation pass
							%% before get_blocks/2 either unwraps it
							%% (Admin-Delete found in trail) or fails
							%% the JOIN.
							From ! {tx_response, H, TXID, Peer,
									{pending_tombstone, Stub}, peer};
						{TX, _, _, _} ->
							From ! {tx_response, H, TXID, Peer, TX, peer};
						Error ->
							From ! {tx_response, H, TXID, Peer, Error, peer}
					end
			end,
			worker()
	end.

%%%===================================================================
%%% Tests.
%%%===================================================================

%% @doc Check that nodes can join a running network by using the fork recoverer.
basic_node_join_test_() ->
	{timeout, ?TEST_NODE_TIMEOUT, fun() ->
		[B0] = ar_weave:init(),
		ar_test_node:start(B0),
		ar_test_node:mine(),
		ar_test_node:wait_until_height(main, 1),
		ar_test_node:mine(),
		ar_test_node:wait_until_height(main, 2),
		ar_test_node:join_on(#{ node => peer1, join_on => main }),
		ar_test_node:assert_wait_until_height(peer1, 2)
	end}.

%% @doc Ensure that both nodes can mine after a join.
node_join_test_() ->
	{timeout, ?TEST_NODE_TIMEOUT, fun() ->
		[B0] = ar_weave:init(),
		ar_test_node:start(B0),
		ar_test_node:mine(),
		ar_test_node:wait_until_height(main, 1),
		ar_test_node:mine(),
		ar_test_node:wait_until_height(main, 2),
		ar_test_node:join_on(#{ node => peer1, join_on => main }),
		ar_test_node:assert_wait_until_height(peer1, 2),
		ar_test_node:mine(peer1),
		ar_test_node:wait_until_height(main, 3)
	end}.

%% @doc Ensure that get_tx works with a single peer and a list of peers.
get_tx_test_() ->
	[
		ar_test_node:test_with_mocked_functions(
			[{ar_http_iface_client, get_tx_from_remote_peer,
				fun(_, _, _) -> {error,{closed,"The connection was lost."}} end}],
			fun test_get_tx/0)
	].

test_get_tx() ->
	?assertEqual(ar_http_iface_client:get_tx({127, 0, 0, 1, 1984}, <<"123">>), not_found),
	?assertEqual(ar_http_iface_client:get_tx([{127, 0, 0, 1, 1984}], <<"123">>), not_found),
	?assertEqual(ar_http_iface_client:get_tx(
		[{127, 0, 0, 1, 1984}, {127, 0, 0, 1, 1985}], <<"123">>), not_found).
