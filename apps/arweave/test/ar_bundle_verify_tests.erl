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
%%% Anonymous-item rejection (out of scope for B1)
%%%-------------------------------------------------------------------

anonymous_item_is_not_verifiable_here_test() ->
    Item = #bundle_item{
        kind = anonymous,
        signature_type = 1,
        signature = binary:copy(<<0>>, 512),
        owner = binary:copy(<<0>>, 512),
        target = undefined,
        anchor = undefined,
        tag_count = 1,
        tag_bytes = <<>>,
        tags = [{<<"PoW-Nonce">>, <<"0">>}],
        data = <<>>,
        id = crypto:hash(sha256, <<"placeholder">>)
    },
    ?assertEqual({error, anonymous_not_verifiable_here},
                 ar_bundle_verify:verify_item(Item)).

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
