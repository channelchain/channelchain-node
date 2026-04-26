-module(ar_pow_verify).

-export([validate_tx_pow/1, check_leading_zeros/2, get_current_difficulty/0, get_difficulty_for_board/1]).

-include_lib("arweave/include/ar.hrl").

%% The default/base difficulty parameter for ChannelChain PoW.
-define(DEFAULT_POW_DIFFICULTY, 20).

%% Dynamic difficulty thresholds (TX count in recent window).
-define(HIGH_LOAD_THRESHOLD, 500).
-define(MED_LOAD_THRESHOLD, 100).
-define(LOW_LOAD_THRESHOLD, 10).

%% Difficulty values per load level.
-define(HIGH_LOAD_DIFFICULTY, 24).  %% ~30 sec
-define(MED_LOAD_DIFFICULTY, 22).   %% ~10 sec
-define(NORMAL_DIFFICULTY, 20).     %% ~3 sec
-define(LOW_LOAD_DIFFICULTY, 16).   %% ~0.5 sec

%% Window size for dynamic adjustment (number of recent TXs to consider).
-define(DIFFICULTY_WINDOW_SIZE, 100).
-define(DIFFICULTY_WINDOW_SECONDS, 600). %% 10 minutes

%% @doc Validates the PoW-Nonce tag for anonymous transactions.
%% Uses dynamic difficulty based on recent network load.
validate_tx_pow(TX) ->
	case lists:keyfind(<<"PoW-Nonce">>, 1, TX#tx.tags) of
		false ->
			false;
		{<<"PoW-Nonce">>, NonceBin} ->
			DataBin = TX#tx.data,
			Input = <<DataBin/binary, NonceBin/binary>>,
			Hash = crypto:hash(sha256, Input),
			%% Check for board-specific difficulty
			BoardId = case lists:keyfind(<<"Board-Id">>, 1, TX#tx.tags) of
				{<<"Board-Id">>, BId} -> BId;
				false -> undefined
			end,
			TxType = case lists:keyfind(<<"Type">>, 1, TX#tx.tags) of
				{<<"Type">>, T} -> T;
				false -> undefined
			end,
			Difficulty = case TxType of
				<<"Report">> -> get_report_difficulty(BoardId);
				_ -> get_difficulty_for_board(BoardId)
			end,
			check_leading_zeros(Hash, Difficulty)
	end.

%% @doc Returns the current effective PoW difficulty based on recent TX rate.
%% Exposed via /info for SDK clients to adjust their PoW computation.
get_current_difficulty() ->
	RecentCount = count_recent_txs(),
	%% Scale: per-10-minute window
	if
		RecentCount > ?HIGH_LOAD_THRESHOLD -> ?HIGH_LOAD_DIFFICULTY;
		RecentCount > ?MED_LOAD_THRESHOLD  -> ?MED_LOAD_DIFFICULTY;
		RecentCount > ?LOW_LOAD_THRESHOLD  -> ?NORMAL_DIFFICULTY;
		true                               -> ?LOW_LOAD_DIFFICULTY
	end.

%% @doc Count TXs indexed in the recent time window.
count_recent_txs() ->
	try
		%% Use the ETS channelchain_tx_tags table size as a proxy
		%% for recent TX activity. In a production system this would
		%% track per-window counts, but ETS table size is a reasonable
		%% approximation for the current single-session dev chain.
		ets:info(channelchain_tx_tags, size)
	catch
		_:_ -> 0
	end.

%% @doc Get difficulty for a specific board.
%% pow_difficulty is a percentage coefficient: 100 = default, 50 = half, 200 = double.
%% Minimum difficulty is 4.
get_difficulty_for_board(undefined) ->
	get_current_difficulty();
get_difficulty_for_board(BoardId) ->
	BaseDifficulty = get_current_difficulty(),
	case ar_admin:get_board_config(BoardId, <<"pow_difficulty">>) of
		undefined -> BaseDifficulty;
		ValBin ->
			try
				Pct = binary_to_integer(ValBin),
				max(BaseDifficulty * Pct div 100, 4)
			catch _:_ -> BaseDifficulty
			end
	end.

%% @doc Get report difficulty for a specific board.
%% report_pow_difficulty is a percentage coefficient: 100 = same as post, 50 = half of post.
%% Default is 50% of post difficulty. Minimum 4.
get_report_difficulty(undefined) ->
	max(get_current_difficulty() div 2, 4);
get_report_difficulty(BoardId) ->
	PostDifficulty = get_difficulty_for_board(BoardId),
	case ar_admin:get_board_config(BoardId, <<"report_pow_difficulty">>) of
		undefined -> max(PostDifficulty div 2, 4);
		ValBin ->
			try
				Pct = binary_to_integer(ValBin),
				max(PostDifficulty * Pct div 100, 4)
			catch _:_ -> max(PostDifficulty div 2, 4)
			end
	end.

%% @doc Check if the hash has the required number of leading zero bits.
check_leading_zeros(Hash, Bits) ->
	case Hash of
		<<0:Bits, _/bits>> -> true;
		_ -> false
	end.
