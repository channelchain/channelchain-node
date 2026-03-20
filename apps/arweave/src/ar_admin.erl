%% ar_admin.erl
%%
%% 権限付きTXの権限検証、および Admin Pool / ロール状態管理

-module(ar_admin).

-export([
	is_admin_tx/1,
	validate_admin_tx/1,
	validate_admin_tx/2,
	validate_block_txs/1,
	apply_admin_txs/2,
	get_admin_cost/1,
	get_admin_addresses/0,
	get_wallet_roles/0,
	get_wallet_capabilities/0,
	get_admin_pool_balance/0,
	get_closed_boards/0,
	is_board_closed/1,
	initial_state_entries/0,
	current_state_entries/0,
	refresh_state/0
]).

-include_lib("arweave/include/ar.hrl").

-define(ADMIN_DELETE_COST,    1000000000).   %% 0.001 TOKEN
-define(ADMIN_BAN_COST,      10000000000).   %% 0.01 TOKEN
-define(ADMIN_GRANT_COST,    50000000000).   %% 0.05 TOKEN
-define(ADMIN_REVOKE_COST,   50000000000).   %% 0.05 TOKEN
-define(ADMIN_BOARD_CLOSE_COST, 100000000000). %% 0.1 TOKEN
-define(MODERATOR_HIDE_COST,  1000000000).   %% 0.001 TOKEN
-define(MODERATOR_BAN_COST,  10000000000).   %% 0.01 TOKEN
-define(DEFAULT_GENESIS_CONFIG_PATH, "config/genesis_block.json").

-define(ROLE_ADMIN, <<"admin">>).
-define(ROLE_MODERATOR, <<"moderator">>).

-define(CAP_HIDE_POST, <<"can_hide_post">>).
-define(CAP_BAN_USER, <<"can_ban_user">>).
-define(CAP_MANAGE_ROLES, <<"can_manage_roles">>).

validate_admin_tx(TX) ->
	validate_admin_tx(TX, {get_admin_addresses(), get_wallet_roles()}).

%% 既存の呼び出し箇所ではこの関数名を使い続けるが、
%% 実際には admin / moderator の両方の権限付きTXを対象にする。
is_admin_tx(TX) ->
	is_privileged_type(get_tag(TX, <<"Type">>)).

validate_admin_tx(TX, {AdminAddresses, WalletRoles}) ->
	Type = get_tag(TX, <<"Type">>),
	case is_privileged_type(Type) of
		false ->
			true;
		true ->
			case has_valid_privileged_payload(TX, Type) of
				false ->
					false;
				true ->
					OwnerAddr = ar_tx:get_owner_address(TX),
					Capabilities = get_capabilities_for_address(
						OwnerAddr,
						AdminAddresses,
						WalletRoles
					),
					case required_capability(Type) of
						undefined ->
							false;
						Capability ->
							lists:member(Capability, Capabilities)
					end
			end
	end.

validate_block_txs(TXs) ->
	{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards} = current_state(),
	case apply_admin_txs(TXs, {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}) of
		{ok, _NextState} ->
			ok;
		Error ->
			Error
	end.

get_admin_cost(<<"Admin-Delete">>) -> ?ADMIN_DELETE_COST;
get_admin_cost(<<"Admin-Ban">>) -> ?ADMIN_BAN_COST;
get_admin_cost(<<"Admin-Grant">>) -> ?ADMIN_GRANT_COST;
get_admin_cost(<<"Admin-Revoke">>) -> ?ADMIN_REVOKE_COST;
get_admin_cost(<<"Admin-Board-Close">>) -> ?ADMIN_BOARD_CLOSE_COST;
get_admin_cost(<<"Moderator-Hide">>) -> ?MODERATOR_HIDE_COST;
get_admin_cost(<<"Moderator-Ban">>) -> ?MODERATOR_BAN_COST;
get_admin_cost(_) -> 0.

apply_admin_txs(TXs, {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}) ->
	TXs2 = normalize_txs(TXs),
	lists:foldl(
		fun
			(_TX, {error, _} = Error) ->
				Error;
			(TX, {ok, {Addresses, Roles, Balance, Boards}}) ->
				apply_admin_tx(TX, {Addresses, Roles, Balance, Boards})
		end,
		{ok, {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}},
		TXs2
	).

