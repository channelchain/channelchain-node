%% ar_admin.erl
%%
%% 権限付きTXの権限検証、および Admin Pool / ロール / Capability 状態管理
%% capability_plan.md に基づく拡張権限体系

-module(ar_admin).

-export([
	is_admin_tx/1,
	is_channelchain_tx/1,
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
	get_board_moderators/0,
	get_user_capabilities/0,
	is_board_closed/1,
	initial_state_entries/0,
	current_state_entries/0,
	refresh_state/0,
	get_genesis_wallets/0
]).

-include_lib("arweave/include/ar.hrl").

%% ── Costs ──
-define(ADMIN_DELETE_COST,         1000000000).   %% 0.001 TOKEN
-define(ADMIN_BAN_COST,           10000000000).   %% 0.01 TOKEN
-define(ADMIN_GRANT_COST,         50000000000).   %% 0.05 TOKEN
-define(ADMIN_REVOKE_COST,        50000000000).   %% 0.05 TOKEN
-define(ADMIN_BOARD_CLOSE_COST,  100000000000).   %% 0.1 TOKEN
-define(MODERATOR_HIDE_COST,       1000000000).   %% 0.001 TOKEN
-define(MODERATOR_BAN_COST,       10000000000).   %% 0.01 TOKEN
-define(BOARD_MOD_HIDE_COST,       500000000).    %% 0.0005 TOKEN
-define(BOARD_MOD_BAN_COST,        500000000).    %% 0.0005 TOKEN
-define(USER_GRANT_COST,          50000000000).   %% 0.05 TOKEN
-define(USER_REVOKE_COST,         50000000000).   %% 0.05 TOKEN
-define(SELF_DELETE_COST,          200000000).     %% 0.0002 TOKEN
-define(DEFAULT_GENESIS_CONFIG_PATH, "config/genesis_block.json").

%% ── Roles ──
-define(ROLE_ADMIN, <<"admin">>).
-define(ROLE_MODERATOR, <<"moderator">>).
-define(ROLE_BOARD_MODERATOR, <<"board-moderator">>).

%% ── Admin/Moderator Capabilities ──
-define(CAP_HIDE_POST, <<"can_hide_post">>).
-define(CAP_BAN_USER, <<"can_ban_user">>).
-define(CAP_MANAGE_ROLES, <<"can_manage_roles">>).

%% ── User Capabilities ──
-define(CAP_SELF_DELETE_POST, <<"can_self_delete_post">>).
-define(CAP_EDIT_POST, <<"can_edit_post">>).
-define(CAP_VERIFIED_POST, <<"can_verified_post">>).
-define(CAP_PRIORITY_REPORT, <<"can_priority_report">>).

-define(VALID_USER_CAPS, [?CAP_SELF_DELETE_POST, ?CAP_EDIT_POST,
	?CAP_VERIFIED_POST, ?CAP_PRIORITY_REPORT]).

%%%===================================================================
%%% State: 6-tuple
%%% {AdminAddresses, WalletRoles, AdminPoolBalance, ClosedBoards,
%%%  BoardModerators, UserCapabilities}
%%%
%%% BoardModerators: #{WalletAddress => [BoardId]}
%%% UserCapabilities: #{WalletAddress => [Capability]}
%%%===================================================================

validate_admin_tx(TX) ->
	validate_admin_tx(TX, current_state()).

is_admin_tx(TX) ->
	is_privileged_type(get_tag(TX, <<"Type">>)).

is_channelchain_tx(TX) ->
	get_tag(TX, <<"App-Name">>) =:= <<"ChannelChain">>.

validate_admin_tx(TX, {AdminAddresses, WalletRoles, _Balance, _Boards, BoardMods, UserCaps}) ->
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
					validate_capabilities(Type, TX, OwnerAddr,
						AdminAddresses, WalletRoles, BoardMods, UserCaps)
			end
	end.

validate_capabilities(<<"Self-Delete">>, TX, OwnerAddr, _AA, _WR, _BM, UserCaps) ->
	%% Self-Delete: owner must have can_self_delete_post capability and
	%% may only delete their own ChannelChain post.
	Caps = maps:get(OwnerAddr, UserCaps, []),
	lists:member(?CAP_SELF_DELETE_POST, Caps)
		andalso validate_self_delete_target(TX, OwnerAddr);
