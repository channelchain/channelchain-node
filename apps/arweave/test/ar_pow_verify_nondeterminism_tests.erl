%% Regression: validate_tx_pow/1 must be deterministic.
%%
%% Background: get_current_difficulty/0 derives the required PoW
%% leading-zero count from `ets:info(channelchain_tx_tags, size)`. Because
%% that ETS table is populated incrementally as a node replays the chain,
%% the same anonymous TX validates differently depending on WHEN it's
%% asked. This breaks JOIN: peer-served historical TXs are rejected with
%% {error, invalid_tx} once a joiner has indexed enough txs to cross a
%% difficulty threshold. Empirically reproduced 2026-06-19 against a real
%% production failing TX (L=18, prod ETS size 1429, board_diff 19).
%%
%% These tests pin the defect (so a future "I fixed something" does not
%% silently re-introduce it) and pin the desired post-fix invariant.

-module(ar_pow_verify_nondeterminism_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

ensure_table() ->
    catch ets:delete(channelchain_tx_tags),
    ets:new(channelchain_tx_tags, [set, public, named_table]),
    %% get_difficulty_for_board/1 consults node_state.board_configs via
    %% ar_admin. Provide an empty map so the test stays on the base
    %% (no-board-override) difficulty path — that's what we're isolating.
    catch ets:delete(node_state),
    ets:new(node_state, [set, public, named_table]),
    ets:insert(node_state, {board_configs, #{}}).

set_size(N) ->
    ets:delete_all_objects(channelchain_tx_tags),
    lists:foreach(
        fun(I) -> ets:insert(channelchain_tx_tags, {{dummy, I}, true}) end,
        lists:seq(1, N)),
    N = ets:info(channelchain_tx_tags, size).

leading_zero_bits(<<0:1, Rest/bitstring>>, N) -> leading_zero_bits(Rest, N + 1);
leading_zero_bits(_, N) -> N.

%% Brute-force a nonce so sha256(Data ++ Nonce) has 16 =< L < 22 leading
%% zero bits — clears the floor (16) but not the >100-tx step (22). The
%% inequality with the band's INNER walls is what makes the test load
%% bearing: a TX whose L sits inside the band must give different
%% validate_tx_pow results on either side of LOW_LOAD_THRESHOLD.
mine_anon_tx() -> mine(<<"nondeterminism-probe">>, 0).
mine(Data, K) ->
    Nonce = integer_to_binary(K),
    case leading_zero_bits(crypto:hash(sha256, <<Data/binary, Nonce/binary>>), 0) of
        L when L >= 16, L < 22 ->
            #tx{
                format = 1,
                signature = <<>>,
                owner = <<>>,
                id = crypto:strong_rand_bytes(32),
                data = Data,
                tags = [{<<"PoW-Nonce">>, Nonce}]
            };
        _ ->
            mine(Data, K + 1)
    end.

%%====================================================================
%% Tests
%%====================================================================

%% The defect, in isolation: required difficulty tracks mutable ETS size.
%% This currently passes (documents the broken behaviour).
difficulty_tracks_table_size_test() ->
    ensure_table(),
    set_size(0),   ?assertEqual(16, ar_pow_verify:get_current_difficulty()),
    set_size(10),  ?assertEqual(16, ar_pow_verify:get_current_difficulty()),
    set_size(11),  ?assertEqual(20, ar_pow_verify:get_current_difficulty()),
    set_size(100), ?assertEqual(20, ar_pow_verify:get_current_difficulty()),
    set_size(101), ?assertEqual(22, ar_pow_verify:get_current_difficulty()),
    set_size(500), ?assertEqual(22, ar_pow_verify:get_current_difficulty()),
    set_size(501), ?assertEqual(24, ar_pow_verify:get_current_difficulty()),
    catch ets:delete(channelchain_tx_tags),
    catch ets:delete(node_state).

%% End-to-end invariant: the JOIN-path validator (validate_tx_pow_join/1)
%% MUST return the same result regardless of node-local ETS state. This
%% is the function ar_tx:verify_tx_id calls for anonymous TXs during
%% JOIN. Also asserts R0 = true: a TX with L in [16, 22) must clear the
%% LOW_LOAD_DIFFICULTY floor (= 16) — if this fires, either the mining
%% loop produced a TX outside the band, or the floor changed.
validate_tx_pow_join_independent_of_table_size_test() ->
    ensure_table(),
    TX = mine_anon_tx(),
    set_size(0),   R0   = ar_pow_verify:validate_tx_pow_join(TX),
    set_size(200), R200 = ar_pow_verify:validate_tx_pow_join(TX),
    catch ets:delete(channelchain_tx_tags),
    catch ets:delete(node_state),
    ?assertEqual(R0, R200),
    ?assertEqual(true, R0).

%% Sanity: validate_tx_pow/1 (live ingestion) is INTENTIONALLY still
%% state-dependent for spam control. If this flips, the live path
%% accidentally lost its dynamic difficulty ladder — flag it.
validate_tx_pow_remains_state_dependent_test() ->
    ensure_table(),
    TX = mine_anon_tx(),
    set_size(0),   R0   = ar_pow_verify:validate_tx_pow(TX),
    set_size(200), R200 = ar_pow_verify:validate_tx_pow(TX),
    catch ets:delete(channelchain_tx_tags),
    catch ets:delete(node_state),
    ?assertNotEqual(R0, R200).
