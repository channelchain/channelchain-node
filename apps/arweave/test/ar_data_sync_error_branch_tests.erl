%%% Regression: Bug 3 + Fable C3 (partial) — ar_data_sync's read paths
%%% must map ar_kv:get{,_prev}'s post-Bug-1 {error, _} return into a
%%% domain-appropriate sentinel (not_found / false / Acc), not
%%% case_clause.
%%%
%%% Incident context (2026-07): after chain a429f1d2's ar_kv:with_db
%%% widening, rocksdb NIF failures no longer crashed the caller with
%%% badarg — they returned {error, failed}. But the callers all had
%%% case statements with only {ok, _} / not_found / none clauses, so
%%% the SAME failure that used to be a badarg became a case_clause
%%% exception. Same crash-loop class, different Erlang error.
%%%
%%% Fix (chain 25b99616 + 6801b487):
%%%   are_data_roots_synced/3       adds `{error, _} -> false`
%%%   get_chunk_metadata/2          adds `{error, _} -> not_found`
%%%   get_data_roots_for_offset/1   adds `{error, _} -> {error, not_found}`
%%%     (via get_data_roots_for_offset_inner)
%%%   read_data_root_entries/6      adds `{error, _} -> Acc`
%%%
%%% These tests use meck to force ar_kv:get{,_prev} into the failure
%%% branch and assert the caller returns the domain sentinel, not
%%% a case_clause.
%%%
%%% Fable review R13. Also serves as a lint against future refactors
%%% that inadvertently drop the {error, _} clause.

-module(ar_data_sync_error_branch_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

setup() ->
	meck:new(ar_kv, [passthrough]).

teardown(_) ->
	meck:unload(ar_kv).

error_branches_test_() ->
	{setup, fun setup/0, fun teardown/1,
		[
			{"are_data_roots_synced returns false on {error, failed}",
				fun are_data_roots_synced_on_error_returns_false/0},
			{"are_data_roots_synced returns false on {error, db_not_found}",
				fun are_data_roots_synced_on_db_not_found_returns_false/0},
			{"get_chunk_metadata returns not_found on {error, failed}",
				fun get_chunk_metadata_on_error_returns_not_found/0},
			{"get_chunk_metadata still returns {ok, X} on healthy path",
				fun get_chunk_metadata_happy_path/0},
			{"get_chunk_metadata still returns not_found on missing key",
				fun get_chunk_metadata_missing_key/0}
		]}.

are_data_roots_synced_on_error_returns_false() ->
	meck:expect(ar_kv, get, fun(_, _) -> {error, failed} end),
	%% Pre-fix: case_clause({error, failed}) crashing the caller.
	%% Post-fix: false (matches the semantic "we can't tell, assume no").
	?assertEqual(false,
		ar_data_sync:are_data_roots_synced(0, 100, <<0:256>>)).

are_data_roots_synced_on_db_not_found_returns_false() ->
	meck:expect(ar_kv, get, fun(_, _) -> {error, db_not_found} end),
	?assertEqual(false,
		ar_data_sync:are_data_roots_synced(0, 100, <<0:256>>)).

get_chunk_metadata_on_error_returns_not_found() ->
	meck:expect(ar_kv, get, fun(_, _) -> {error, failed} end),
	?assertEqual(not_found,
		ar_data_sync:get_chunk_metadata(12345, some_store_id)).

get_chunk_metadata_happy_path() ->
	%% Simulate a valid stored metadata record (a term encoded via
	%% term_to_binary). Any Erlang term will do; the caller just
	%% binary_to_term's it back.
	Sample = {some, tuple, [with, list]},
	meck:expect(ar_kv, get, fun(_, _) -> {ok, term_to_binary(Sample)} end),
	?assertEqual({ok, Sample},
		ar_data_sync:get_chunk_metadata(12345, some_store_id)).

get_chunk_metadata_missing_key() ->
	meck:expect(ar_kv, get, fun(_, _) -> not_found end),
	?assertEqual(not_found,
		ar_data_sync:get_chunk_metadata(12345, some_store_id)).
