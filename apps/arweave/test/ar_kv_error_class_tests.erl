%%% Regression: Bug 1 — ar_kv:with_db must catch every exception class
%%% (throw, error, exit), not only throw.
%%%
%%% Incident context (2026-07): cc-miner3 spent 68 hours crash-looping
%%% because rocksdb NIF calls raise error:badarg for stale iterators
%%% and inconsistent DBs. Pre-fix, `with_db` was:
%%%
%%%   try apply(Callback, ...) catch Exc -> {error, failed} end
%%%
%%% In Erlang, `catch Pattern ->` without a class prefix defaults to
%%% throw. So any error:badarg from the rocksdb NIF sailed straight
%%% through with_db's try/catch and killed whatever HTTP request /
%%% gen_server invoked it, feeding the crash loop.
%%%
%%% Fix (chain a429f1d2): widened to `catch Class:Exc:Stack -> ...`,
%%% normalizing every class into {error, failed} with a diagnostic
%%% LOG_ERROR that includes the class and stack.
%%%
%%% These tests pin the three exception classes.
%%%
%%% Fable review R13 asked for exactly this: a decisive re-executable
%%% test that would have caught the incident, or would fail loudly if
%%% the fix silently regressed (e.g. someone rewriting `catch _:_ ->`
%%% back to `catch Exc ->` in a "cleanup" pass).

-module(ar_kv_error_class_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

%% --- helpers ---

%% ar_kv:with_db reads the DB record from the module-owned ets table.
%% We plant a fake #db{} record and drive with_db through it. We do not
%% touch rocksdb here — the callback is what raises, exactly like a NIF
%% would.
setup_fake_db(Name) ->
	%% named_table ownership: the real ar_kv gen_server usually owns
	%% this. If it happens to exist (running dev shell), reuse it;
	%% otherwise create it as an ordinary named public table.
	case ets:info(ar_kv) of
		undefined -> ets:new(ar_kv, [set, public, named_table, {keypos, 2}]);
		_ -> ok
	end,
	%% #db{} record layout is defined in ar_kv.erl. keypos = 2 means
	%% .name is the ETS key. #db.db_handle can be anything for our
	%% purposes — the callbacks don't dereference it.
	Rec = {db, Name, fake_db_handle, undefined},
	ets:insert(ar_kv, Rec),
	Rec.

teardown_fake_db(Name) ->
	catch ets:delete(ar_kv, Name),
	ok.

%% --- tests ---

%% Throw was the only class the pre-fix code caught. Make sure the fix
%% still handles it (regression against overcorrection).
throw_still_caught_test() ->
	Name = {ar_kv_test, erlang:phash2(make_ref())},
	setup_fake_db(Name),
	try
		Result = ar_kv:with_db(Name, throw_test,
			fun(_Rec) -> throw(deliberate_throw) end),
		?assertEqual({error, failed}, Result)
	after
		teardown_fake_db(Name)
	end.

%% Error class — the actual load-bearing case for Bug 1. rocksdb NIF
%% badarg comes in as error:badarg. Pre-fix this crashed the caller;
%% post-fix it becomes {error, failed}.
error_class_now_caught_test() ->
	Name = {ar_kv_test, erlang:phash2(make_ref())},
	setup_fake_db(Name),
	try
		Result = ar_kv:with_db(Name, error_test,
			fun(_Rec) -> erlang:error(badarg) end),
		?assertEqual({error, failed}, Result)
	after
		teardown_fake_db(Name)
	end.

%% Exit class — less common in practice (usually from linked-process
%% exits), but the widened catch covers all three classes.
exit_class_now_caught_test() ->
	Name = {ar_kv_test, erlang:phash2(make_ref())},
	setup_fake_db(Name),
	try
		Result = ar_kv:with_db(Name, exit_test,
			fun(_Rec) -> exit(deliberate_exit) end),
		?assertEqual({error, failed}, Result)
	after
		teardown_fake_db(Name)
	end.

%% Missing DB path — with_db returns {error, db_not_found} when the
%% ets:lookup finds nothing. This is the read-path signal that Bug 3's
%% {error, _} branches now match on.
missing_db_returns_db_not_found_test() ->
	Name = {ar_kv_test, erlang:phash2(make_ref())},
	%% Deliberately do NOT populate the fake DB.
	Result = ar_kv:with_db(Name, missing_test,
		fun(_Rec) -> ?assert(never_reached), ok end),
	?assertEqual({error, db_not_found}, Result).

%% Success path — callback returns a value verbatim.
success_pass_through_test() ->
	Name = {ar_kv_test, erlang:phash2(make_ref())},
	setup_fake_db(Name),
	try
		Result = ar_kv:with_db(Name, ok_test,
			fun(_Rec) -> {ok, my_return_value} end),
		?assertEqual({ok, my_return_value}, Result)
	after
		teardown_fake_db(Name)
	end.