validate_capabilities(<<"Edit-Post">>, TX, OwnerAddr, _AA, _WR, _BM, UserCaps) ->
	%% Edit-Post: owner must have can_edit_post capability and
	%% may only edit their own ChannelChain post.
	Caps = maps:get(OwnerAddr, UserCaps, []),
	lists:member(?CAP_EDIT_POST, Caps)
		andalso validate_edit_target(TX, OwnerAddr);
validate_capabilities(<<"Priority-Report">>, _TX, OwnerAddr, _AA, _WR, _BM, UserCaps) ->
	%% Priority-Report: owner must have can_priority_report capability.
	Caps = maps:get(OwnerAddr, UserCaps, []),
	lists:member(?CAP_PRIORITY_REPORT, Caps);
validate_capabilities(Type, TX, OwnerAddr, AdminAddresses, WalletRoles, BoardMods, _UserCaps) ->
	Capabilities = get_capabilities_for_address(OwnerAddr, AdminAddresses, WalletRoles),
	case required_capability(Type) of
		undefined ->
			false;
		Capability ->
			HasCap = lists:member(Capability, Capabilities),
			case HasCap of
				false -> false;
				true ->
					%% Board-Moderator scope enforcement
					case Type of
						<<"Board-Moderator-Hide">> ->
							validate_board_scope(OwnerAddr, TX, BoardMods);
						<<"Board-Moderator-Ban">> ->
							validate_board_scope(OwnerAddr, TX, BoardMods);
						_ ->
							true
					end
			end
	end.

validate_board_scope(OwnerAddr, TX, BoardMods) ->
	BoardId = get_tag(TX, <<"Board-Id">>),
	AuthorizedBoards = maps:get(OwnerAddr, BoardMods, []),
	lists:member(BoardId, AuthorizedBoards).

validate_self_delete_target(TX, OwnerAddr) ->
	case get_target_tx_id(TX) of
		undefined ->
			false;
		TargetTXID ->
			case read_target_tx(TargetTXID) of
				unavailable ->
					false;
				TargetTX ->
					get_tag(TargetTX, <<"App-Name">>) =:= <<"ChannelChain">>
						andalso get_tag(TargetTX, <<"Type">>) =:= <<"Post">>
						andalso ar_tx:get_owner_address(TargetTX) =:= OwnerAddr
			end
	end.

validate_edit_target(TX, OwnerAddr) ->
	case get_target_tx_id(TX) of
		undefined ->
			false;
		TargetTXID ->
			case read_target_tx(TargetTXID) of
				unavailable ->
					false;
				TargetTX ->
					get_tag(TargetTX, <<"App-Name">>) =:= <<"ChannelChain">>
						andalso get_tag(TargetTX, <<"Type">>) =:= <<"Post">>
						andalso ar_tx:get_owner_address(TargetTX) =:= OwnerAddr
			end
	end.

read_target_tx(TargetTXID) ->
	case ar_mempool:get_tx(TargetTXID) of
		not_found ->
			ar_storage:read_tx(TargetTXID);
		TargetTX ->
			TargetTX
	end.

validate_block_txs(TXs) ->
	State = current_state(),
	case apply_admin_txs(TXs, State) of
		{ok, _NextState} ->
			ok;
		Error ->
			Error
	end.

