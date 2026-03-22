-module(ar_inflation).

-export([calculate/1, blocks_per_year/1, calculate_reward/2, process_donation/2]).

-include_lib("arweave/include/ar.hrl").

-define(GENESIS_ENDOWMENT,  85000000000000).  %% 85M TOKEN (winston単位)
-define(ADMIN_POOL,          5000000000000).  %% 5M TOKEN
-define(BLOCK_REWARD,              1000000).  %% 1 TOKEN/ブロック（基金から） - 1 AR is 1_000_000_000_000 winston. Wait, the spec says 1,000,000 winston.
-define(INFLATION_REWARD,           100000).  %% 0.1 TOKEN/ブロック（新規発行）
-define(HALVING_INTERVAL,           525600).  %% 約1年ごとに半減（2分/ブロック想定）

%% @doc Return the inflation reward for a given block height.
calculate(Height) ->
	Halvings = Height div ?HALVING_INTERVAL,
	?INFLATION_REWARD bsr Halvings.

%% @doc Return the expected number of blocks per year.
blocks_per_year(_Height) ->
	?HALVING_INTERVAL.

%% @doc Calculate minor reward and return {TotalReward, NewEndowmentPool}
calculate_reward(Height, EndowmentPool) ->
	%% 1. 基金からの支給（枯渇するまで）
	EndowmentReward = case EndowmentPool > ?BLOCK_REWARD of
		true  -> ?BLOCK_REWARD;
		false -> EndowmentPool  %% 残り全額
	end,

	%% 2. インフレーション発行（半減あり）
	Halvings = Height div ?HALVING_INTERVAL,
	InflationReward = ?INFLATION_REWARD bsr Halvings,  %% 右シフトで半減

	%% 合計報酬
	TotalReward = EndowmentReward + InflationReward,
	NewEndowment = EndowmentPool - EndowmentReward,
	{TotalReward, NewEndowment}.

%% @doc 寄付受付: 特殊タグ "Donation" 付きTXをEndowmentに加算
process_donation(TX, EndowmentPool) ->
	case get_tag(TX, <<"Type">>) of
		<<"Donation">> ->
			Amount = TX#tx.quantity,
			EndowmentPool + Amount;
		_ ->
			EndowmentPool
	end.

get_tag(TX, TagName) ->
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false -> undefined
	end.
