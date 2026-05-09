%%% Eunit tests for ar_bundle_verify.
%%%
%%% B1 scope (docs/l2-bundle-chain-spec.md §8):
%%%   U3  signed-item RSA-PSS verify (valid)   → ok
%%%   U4  signed-item RSA-PSS verify (tamper)  → {error, bad_signature}

-module(ar_bundle_verify_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar_bundle.hrl").

%%%-------------------------------------------------------------------
%%% U3: valid signature from arbundles fixture
%%%-------------------------------------------------------------------

verify_signed_items_from_arbundles_fixture_test() ->
    Items = parsed_fixture_items(),
    ?assert(length(Items) > 0),
    [?assertEqual(ok, ar_bundle_verify:verify_item(I)) || I <- Items].

%%%-------------------------------------------------------------------
%%% U4: tampered fields → bad_signature
%%%-------------------------------------------------------------------

tampered_signature_fails_test() ->
    [Item | _] = parsed_fixture_items(),
    Tampered = Item#bundle_item{signature = flip_first_byte(Item#bundle_item.signature)},
    ?assertMatch({error, bad_signature}, ar_bundle_verify:verify_item(Tampered)).

tampered_data_fails_test() ->
    [Item | _] = parsed_fixture_items(),
    Tampered = Item#bundle_item{data = <<"tampered">>},
    ?assertMatch({error, bad_signature}, ar_bundle_verify:verify_item(Tampered)).

tampered_tag_bytes_fails_test() ->
    [Item | _] = parsed_fixture_items(),
    %% Flip a byte deep in the tag bytes (avoid breaking varint header).
    TagBytes = Item#bundle_item.tag_bytes,
    Mutated = flip_last_byte(TagBytes),
    Tampered = Item#bundle_item{tag_bytes = Mutated},
    ?assertMatch({error, bad_signature}, ar_bundle_verify:verify_item(Tampered)).

%%%-------------------------------------------------------------------
%%% B2: anonymous PoW verification
%%%-------------------------------------------------------------------

%% U5: a freshly mined anonymous item passes verify with its PoW.
anonymous_pow_valid_test_() ->
    {timeout, 30, fun anonymous_pow_valid/0}.

anonymous_pow_valid() ->
    Difficulty = 12,
    Data = <<"hello-anonymous">>,
    Nonce = mine_pow(Data, Difficulty),
    Item = anon_item(Data, Nonce, []),
    ?assertEqual(ok, ar_bundle_verify:verify_item(Item, [{difficulty, Difficulty}])).

%% U6: a wrong nonce fails.
anonymous_pow_invalid_nonce_test() ->
    Difficulty = 12,
    Item = anon_item(<<"some-data">>, <<"0">>, []),  %% nonce 0 ≪ unlikely to satisfy 12 leading zero bits
    ?assertMatch({error, bad_pow},
                 ar_bundle_verify:verify_item(Item, [{difficulty, Difficulty}])).

%% A nonce that worked at one difficulty must fail when the difficulty
%% is bumped up — ensures the threshold is enforced, not merely the
%% existence of a hash.
anonymous_pow_difficulty_threshold_test_() ->
    {timeout, 30, fun anonymous_pow_difficulty_threshold/0}.

anonymous_pow_difficulty_threshold() ->
    LowDifficulty  = 8,
    HighDifficulty = 24,    %% practically unreachable in this test
    Data = <<"diff-threshold">>,
    Nonce = mine_pow(Data, LowDifficulty),
    Item = anon_item(Data, Nonce, []),
    ?assertEqual(ok, ar_bundle_verify:verify_item(Item, [{difficulty, LowDifficulty}])),
    ?assertMatch({error, bad_pow},
                 ar_bundle_verify:verify_item(Item, [{difficulty, HighDifficulty}])).

%% Sanity: the leading-zeros helper itself behaves on byte boundaries
%% and within the trailing partial byte.
check_leading_zeros_byte_aligned_test() ->
    ?assert(ar_bundle_verify:check_leading_zeros(<<0,0,16#FF,16#FF>>, 16)),
    ?assertNot(ar_bundle_verify:check_leading_zeros(<<0,1>>, 16)).

check_leading_zeros_partial_byte_test() ->
    %% 0x0F = 0000_1111: top 4 bits are zero, bit 5 is 1.
    ?assert(ar_bundle_verify:check_leading_zeros(<<16#0F>>, 4)),
    ?assertNot(ar_bundle_verify:check_leading_zeros(<<16#0F>>, 5)).

%% A hand-built anonymous item whose tags contain no PoW-Nonce should
%% never reach this verifier (parser rejects upstream), but defensive
%% behaviour matters for hand-constructed records.
anonymous_pow_missing_nonce_tag_defensive_test() ->
    Item = anon_item(<<"d">>, <<>>, [drop_pow_nonce]),
    ?assertMatch({error, missing_pow_nonce},
                 ar_bundle_verify:verify_item(Item, [{difficulty, 4}])).

%%%-------------------------------------------------------------------
%%% deep_hash/1 cross-check vs A3 fixture
%%%-------------------------------------------------------------------

deep_hash_matches_fixture_test() ->
    Items   = parsed_fixture_items(),
    {ok, [Expected]} = file:consult(fixture_path("bundle_v2.fixt")),
    [?assertEqual(maps:get(deep_hash, Exp), ar_bundle_verify:deep_hash(I))
     || {Exp, I} <- lists:zip(Expected, Items)].

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

parsed_fixture_items() ->
    {ok, BundleBin} = file:read_file(fixture_path("bundle_v2.bin")),
    {ok, Items} = ar_bundle_parser:parse(BundleBin),
    Items.

fixture_path(Name) ->
    case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end.

flip_first_byte(<<B, Rest/binary>>) ->
    <<(B bxor 16#01), Rest/binary>>.

flip_last_byte(Bin) ->
    Sz = byte_size(Bin) - 1,
    <<Head:Sz/binary, B:8>> = Bin,
    <<Head/binary, (B bxor 16#01):8>>.

%%% --- Anonymous-item construction & PoW mining ---

%% Build a minimal anonymous bundle_item record. `Modifiers` lets a
%% test omit the PoW-Nonce tag without weakening the parser's rules
%% (the parser would reject this; we exercise the verifier directly).
anon_item(Data, Nonce, Modifiers) ->
    BaseTags = [{<<"App-Name">>, <<"ChannelChain">>},
                {<<"Type">>, <<"Post">>},
                {<<"PoW-Nonce">>, Nonce}],
    Tags = case lists:member(drop_pow_nonce, Modifiers) of
        true  -> lists:keydelete(<<"PoW-Nonce">>, 1, BaseTags);
        false -> BaseTags
    end,
    #bundle_item{
        id = crypto:hash(sha256, <<"anon-fixture-id">>),
        kind = anonymous,
        signature_type = 1,
        signature = binary:copy(<<0>>, ?ANON_SIG_SIZE),
        owner = binary:copy(<<0>>, ?ANON_OWNER_SIZE),
        target = undefined,
        anchor = undefined,
        tag_count = length(Tags),
        tag_bytes = <<>>,
        tags = Tags,
        data = Data
    }.

%% Mine a nonce N such that SHA-256(Data || ascii(N)) has `Difficulty`
%% leading zero bits. Capped at 16 so unit tests stay well under a
%% second per call.
mine_pow(Data, Difficulty) when Difficulty =< 16 ->
    mine_pow_loop(Data, Difficulty, 0).

mine_pow_loop(_Data, _Difficulty, N) when N > 1_000_000 ->
    erlang:error({pow_mine_exhausted, N});
mine_pow_loop(Data, Difficulty, N) ->
    Nonce = integer_to_binary(N),
    Hash = crypto:hash(sha256, <<Data/binary, Nonce/binary>>),
    case ar_bundle_verify:check_leading_zeros(Hash, Difficulty) of
        true  -> Nonce;
        false -> mine_pow_loop(Data, Difficulty, N + 1)
    end.