get_admin_addresses() ->
	case ets:lookup(node_state, admin_addresses) of
		[{admin_addresses, Addresses}] ->
			Addresses;
		[] ->
			element(1, initial_state())
	end.

get_wallet_roles() ->
	case ets:lookup(node_state, wallet_roles) of
		[{wallet_roles, Roles}] ->
			ensure_admin_roles(get_admin_addresses(), Roles);
		[] ->
			element(2, initial_state())
	end.

get_wallet_capabilities() ->
	maps:map(
		fun(_Addr, Role) ->
			role_capabilities(Role)
		end,
		get_wallet_roles()
	).

get_admin_pool_balance() ->
	case ets:lookup(node_state, admin_pool_balance) of
		[{admin_pool_balance, Balance}] ->
			Balance;
		[] ->
			element(3, initial_state())
	end.

is_board_closed(BoardId) ->
	case ets:lookup(node_state, closed_boards) of
		[{closed_boards, Boards}] ->
			lists:member(BoardId, Boards);
		[] ->
			lists:member(BoardId, element(4, initial_state()))
	end.

initial_state_entries() ->
	{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards} = initial_state(),
	[
		{admin_addresses, AdminAddresses},
		{wallet_roles, WalletRoles},
		{admin_pool_balance, AdminPoolBalance},
		{closed_boards, ClosedBoards}
	].

current_state_entries() ->
	{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards} = current_state_from_chain(),
	[
		{admin_addresses, AdminAddresses},
		{wallet_roles, WalletRoles},
		{admin_pool_balance, AdminPoolBalance},
		{closed_boards, ClosedBoards}
	].

is_privileged_type(<<"Admin-Delete">>) -> true;
is_privileged_type(<<"Admin-Ban">>) -> true;
is_privileged_type(<<"Admin-Grant">>) -> true;
is_privileged_type(<<"Admin-Revoke">>) -> true;
is_privileged_type(<<"Admin-Board-Close">>) -> true;
is_privileged_type(<<"Moderator-Hide">>) -> true;
is_privileged_type(<<"Moderator-Ban">>) -> true;
is_privileged_type(_) -> false.

required_capability(<<"Admin-Delete">>) -> ?CAP_HIDE_POST;
required_capability(<<"Moderator-Hide">>) -> ?CAP_HIDE_POST;
required_capability(<<"Admin-Ban">>) -> ?CAP_BAN_USER;
required_capability(<<"Moderator-Ban">>) -> ?CAP_BAN_USER;
required_capability(<<"Admin-Grant">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"Admin-Revoke">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"Admin-Board-Close">>) -> ?CAP_MANAGE_ROLES;
required_capability(_) -> undefined.

apply_admin_tx(TX, {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}) ->
	Type = get_tag(TX, <<"Type">>),
	case is_privileged_type(Type) of
		false ->
			{ok, {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}};
		true ->
			case validate_admin_tx(TX, {AdminAddresses, WalletRoles}) of
				false ->
					{error, unauthorized_admin};
				true ->
					Cost = get_admin_cost(Type),
					case AdminPoolBalance >= Cost of
						false ->
							{error, insufficient_admin_funds};
						true ->
							{ok, apply_admin_effect(Type, TX, AdminAddresses, WalletRoles, AdminPoolBalance - Cost, ClosedBoards)}
					end
			end
	end.

apply_admin_effect(<<"Admin-Grant">>, TX, AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards) ->
	case {get_target_address(TX), get_grant_role(TX)} of
		{undefined, _} ->
			{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards};
		{_, undefined} ->
			{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards};
		{TargetAddress, Role} ->
			AdminAddresses2 =
				case Role of
					?ROLE_ADMIN ->
						lists:usort([TargetAddress | AdminAddresses]);
					?ROLE_MODERATOR ->
						lists:delete(TargetAddress, AdminAddresses)
				end,
			{
				AdminAddresses2,
				WalletRoles#{ TargetAddress => Role },
				AdminPoolBalance,
				ClosedBoards
			}
	end;