%% ── Costs ──
get_admin_cost(<<"Admin-Delete">>) -> ?ADMIN_DELETE_COST;
get_admin_cost(<<"Admin-Ban">>) -> ?ADMIN_BAN_COST;
get_admin_cost(<<"Admin-Grant">>) -> ?ADMIN_GRANT_COST;
get_admin_cost(<<"Admin-Revoke">>) -> ?ADMIN_REVOKE_COST;
get_admin_cost(<<"Admin-Board-Close">>) -> ?ADMIN_BOARD_CLOSE_COST;
get_admin_cost(<<"Moderator-Hide">>) -> ?MODERATOR_HIDE_COST;
get_admin_cost(<<"Moderator-Ban">>) -> ?MODERATOR_BAN_COST;
get_admin_cost(<<"Board-Moderator-Hide">>) -> ?BOARD_MOD_HIDE_COST;
get_admin_cost(<<"Board-Moderator-Ban">>) -> ?BOARD_MOD_BAN_COST;
get_admin_cost(<<"User-Grant">>) -> ?USER_GRANT_COST;
get_admin_cost(<<"User-Revoke">>) -> ?USER_REVOKE_COST;
get_admin_cost(<<"Self-Delete">>) -> 0; %% paid by user wallet via TX quantity
get_admin_cost(<<"Edit-Post">>) -> 0; %% paid by user wallet via TX quantity
get_admin_cost(<<"Priority-Report">>) -> 0; %% paid by user wallet via TX quantity
get_admin_cost(_) -> 0.

%% ── State application ──
apply_admin_txs(TXs, State) ->
	TXs2 = normalize_txs(TXs),
	lists:foldl(
		fun(TX, {ok, S}) ->
			apply_admin_tx(TX, S)
		end,
		{ok, State},
		TXs2
	).

apply_admin_tx(TX, {AA, WR, Balance, Boards, BM, UC}) ->
	Type = get_tag(TX, <<"Type">>),
	case is_privileged_type(Type) of
		false ->
			{ok, {AA, WR, Balance, Boards, BM, UC}};
		true ->
			case validate_admin_tx(TX, {AA, WR, Balance, Boards, BM, UC}) of
				false ->
					%% Skip unauthorized TXs instead of aborting the fold
					{ok, {AA, WR, Balance, Boards, BM, UC}};
				true ->
					Cost = get_admin_cost(Type),
					case Balance >= Cost of
						false ->
							%% Skip underfunded TXs
							{ok, {AA, WR, Balance, Boards, BM, UC}};
						true ->
							{ok, apply_admin_effect(Type, TX, AA, WR, Balance - Cost, Boards, BM, UC)}
					end
			end
	end.

%% ── Effects ──
apply_admin_effect(<<"Admin-Grant">>, TX, AA, WR, Balance, Boards, BM, UC) ->
	case {get_target_address(TX), get_grant_role(TX)} of
		{undefined, _} ->
			{AA, WR, Balance, Boards, BM, UC};
		{_, undefined} ->
			{AA, WR, Balance, Boards, BM, UC};
		{TargetAddress, ?ROLE_ADMIN} ->
			{lists:usort([TargetAddress | AA]),
			 WR#{ TargetAddress => ?ROLE_ADMIN },
			 Balance, Boards, BM, UC};
		{TargetAddress, ?ROLE_MODERATOR} ->
			{lists:delete(TargetAddress, AA),
			 WR#{ TargetAddress => ?ROLE_MODERATOR },
			 Balance, Boards, BM, UC};
		{TargetAddress, ?ROLE_BOARD_MODERATOR} ->
			BoardId = get_tag(TX, <<"Board-Id">>),
			case BoardId of
				undefined ->
					{AA, WR, Balance, Boards, BM, UC};
				_ ->
					BM2 = maps:update_with(TargetAddress,
						fun(Bs) -> lists:usort([BoardId | Bs]) end,
						[BoardId], BM),
					{AA, WR#{ TargetAddress => ?ROLE_BOARD_MODERATOR },
					 Balance, Boards, BM2, UC}
			end
	end;
apply_admin_effect(<<"Admin-Revoke">>, TX, AA, WR, Balance, Boards, BM, UC) ->
	case get_target_address(TX) of
		undefined ->
			{AA, WR, Balance, Boards, BM, UC};
		TargetAddress ->
			{lists:delete(TargetAddress, AA),
			 maps:remove(TargetAddress, WR),
			 Balance, Boards,
			 maps:remove(TargetAddress, BM),
			 UC}
	end;
apply_admin_effect(<<"Admin-Board-Close">>, TX, AA, WR, Balance, Boards, BM, UC) ->
	case get_tag(TX, <<"Board-Id">>) of
		undefined ->
			{AA, WR, Balance, Boards, BM, UC};
		BoardId ->
			{AA, WR, Balance, lists:usort([BoardId | Boards]), BM, UC}
	end;
