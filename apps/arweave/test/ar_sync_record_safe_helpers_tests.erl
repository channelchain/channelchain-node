%%% Regression: Bug 2 — ar_sync_record's public read paths must not
%%% crash when the sync_records ETS table has not been created (or
%%% has been deleted post-supervisor-collapse).
%%%
%%% Incident context (2026-07): the cc-miner3 crash trace showed
%%%
%%%   {ets, lookup, [sync_records, {ar_data_sync_footprints, ...}],
%%%    [{error_info, #{cause => id, module => erl_stdlib_errors}}]}
%%%
%%% `cause => id` means "the table id is invalid" — the named table
%%% `sync_records` did not exist at the moment lookup fired. It IS
%%% created by ar_sync_record_sup:init/1 during startup, but HTTP
%%% listeners can be up before that init completes, and after a
%%% supervisor collapse the table can vanish while HTTP still serves.
%%% Every crash the trace showed was a downstream case_clause on a
%%% badarg that this fix would have turned into an empty result.
%%%
%%% Fix (chain a429f1d2 + 25b99616):
%%%   - safe_sync_records_lookup/1   returns [] on badarg
%%%   - safe_sync_records_first/0    returns '$end_of_table' on badarg
%%%   - safe_sync_records_next/1     returns '$end_of_table' on badarg
%%% All three log a WARNING event `sync_records_table_missing` so
%%% operators can grep for the silent-degradation mode.
%%%
%%% These tests pin both directions for each helper: healthy table
%%% (delegates to raw ets), and missing table (returns the sentinel
%%% without raising).

-module(ar_sync_record_safe_helpers_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- helpers ---

ensure_missing() ->
	catch ets:delete(sync_records),
	?assertEqual(undefined, ets:info(sync_records)).

ensure_populated(Entries) ->
	catch ets:delete(sync_records),
	ets:new(sync_records, [set, public, named_table, {read_concurrency, true}]),
	lists:foreach(fun(E) -> ets:insert(sync_records, E) end, Entries).

teardown() ->
	catch ets:delete(sync_records),
	ok.

%% --- safe_sync_records_lookup/1 ---

lookup_missing_table_returns_empty_test() ->
	ensure_missing(),
	try
		%% Pre-fix: error:badarg with cause=id, killing the caller.
		?assertEqual([], ar_sync_record:safe_sync_records_lookup(any_key))
	after
		teardown()
	end.

lookup_populated_returns_entry_test() ->
	ensure_populated([{k1, tid1}, {k2, tid2}]),
	try
		?assertEqual([{k1, tid1}], ar_sync_record:safe_sync_records_lookup(k1)),
		?assertEqual([{k2, tid2}], ar_sync_record:safe_sync_records_lookup(k2)),
		?assertEqual([], ar_sync_record:safe_sync_records_lookup(k3))
	after
		teardown()
	end.

%% --- safe_sync_records_first/0 ---

first_missing_table_returns_end_of_table_test() ->
	ensure_missing(),
	try
		%% Pre-fix: badarg killed is_recorded/3's tail-recursion.
		%% Post-fix: '$end_of_table' terminates the recursion cleanly
		%% via is_recorded2/4's first clause.
		?assertEqual('$end_of_table', ar_sync_record:safe_sync_records_first())
	after
		teardown()
	end.

first_populated_returns_some_key_test() ->
	ensure_populated([{only_key, tid_val}]),
	try
		?assertEqual(only_key, ar_sync_record:safe_sync_records_first())
	after
		teardown()
	end.

%% --- safe_sync_records_next/1 ---

next_missing_table_returns_end_of_table_test() ->
	ensure_missing(),
	try
		?assertEqual('$end_of_table',
			ar_sync_record:safe_sync_records_next(some_previous_key))
	after
		teardown()
	end.

next_populated_iterates_test() ->
	ensure_populated([{a, 1}, {b, 2}, {c, 3}]),
	try
		First = ar_sync_record:safe_sync_records_first(),
		Second = ar_sync_record:safe_sync_records_next(First),
		Third = ar_sync_record:safe_sync_records_next(Second),
		Fourth = ar_sync_record:safe_sync_records_next(Third),
		Keys = lists:sort([First, Second, Third]),
		?assertEqual([a, b, c], Keys),
		?assertEqual('$end_of_table', Fourth)
	after
		teardown()
	end.