apply_admin_effect(<<"Admin-Revoke">>, TX, AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards) ->
	case get_target_address(TX) of
		undefined ->
			{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards};
		TargetAddress ->
			{
				lists:delete(TargetAddress, AdminAddresses),
				maps:remove(TargetAddress, WalletRoles),
				AdminPoolBalance,
				ClosedBoards
			}
	end;
apply_admin_effect(<<"Admin-Board-Close">>, TX, AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards) ->
	case get_tag(TX, <<"Board-Id">>) of
		undefined ->
			{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards};
		BoardId ->
			{
				AdminAddresses,
				WalletRoles,
				AdminPoolBalance,
				lists:usort([BoardId | ClosedBoards])
			}
	end;
apply_admin_effect(_, _TX, AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards) ->
	{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}.

has_valid_privileged_payload(TX, <<"Admin-Grant">>) ->
	get_target_address(TX) =/= undefined andalso get_grant_role(TX) =/= undefined;
has_valid_privileged_payload(TX, <<"Admin-Revoke">>) ->
	get_target_address(TX) =/= undefined;
has_valid_privileged_payload(TX, <<"Admin-Delete">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Moderator-Hide">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Admin-Ban">>) ->
	has_nonempty_tag(TX, <<"Ban-Pattern">>);
has_valid_privileged_payload(TX, <<"Moderator-Ban">>) ->
	has_nonempty_tag(TX, <<"Ban-Pattern">>);
has_valid_privileged_payload(TX, <<"Admin-Board-Close">>) ->
	has_nonempty_tag(TX, <<"Board-Id">>);
has_valid_privileged_payload(_TX, _Type) ->
	true.

get_target_address(TX) ->
	case get_tag(TX, <<"Target-Address">>) of
		undefined ->
			undefined;
		Address ->
			decode_address(Address)
	end.

get_grant_role(TX) ->
	case get_tag(TX, <<"Role">>) of
		undefined ->
			undefined;
		Role when Role =:= ?ROLE_ADMIN; Role =:= ?ROLE_MODERATOR ->
			Role;
		_ ->
			undefined
	end.

has_nonempty_tag(TX, TagName) ->
	case get_tag(TX, TagName) of
		undefined -> false;
		<<>> -> false;
		_ -> true
	end.

normalize_txs(TXs) ->
	lists:filtermap(
		fun
			(TX) when is_record(TX, tx) ->
				{true, TX};
			(TXID) when is_binary(TXID) ->
				case ar_storage:read_tx(TXID) of
					unavailable ->
						false;
					TX ->
						{true, TX}
				end;
			(_) ->
				false
		end,
		TXs
	).

current_state() ->
	{
		get_admin_addresses(),
		get_wallet_roles(),
		get_admin_pool_balance(),
		get_closed_boards()
	}.

get_closed_boards() ->
	case ets:lookup(node_state, closed_boards) of
		[{closed_boards, Boards}] ->
			Boards;
		[] ->
			element(4, initial_state())
	end.

%% @doc Refresh admin state in ETS from chain + mempool.
%% Called by FAST_MINE endpoint to immediately reflect admin TXs.
refresh_state() ->
	Entries = current_state_entries(),
	lists:foreach(fun({K, V}) ->
		ets:insert(node_state, {K, V})
	end, Entries),
	ok.

current_state_from_chain() ->
	InitialState = initial_state(),
	%% First, apply admin TXs from confirmed blocks
	ChainState = case catch ar_storage:read_block_index() of
		{'EXIT', _} ->
			InitialState;
		not_found ->
			InitialState;
		BlockIndex when is_list(BlockIndex) ->
			lists:foldl(
				fun(BlockRef, {Addresses, Roles, Balance, Boards}) ->
					case ar_storage:read_block(BlockRef) of
						unavailable ->
							{Addresses, Roles, Balance, Boards};
						#block{txs = TXs} ->
							case apply_admin_txs(TXs, {Addresses, Roles, Balance, Boards}) of
								{ok, State} ->
									State;
								{error, _} ->
									{Addresses, Roles, Balance, Boards}
							end
					end
				end,
				InitialState,
				lists:reverse(BlockIndex)
			)
	end,
	%% Then, also apply admin TXs from the mempool (for dev/pre-mine visibility)
	MempoolTXIDs = ar_mempool:get_all_txids(),
	MempoolTXs = lists:filtermap(fun(TXID) ->
		case ar_mempool:get_tx(TXID) of
			not_found -> false;
			TX when is_record(TX, tx) -> {true, TX};
			_ -> false
		end
	end, MempoolTXIDs),
	case apply_admin_txs(MempoolTXs, {element(1, ChainState), element(2, ChainState),
			element(3, ChainState), element(4, ChainState)}) of
		{ok, FinalState} ->
			FinalState;
		{error, _} ->
			ChainState
	end.