apply_admin_effect(<<"User-Grant">>, TX, AA, WR, Balance, Boards, BM, UC) ->
	case {get_target_address(TX), get_tag(TX, <<"Capability">>)} of
		{undefined, _} ->
			{AA, WR, Balance, Boards, BM, UC};
		{_, undefined} ->
			{AA, WR, Balance, Boards, BM, UC};
		{TargetAddress, Cap} ->
			case lists:member(Cap, ?VALID_USER_CAPS) of
				false ->
					{AA, WR, Balance, Boards, BM, UC};
				true ->
					UC2 = maps:update_with(TargetAddress,
						fun(Cs) -> lists:usort([Cap | Cs]) end,
						[Cap], UC),
					{AA, WR, Balance, Boards, BM, UC2}
			end
	end;
apply_admin_effect(<<"User-Revoke">>, TX, AA, WR, Balance, Boards, BM, UC) ->
	case {get_target_address(TX), get_tag(TX, <<"Capability">>)} of
		{undefined, _} ->
			{AA, WR, Balance, Boards, BM, UC};
		{_, undefined} ->
			{AA, WR, Balance, Boards, BM, UC};
		{TargetAddress, Cap} ->
			CurrentCaps = maps:get(TargetAddress, UC, []),
			NewCaps = lists:delete(Cap, CurrentCaps),
			UC2 = case NewCaps of
				[] -> maps:remove(TargetAddress, UC);
				_ -> UC#{ TargetAddress => NewCaps }
			end,
			{AA, WR, Balance, Boards, BM, UC2}
	end;
apply_admin_effect(_, _TX, AA, WR, Balance, Boards, BM, UC) ->
	{AA, WR, Balance, Boards, BM, UC}.

%% ── Privileged type checks ──
is_privileged_type(<<"Admin-Delete">>) -> true;
is_privileged_type(<<"Admin-Ban">>) -> true;
is_privileged_type(<<"Admin-Grant">>) -> true;
is_privileged_type(<<"Admin-Revoke">>) -> true;
is_privileged_type(<<"Admin-Board-Close">>) -> true;
is_privileged_type(<<"Moderator-Hide">>) -> true;
is_privileged_type(<<"Moderator-Ban">>) -> true;
is_privileged_type(<<"Board-Moderator-Hide">>) -> true;
is_privileged_type(<<"Board-Moderator-Ban">>) -> true;
is_privileged_type(<<"User-Grant">>) -> true;
is_privileged_type(<<"User-Revoke">>) -> true;
is_privileged_type(<<"Self-Delete">>) -> true;
is_privileged_type(<<"Edit-Post">>) -> true;
is_privileged_type(<<"Priority-Report">>) -> true;
is_privileged_type(_) -> false.

required_capability(<<"Admin-Delete">>) -> ?CAP_HIDE_POST;
required_capability(<<"Moderator-Hide">>) -> ?CAP_HIDE_POST;
required_capability(<<"Board-Moderator-Hide">>) -> ?CAP_HIDE_POST;
required_capability(<<"Admin-Ban">>) -> ?CAP_BAN_USER;
required_capability(<<"Moderator-Ban">>) -> ?CAP_BAN_USER;
required_capability(<<"Board-Moderator-Ban">>) -> ?CAP_BAN_USER;
required_capability(<<"Admin-Grant">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"Admin-Revoke">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"Admin-Board-Close">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"User-Grant">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"User-Revoke">>) -> ?CAP_MANAGE_ROLES;
required_capability(<<"Self-Delete">>) -> undefined; %% handled separately
required_capability(<<"Edit-Post">>) -> undefined; %% handled separately
required_capability(<<"Priority-Report">>) -> undefined; %% handled separately
required_capability(_) -> undefined.

%% ── Payload validation ──
has_valid_privileged_payload(TX, <<"Admin-Grant">>) ->
	case get_grant_role(TX) of
		?ROLE_BOARD_MODERATOR ->
			get_target_address(TX) =/= undefined andalso has_nonempty_tag(TX, <<"Board-Id">>);
		Role when Role =/= undefined ->
			get_target_address(TX) =/= undefined;
		_ ->
			false
	end;
