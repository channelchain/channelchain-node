%%% Regression: Bug 5 — ar_tx_blacklist auto-recovers from a 0-byte dets
%%% file on disk instead of crash-looping the whole arweave application.
%%%
%%% Incident (2026-07-01): cc-miner's ar_tx_blacklist dets file on disk
%%% was truncated to 0 bytes by a SIGKILL landing mid-flush. Next boot,
%%% dets:open_file/2 returned {error, {not_a_dets_file, File}}; the
%%% pattern-match in initialize_state/0's lists:foreach blew up
%%% ar_tx_blacklist:init/1; the ar_sup start_error tore down the arweave
%%% application; docker's restart policy replayed the same crash
%%% forever. Node was unreachable until an operator manually deleted
%%% the empty file.
%%%
%%% Fix (chain 9b9ac477): open_dets_recover_empty/2 checks the on-disk
%%% size when open_file reports not_a_dets_file. Zero bytes = nothing to
%%% preserve; delete and let dets create a fresh table (which is what
%%% open_file would have done had the file simply been missing).
%%% Non-zero corrupt files still crash — preserving data integrity when
%%% the corruption is not obviously safe to discard is more important
%%% than uptime.
%%%
%%% These tests pin the three branches of open_dets_recover_empty/2:
%%%   (a) file missing               → ok, fresh dets file created
%%%   (b) file exists, valid dets    → ok, pre-existing entries preserved
%%%   (c) file exists, 0 bytes       → ok, warning logged, fresh table
%%%   (d) file exists, non-empty garbage → error({not_a_dets_file, _})
%%%
%%% Fable review R13 asked for exactly this: a decisive re-executable
%%% test that would have caught the incident, or would fail loudly if
%%% the fix silently regressed.

-module(ar_tx_blacklist_dets_recovery_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- helpers ---

tmp_dir() ->
	Base = filename:join([<<"/tmp">>,
		list_to_binary(io_lib:format("ar_tx_blacklist_dets_test_~p_~p",
			[erlang:phash2(make_ref()), erlang:system_time()]))]),
	ok = filelib:ensure_dir(<<Base/binary, "/x">>),
	Base.

cleanup(Dir) ->
	%% dets:close/1 is idempotent on an already-closed table; the file
	%% deletion is the important part.
	os:cmd("rm -rf " ++ binary_to_list(Dir)).

random_name() ->
	list_to_atom("dets_test_" ++
		integer_to_list(erlang:phash2(make_ref())) ++ "_" ++
		integer_to_list(erlang:system_time())).

%% --- tests ---

%% (a) File missing → open_file itself creates a fresh dets. Confirms the
%% helper does not accidentally break the happy path.
missing_file_creates_fresh_test() ->
	Dir = tmp_dir(),
	try
		Name = random_name(),
		File = filename:join(Dir, atom_to_list(Name)),
		?assertEqual(false, filelib:is_regular(File)),
		ok = ar_tx_blacklist:open_dets_recover_empty(Name, File),
		?assertEqual(true, filelib:is_regular(File)),
		%% Fresh dets: no entries.
		?assertEqual([], dets:match_object(Name, '_')),
		dets:close(Name)
	after
		cleanup(Dir)
	end.

%% (b) Pre-existing valid dets with entries → preserved. Confirms we do
%% not touch a healthy file.
existing_valid_dets_preserved_test() ->
	Dir = tmp_dir(),
	try
		Name = random_name(),
		File = filename:join(Dir, atom_to_list(Name)),
		%% Populate a valid dets file.
		{ok, Name} = dets:open_file(Name, [{file, File}]),
		ok = dets:insert(Name, [{alice, 1}, {bob, 2}]),
		ok = dets:close(Name),
		%% Re-open through the helper: entries should still be there.
		ok = ar_tx_blacklist:open_dets_recover_empty(Name, File),
		Entries = lists:sort(dets:match_object(Name, '_')),
		?assertEqual([{alice, 1}, {bob, 2}], Entries),
		dets:close(Name)
	after
		cleanup(Dir)
	end.

%% (c) 0-byte file (the exact incident) → recovered as a fresh table.
%% This is the load-bearing case: the pre-fix path here was a badmatch
%% that crash-looped the container.
zero_byte_recovered_as_fresh_test() ->
	Dir = tmp_dir(),
	try
		Name = random_name(),
		File = filename:join(Dir, atom_to_list(Name)),
		%% Simulate a mid-flush SIGKILL: 0-byte file exists on disk.
		ok = file:write_file(File, <<>>),
		?assertEqual({ok, 0}, {ok, filelib:file_size(File)}),
		%% The pre-fix code would have crashed with badmatch here.
		%% The fix must return ok and give us a usable table.
		ok = ar_tx_blacklist:open_dets_recover_empty(Name, File),
		?assertEqual([], dets:match_object(Name, '_')),
		%% Verify we can actually write to the newly-created table.
		ok = dets:insert(Name, {recovery_marker, 1}),
		?assertEqual([{recovery_marker, 1}], dets:match_object(Name, '_')),
		dets:close(Name)
	after
		cleanup(Dir)
	end.

%% (d) Non-empty garbage file → still crashes. This is intentional
%% policy: we do not want to silently discard data whose corruption
%% could hide something we should investigate.
non_empty_garbage_still_crashes_test() ->
	Dir = tmp_dir(),
	try
		Name = random_name(),
		File = filename:join(Dir, atom_to_list(Name)),
		%% Write ~4KB of random garbage.
		ok = file:write_file(File, crypto:strong_rand_bytes(4096)),
		?assert(filelib:file_size(File) > 0),
		?assertError({not_a_dets_file, _},
			ar_tx_blacklist:open_dets_recover_empty(Name, File))
	after
		cleanup(Dir)
	end.