initial_state() ->
	Config = read_genesis_config(),
	AdminAddresses0 = get_configured_admin_addresses(Config),
	AdminAddresses = lists:usort([decode_address(Address) || Address <- AdminAddresses0]),
	WalletRoles = maps:from_list([{Addr, ?ROLE_ADMIN} || Addr <- AdminAddresses]),
	AdminPoolBalance = get_configured_admin_pool(Config),
	ClosedBoards = [],
	io:format("DEBUG: ar_admin: Initialized with ~p admins and ~p pool balance.~n", [length(AdminAddresses), AdminPoolBalance]),
	{AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards}.

read_genesis_config() ->
	Path =
		case os:getenv("AR_ADMIN_CONFIG_PATH") of
			false ->
				?DEFAULT_GENESIS_CONFIG_PATH;
			Value ->
				Value
		end,
	io:format("DEBUG: ar_admin: Reading genesis config from: ~s~n", [Path]),
	case file:read_file(Path) of
		{ok, Bin} ->
			try jiffy:decode(Bin, [return_maps]) of
				Map when is_map(Map) ->
					Map
			catch
				E:R ->
					io:format("DEBUG: ar_admin: Failed to parse genesis config: ~p:~p~n", [E, R]),
					#{}
			end;
		{error, Reason} ->
			io:format("DEBUG: ar_admin: Failed to read genesis config file (~s): ~p~n", [Path, Reason]),
			#{}
	end.

decode_address(Address) when is_binary(Address) ->
	case ar_util:safe_decode(Address) of
		{ok, Decoded} ->
			Decoded;
		{error, invalid} ->
			Address
	end.

get_configured_admin_addresses(Config) ->
	case os:getenv("AR_ADMIN_ADDRESSES") of
		false ->
			AdminConfig = maps:get(<<"admin">>, Config, #{}),
			maps:get(<<"admin_addresses">>, AdminConfig, []);
		Value ->
			[
				list_to_binary(string:trim(Address))
				|| Address <- string:split(Value, ",", all),
				   string:trim(Address) =/= ""
			]
	end.

get_configured_admin_pool(Config) ->
	case os:getenv("AR_ADMIN_POOL") of
		false ->
			TokenDistribution = maps:get(<<"token_distribution">>, Config, #{}),
			maps:get(<<"admin_pool">>, TokenDistribution, 0);
		Value ->
			try list_to_integer(Value) of
				Pool -> Pool
			catch
				_:_ ->
					0
			end
	end.

ensure_admin_roles(AdminAddresses, WalletRoles) ->
	lists:foldl(
		fun(Address, Acc) ->
			maps:put(Address, ?ROLE_ADMIN, Acc)
		end,
		WalletRoles,
		AdminAddresses
	).

get_capabilities_for_address(Address, AdminAddresses, WalletRoles) ->
	EffectiveRoles = ensure_admin_roles(AdminAddresses, WalletRoles),
	case maps:get(Address, EffectiveRoles, undefined) of
		undefined ->
			[];
		Role ->
			role_capabilities(Role)
	end.

role_capabilities(?ROLE_ADMIN) ->
	[
		?CAP_HIDE_POST,
		?CAP_BAN_USER,
		?CAP_MANAGE_ROLES
	];
role_capabilities(?ROLE_MODERATOR) ->
	[
		?CAP_HIDE_POST,
		?CAP_BAN_USER
	];
role_capabilities(_) ->
	[].

get_tag(TX, TagName) ->
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false -> undefined
	end.