has_valid_privileged_payload(TX, <<"Admin-Revoke">>) ->
	get_target_address(TX) =/= undefined;
has_valid_privileged_payload(TX, <<"Admin-Delete">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Moderator-Hide">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Board-Moderator-Hide">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>) andalso has_nonempty_tag(TX, <<"Board-Id">>);
has_valid_privileged_payload(TX, <<"Admin-Ban">>) ->
	has_nonempty_tag(TX, <<"Ban-Pattern">>);
has_valid_privileged_payload(TX, <<"Moderator-Ban">>) ->
	has_nonempty_tag(TX, <<"Ban-Pattern">>);
has_valid_privileged_payload(TX, <<"Board-Moderator-Ban">>) ->
	has_nonempty_tag(TX, <<"Ban-Pattern">>) andalso has_nonempty_tag(TX, <<"Board-Id">>);
has_valid_privileged_payload(TX, <<"Admin-Board-Close">>) ->
	has_nonempty_tag(TX, <<"Board-Id">>);
has_valid_privileged_payload(TX, <<"User-Grant">>) ->
	get_target_address(TX) =/= undefined andalso has_nonempty_tag(TX, <<"Capability">>);
has_valid_privileged_payload(TX, <<"User-Revoke">>) ->
	get_target_address(TX) =/= undefined andalso has_nonempty_tag(TX, <<"Capability">>);
