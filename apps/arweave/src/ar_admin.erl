%% ar_admin.erl
%%
%% 管理操作TX（削除、BAN等）の検証およびAdmin Pool残高管理

-module(ar_admin).

-export([validate_admin_tx/2, apply_admin_tx/2, get_admin_cost/1]).

-include_lib("arweave/include/ar.hrl").

%% 1 TOKEN = 1_000_000_000_000 winston
-define(ADMIN_DELETE_COST,    1000000000).  %% 0.001 TOKEN
-define(ADMIN_BAN_COST,      10000000000).  %% 0.01 TOKEN
-define(ADMIN_GRANT_COST,    50000000000).  %% 0.05 TOKEN
-define(ADMIN_REVOKE_COST,   50000000000).  %% 0.05 TOKEN

%% @doc Admin TXが適切な署名を持ち、Admin Pool（あるいは指定のアカウント）から手数料を払えるか検証
validate_admin_tx(TX, AdminAddresses) ->
	Type = get_tag(TX, <<"Type">>),
	case is_admin_type(Type) of
		true ->
			OwnerAddr = ar_tx:get_owner_address(TX),
			case lists:member(OwnerAddr, AdminAddresses) of
				true -> true;
				false -> false
			end;
		false ->
			true
	end.

is_admin_type(<<"Admin-Delete">>) -> true;
is_admin_type(<<"Admin-Ban">>) -> true;
is_admin_type(<<"Admin-Grant">>) -> true;
is_admin_type(<<"Admin-Revoke">>) -> true;
is_admin_type(_) -> false.

%% @doc Admin操作のコストを返す
get_admin_cost(<<"Admin-Delete">>) -> ?ADMIN_DELETE_COST;
get_admin_cost(<<"Admin-Ban">>) -> ?ADMIN_BAN_COST;
get_admin_cost(<<"Admin-Grant">>) -> ?ADMIN_GRANT_COST;
get_admin_cost(<<"Admin-Revoke">>) -> ?ADMIN_REVOKE_COST;
get_admin_cost(_) -> 0.

%% @doc 状態更新時のコスト差し引き
apply_admin_tx(TX, AdminPoolBalance) ->
	Type = get_tag(TX, <<"Type">>),
	Cost = get_admin_cost(Type),
	case AdminPoolBalance >= Cost of
		true -> {ok, AdminPoolBalance - Cost};
		false -> {error, insufficient_admin_funds}
	end.

get_tag(TX, TagName) ->
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false -> undefined
	end.
