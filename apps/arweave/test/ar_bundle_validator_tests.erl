%%% Eunit tests for ar_bundle_validator (Phase C1).
%%%
%%% Scope:
%%%   - Carrier tag presence / value checks.
%%%   - Carrier-level Bundle-PoW gating.
%%%   - End-to-end happy path on the arbundles fixture (skipping
%%%     ar_bbs_validator since it would require a live ETS node_state).
%%%   - Pseudo TX synthesis preserves the data/owner/signature/tags.
%%%
%%% I3 (one bad item rejects the whole carrier) is exercised here for
%%% the parser/verify boundary; the deeper integration with
%%% ar_bbs_validator is C3.

-module(ar_bundle_validator_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_bundle.hrl").

%%%-------------------------------------------------------------------
%%% Carrier tag checks
%%%-------------------------------------------------------------------

missing_app_name_test() ->
    Carrier = make_carrier(remove_tag(<<"App-Name">>, base_tags()),
                           <<"_unused_bundle_bytes_">>),
    ?assertMatch({error, {carrier_missing_tag, <<"App-Name">>}},
                 ar_bundle_validator:validate_bundle(Carrier)).

wrong_bundle_format_test() ->
    Tags = lists:keyreplace(<<"Bundle-Format">>, 1, base_tags(),
                            {<<"Bundle-Format">>, <<"json">>}),
    Carrier = make_carrier(Tags, <<"_unused_">>),
    ?assertMatch({error, {carrier_wrong_tag_value, <<"Bundle-Format">>, <<"json">>}},
                 ar_bundle_validator:validate_bundle(Carrier)).

wrong_bundle_version_test() ->
    Tags = lists:keyreplace(<<"Bundle-Version">>, 1, base_tags(),
                            {<<"Bundle-Version">>, <<"1.0.0">>}),
    Carrier = make_carrier(Tags, <<"_unused_">>),
    ?assertMatch({error, {carrier_wrong_tag_value, <<"Bundle-Version">>, <<"1.0.0">>}},
                 ar_bundle_validator:validate_bundle(Carrier)).

missing_bundle_pow_nonce_test() ->
    Carrier = make_carrier(remove_tag(<<"Bundle-PoW-Nonce">>, base_tags()),
                           <<"_unused_">>),
    ?assertMatch({error, missing_bundle_pow_nonce},
                 ar_bundle_validator:validate_bundle(Carrier)).

%%%-------------------------------------------------------------------
%%% Carrier PoW
%%%-------------------------------------------------------------------

bad_carrier_pow_rejected_test() ->
    BundleBin = read_fixture("bundle_v2.bin"),
    Tags = set_tag(<<"Bundle-PoW-Nonce">>, <<"0">>, base_tags()),
    Carrier = make_carrier(Tags, BundleBin),
    %% Difficulty 12 with nonce "0" is overwhelmingly unlikely to satisfy.
    ?assertMatch({error, bad_carrier_pow},
                 ar_bundle_validator:validate_bundle(Carrier,
                     [{bundle_pow_difficulty, 12}])).

%%%-------------------------------------------------------------------
%%% Happy path (signed items only)
%%%-------------------------------------------------------------------

happy_path_signed_bundle_test_() ->
    {timeout, 30, fun happy_path_signed_bundle/0}.

happy_path_signed_bundle() ->
    BundleBin = read_fixture("bundle_v2.bin"),
    Difficulty = 12,
    Nonce = mine_carrier_pow(BundleBin, Difficulty),
    Tags = set_tag(<<"Bundle-PoW-Nonce">>, Nonce, base_tags()),
    Carrier = make_carrier(Tags, BundleBin),
    {ok, PseudoTXs} = ar_bundle_validator:validate_bundle(Carrier,
        [{bundle_pow_difficulty, Difficulty},
         {skip_bbs_validator, true}]),
    ?assertEqual(2, length(PseudoTXs)),
    [T1, T2] = PseudoTXs,
    %% Pseudo TXs should reflect the original item data.
    ?assertEqual(<<"hello">>, T1#tx.data),
    ?assertEqual(<<"世界"/utf8>>, T2#tx.data),
    %% Format-2 TXs.
    ?assertEqual(2, T1#tx.format),
    ?assertEqual(2, T2#tx.format),
    %% Owner is preserved (RSA modulus, 512 bytes).
    ?assertEqual(512, byte_size(T1#tx.owner)),
    %% Tags are preserved (App-Name, Type, Thread-Title for T2).
    ?assert(lists:keymember(<<"App-Name">>, 1, T1#tx.tags)),
    ?assert(lists:keymember(<<"Thread-Title">>, 1, T2#tx.tags)).

%%%-------------------------------------------------------------------
%%% I3-style: one bad item ⇒ whole carrier rejected
%%%-------------------------------------------------------------------

one_bad_signature_rejects_whole_carrier_test_() ->
    {timeout, 30, fun one_bad_signature_rejects_whole_carrier/0}.

one_bad_signature_rejects_whole_carrier() ->
    %% Flip a byte in the second item's data — parser still parses
    %% (entry id is SHA-256(sig), unchanged), but the second item's
    %% deepHash diverges, so RSA-PSS verify fails. The whole carrier
    %% must be rejected.
    BundleBin = read_fixture("bundle_v2.bin"),
    Mutated = flip_byte_in_second_item_data(BundleBin),
    Difficulty = 12,
    Nonce = mine_carrier_pow(Mutated, Difficulty),
    Tags = set_tag(<<"Bundle-PoW-Nonce">>, Nonce, base_tags()),
    Carrier = make_carrier(Tags, Mutated),
    Result = ar_bundle_validator:validate_bundle(Carrier,
        [{bundle_pow_difficulty, Difficulty},
         {skip_bbs_validator, true}]),
    ?assertMatch({error, {item_verify_failed, _Id, bad_signature}}, Result).

%%%-------------------------------------------------------------------
%%% Pseudo TX synthesis (unit-level)
%%%-------------------------------------------------------------------

pseudo_tx_for_anonymous_item_uses_zero_owner_test() ->
    Item = #bundle_item{
        id        = crypto:hash(sha256, <<"anon">>),
        kind      = anonymous,
        signature_type = 1,
        signature = binary:copy(<<0>>, ?ANON_SIG_SIZE),
        owner     = binary:copy(<<0>>, ?ANON_OWNER_SIZE),
        target    = undefined,
        anchor    = undefined,
        tag_count = 1,
        tag_bytes = <<>>,
        tags      = [{<<"PoW-Nonce">>, <<"42">>}],
        data      = <<"anon-data">>
    },
    TX = ar_bundle_validator:item_to_pseudo_tx(Item),
    ?assertEqual(2, TX#tx.format),
    ?assertEqual(binary:copy(<<0>>, ?ANON_OWNER_SIZE), TX#tx.owner),
    ?assertEqual(binary:copy(<<0>>, ?ANON_SIG_SIZE), TX#tx.signature),
    ?assertEqual(<<>>, TX#tx.target),
    ?assertEqual(<<"anon-data">>, TX#tx.data),
    ?assertEqual(byte_size(<<"anon-data">>), TX#tx.data_size).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

base_tags() ->
    [{<<"App-Name">>,        <<"ChannelChain">>},
     {<<"Type">>,            <<"Bundle">>},
     {<<"Bundle-Format">>,   <<"binary">>},
     {<<"Bundle-Version">>,  <<"2.0.0">>},
     {<<"Bundle-PoW-Nonce">>, <<"0">>}].

remove_tag(Name, Tags) -> lists:keydelete(Name, 1, Tags).

set_tag(Name, Value, Tags) ->
    lists:keystore(Name, 1, Tags, {Name, Value}).

make_carrier(Tags, BundleBin) ->
    #tx{
        format = 2,
        id = crypto:hash(sha256, <<"carrier">>),
        owner = <<>>,
        tags = Tags,
        target = <<>>,
        data = BundleBin,
        data_size = byte_size(BundleBin)
    }.

read_fixture(Name) ->
    {ok, Bin} = file:read_file(fixture_path(Name)),
    Bin.

fixture_path(Name) ->
    case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end.

mine_carrier_pow(BundleBin, Difficulty) when Difficulty =< 16 ->
    Domain = ar_bundle_verify:carrier_pow_domain(),
    mine_loop(Domain, BundleBin, Difficulty, 0).

mine_loop(_D, _Bin, _Diff, N) when N > 1_000_000 ->
    erlang:error({carrier_mine_exhausted, N});
mine_loop(Domain, BundleBin, Difficulty, N) ->
    Nonce = integer_to_binary(N),
    Hash  = crypto:hash(sha256, <<Domain/binary, BundleBin/binary, Nonce/binary>>),
    case ar_bundle_verify:check_leading_zeros(Hash, Difficulty) of
        true  -> Nonce;
        false -> mine_loop(Domain, BundleBin, Difficulty, N + 1)
    end.

%% Flip the first byte of the second item's data inside the bundle
%% binary. Parser stays happy (entry id is SHA-256(signature)), but
%% verify_item will see a deepHash that no longer matches the original
%% signature, so RSA-PSS verify fails — exercising the I3-style
%% "one bad item rejects the whole carrier" path.
flip_byte_in_second_item_data(BundleBin) ->
    {ok, [_First, Second]} = ar_bundle_parser:parse(BundleBin),
    Data = Second#bundle_item.data,
    {Pos, _} = binary:match(BundleBin, Data),
    <<Head:Pos/binary, ByteToFlip, Rest/binary>> = BundleBin,
    <<Head/binary, (ByteToFlip bxor 16#01), Rest/binary>>.