has_valid_privileged_payload(TX, <<"Self-Delete">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Edit-Post">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>);
has_valid_privileged_payload(TX, <<"Priority-Report">>) ->
	has_nonempty_tag(TX, <<"Target-TX">>) andalso has_nonempty_tag(TX, <<"Reason">>);
has_valid_privileged_payload(_TX, _Type) ->
	true.

%% ── State accessors ──
get_admin_addresses() ->
	case ets:lookup(node_state, admin_addresses) of
		[{admin_addresses, Addresses}] -> Addresses;
		[] -> element(1, initial_state())
	end.

get_wallet_roles() ->
	case ets:lookup(node_state, wallet_roles) of
		[{wallet_roles, Roles}] -> ensure_admin_roles(get_admin_addresses(), Roles);
		[] -> element(2, initial_state())
	end.

get_wallet_capabilities() ->
	%% Role-derived capabilities (for /info display)
	RoleCaps = maps:map(
		fun(_Addr, Role) -> role_capabilities(Role) end,
		get_wallet_roles()
	),
	%% Merge with user-granted capabilities
	UserCaps = get_user_capabilities(),
	maps:fold(fun(Addr, Caps, Acc) ->
		ExistingCaps = maps:get(Addr, Acc, []),
		maps:put(Addr, lists:usort(ExistingCaps ++ Caps), Acc)
	end, RoleCaps, UserCaps).

get_admin_pool_balance() ->
	case ets:lookup(node_state, admin_pool_balance) of
		[{admin_pool_balance, Balance}] -> Balance;
		[] -> element(3, initial_state())
	end.

get_closed_boards() ->
	case ets:lookup(node_state, closed_boards) of
		[{closed_boards, Boards}] -> Boards;
		[] -> element(4, initial_state())
	end.

get_board_moderators() ->
	case ets:lookup(node_state, board_moderators) of
		[{board_moderators, BM}] -> BM;
		[] -> element(5, initial_state())
	end.

get_user_capabilities() ->
	case ets:lookup(node_state, user_capabilities) of
		[{user_capabilities, UC}] -> UC;
		[] -> element(6, initial_state())
	end.

is_board_closed(BoardId) ->
	lists:member(BoardId, get_closed_boards()).

%% ── State entries for ETS ──
initial_state_entries() ->
	{AA, WR, Balance, Boards, BM, UC} = initial_state(),
	[{admin_addresses, AA}, {wallet_roles, WR}, {admin_pool_balance, Balance},
	 {closed_boards, Boards}, {board_moderators, BM}, {user_capabilities, UC}].

current_state_entries() ->
	{AA, WR, Balance, Boards, BM, UC} = current_state_from_chain(),
	[{admin_addresses, AA}, {wallet_roles, WR}, {admin_pool_balance, Balance},
	 {closed_boards, Boards}, {board_moderators, BM}, {user_capabilities, UC}].

refresh_state() ->
	Entries = current_state_entries(),
	lists:foreach(fun({K, V}) -> ets:insert(node_state, {K, V}) end, Entries),
	ok.

%% ── Internal helpers ──
current_state() ->
	{get_admin_addresses(), get_wallet_roles(), get_admin_pool_balance(),
	 get_closed_boards(), get_board_moderators(), get_user_capabilities()}.

current_state_from_chain() ->
	InitialState = initial_state(),
	ChainState = case catch ar_storage:read_block_index() of
		{'EXIT', _} -> InitialState;
		not_found -> InitialState;
		BlockIndex when is_list(BlockIndex) ->
			lists:foldl(
				fun(BlockRef, State) ->
					case ar_storage:read_block(BlockRef) of
						unavailable -> State;
						#block{txs = TXs} ->
							case apply_admin_txs(TXs, State) of
								{ok, S} -> S;
								{error, _} -> State
							end
					end
				end,
				InitialState,
				lists:reverse(BlockIndex)
			)
	end,
	%% Also apply admin TXs from mempool (for dev/pre-mine visibility)
	%% Collect pending TXs from mempool
	MempoolTXIDs = ar_mempool:get_all_txids(),
	MempoolTXs = lists:filtermap(fun(TXID) ->
		case ar_mempool:get_tx(TXID) of
			not_found -> false;
			TX when is_record(TX, tx) -> {true, TX};
			_ -> false
		end
	end, MempoolTXIDs),
	%% Also get admin TX records from the channelchain index's TX records table.
	%% Signed admin TXs may not be in ar_mempool but are stored here.
	AdminTXRecords = case catch ets:tab2list(channelchain_tx_records) of
		{'EXIT', _} -> [];
		Records ->
			MempoolIDSet = sets:from_list([TX#tx.id || TX <- MempoolTXs]),
			[TX || {_TXID, TX} <- Records,
			       not sets:is_element(TX#tx.id, MempoolIDSet)]
	end,
	AllTXs = MempoolTXs ++ AdminTXRecords,
	case apply_admin_txs(AllTXs, ChainState) of
		{ok, FinalState} -> FinalState;
		{error, _} -> ChainState
	end.

initial_state() ->
	Config = read_genesis_config(),
	AdminAddresses0 = get_configured_admin_addresses(Config),
	AdminAddresses = lists:usort([decode_address(Address) || Address <- AdminAddresses0]),
	WalletRoles = maps:from_list([{Addr, ?ROLE_ADMIN} || Addr <- AdminAddresses]),
	AdminPoolBalance = get_configured_admin_pool(Config),
	{AdminAddresses, WalletRoles, AdminPoolBalance, [], #{}, #{}}.

read_genesis_config() ->
	Path = case os:getenv("AR_ADMIN_CONFIG_PATH") of
		false -> ?DEFAULT_GENESIS_CONFIG_PATH;
		Value -> Value
	end,
	case file:read_file(Path) of
		{ok, Bin} ->
			try jiffy:decode(Bin, [return_maps]) of
				Map when is_map(Map) -> Map
			catch _:_ -> #{} end;
		{error, _} -> #{}
	end.

decode_address(Address) when is_binary(Address) ->
	case ar_util:safe_decode(Address) of
		{ok, Decoded} -> Decoded;
		{error, invalid} -> Address
	end.

get_configured_admin_addresses(Config) ->
	case os:getenv("AR_ADMIN_ADDRESSES") of
		false ->
			AdminConfig = maps:get(<<"admin">>, Config, #{}),
			maps:get(<<"admin_addresses">>, AdminConfig, []);
		Value ->
			[list_to_binary(string:trim(A)) || A <- string:split(Value, ",", all),
			 string:trim(A) =/= ""]
	end.

get_configured_admin_pool(Config) ->
	case os:getenv("AR_ADMIN_POOL") of
		false ->
			TokenDist = maps:get(<<"token_distribution">>, Config, #{}),
			maps:get(<<"admin_pool">>, TokenDist, 0);
		Value ->
			try list_to_integer(Value) of Pool -> Pool
			catch _:_ -> 0 end
	end.

%% @doc Read genesis wallets from config.
%% Returns [{DecodedAddress, Balance, <<>>}] for ar_weave:init/1.
get_genesis_wallets() ->
	Config = read_genesis_config(),
	Wallets = maps:get(<<"wallets">>, Config, []),
	lists:filtermap(fun(Entry) when is_map(Entry) ->
		case {maps:get(<<"address">>, Entry, undefined),
		      maps:get(<<"balance">>, Entry, 0)} of
			{undefined, _} -> false;
			{Addr, Balance} when is_binary(Addr), is_integer(Balance), Balance > 0 ->
				{true, {decode_address(Addr), Balance, <<>>}};
			_ -> false
		end;
	(_) -> false
	end, Wallets).

get_target_address(TX) ->
	%% Decode the base64url-encoded address from the tag to raw binary,
	%% matching the format returned by ar_tx:get_owner_address/1.
	case get_tag(TX, <<"Target-Address">>) of
		undefined -> undefined;
		Addr -> decode_address(Addr)
	end.

get_target_tx_id(TX) ->
	case get_tag(TX, <<"Target-TX">>) of
		undefined ->
			undefined;
		TXID ->
			case ar_util:safe_decode(TXID) of
				{ok, Decoded} -> Decoded;
				{error, invalid} -> TXID
			end
	end.

get_grant_role(TX) ->
	case get_tag(TX, <<"Role">>) of
		undefined -> undefined;
		Role when Role =:= ?ROLE_ADMIN; Role =:= ?ROLE_MODERATOR;
		          Role =:= ?ROLE_BOARD_MODERATOR -> Role;
		_ -> undefined
	end.

has_nonempty_tag(TX, TagName) ->
	case get_tag(TX, TagName) of
		undefined -> false;
		<<>> -> false;
		_ -> true
	end.

normalize_txs(TXs) ->
	lists:filtermap(fun
		(TX) when is_record(TX, tx) -> {true, TX};
		(TXID) when is_binary(TXID) ->
			case ar_storage:read_tx(TXID) of
				unavailable -> false;
				TX -> {true, TX}
			end;
		(_) -> false
	end, TXs).

ensure_admin_roles(AdminAddresses, WalletRoles) ->
	lists:foldl(fun(Address, Acc) ->
		maps:put(Address, ?ROLE_ADMIN, Acc)
	end, WalletRoles, AdminAddresses).

get_capabilities_for_address(Address, AdminAddresses, WalletRoles) ->
	EffectiveRoles = ensure_admin_roles(AdminAddresses, WalletRoles),
	case maps:get(Address, EffectiveRoles, undefined) of
		undefined -> [];
		Role -> role_capabilities(Role)
	end.

role_capabilities(?ROLE_ADMIN) ->
	[?CAP_HIDE_POST, ?CAP_BAN_USER, ?CAP_MANAGE_ROLES];
role_capabilities(?ROLE_MODERATOR) ->
	[?CAP_HIDE_POST, ?CAP_BAN_USER];
role_capabilities(?ROLE_BOARD_MODERATOR) ->
	[?CAP_HIDE_POST, ?CAP_BAN_USER];
role_capabilities(_) ->
	[].

get_tag(TX, TagName) ->
	%% Tags may be stored as plain binary or base64url-encoded.
	%% Try plain match first, then decode each tag for comparison.
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false ->
			get_tag_decoded(TX#tx.tags, TagName)
	end.

get_tag_decoded([], _TagName) -> undefined;
get_tag_decoded([{EncodedName, EncodedValue} | Rest], TagName) ->
	case catch ar_util:decode(EncodedName) of
		TagName ->
			case catch ar_util:decode(EncodedValue) of
				{'EXIT', _} -> EncodedValue;
				DecodedValue -> DecodedValue
			end;
		_ ->
			get_tag_decoded(Rest, TagName)
	end.
