-module(ar_pow_verify).

-export([validate_tx_pow/1, check_leading_zeros/2]).

-include_lib("arweave/include/ar.hrl").

%% The default difficulty parameter for PermaBoard PoW.
-define(DEFAULT_POW_DIFFICULTY, 16).

%% @doc Validates the PoW-Nonce tag for anonymous transactions.
validate_tx_pow(TX) ->
	case lists:keyfind(<<"PoW-Nonce">>, 1, TX#tx.tags) of
		false ->
			false;
		{<<"PoW-Nonce">>, NonceBin} ->
			DataBin = TX#tx.data,
			Input = <<DataBin/binary, NonceBin/binary>>,
			Hash = crypto:hash(sha256, Input),
			check_leading_zeros(Hash, ?DEFAULT_POW_DIFFICULTY)
	end.

%% @doc Check if the hash has the required number of leading zero bits.
check_leading_zeros(Hash, Bits) ->
	case Hash of
		<<0:Bits, _/bits>> -> true;
		_ -> false
	end.
