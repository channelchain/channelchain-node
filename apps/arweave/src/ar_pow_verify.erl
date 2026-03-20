-module(ar_pow_verify).

-export([validate_tx_pow/1, check_leading_zeros/2, get_current_difficulty/0]).

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
			Difficulty = get_current_difficulty(),
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

%% @doc Check if the hash has the required number of leading zero bits.
check_leading_zeros(Hash, Bits) ->
	case Hash of
		<<0:Bits, _/bits>> -> true;
		_ -> false
	end.
