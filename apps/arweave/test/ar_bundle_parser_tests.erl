%%% @doc Eunit tests for ar_bundle_parser.
%%%
%%% A1 scope (see docs/l2-bundle-chain-spec.md §8):
%%%   U1  parse a well-formed bundle (0 / 1 / 2 items)
%%%   U7  reject when entry-table count vs items length disagree
%%%   U8  reject when an entry's id does not match SHA-256(signature)
%%%
%%% Avro tag decoding is *not* exercised here — the parser keeps tag
%%% bytes raw. Tests use placeholder tag bytes only.

-module(ar_bundle_parser_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SIGTYPE_ARWEAVE, 1).
-define(SIG_LEN, 512).
-define(OWNER_LEN, 512).

%%%-------------------------------------------------------------------
%%% U1: well-formed bundles
%%%-------------------------------------------------------------------

empty_bundle_test() ->
    Bin = u256_le(0),
    ?assertEqual({ok, []}, ar_bundle_parser:parse(Bin)).

single_item_bundle_test() ->
    Sig    = filled(?SIG_LEN, $A),
    Owner  = filled(?OWNER_LEN, $B),
    Tags   = <<>>,                     %% empty Avro placeholder
    Data   = <<"hello">>,
    {ItemBin, ItemId} = build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                                   undefined, undefined, 0, Tags, Data),

    Bundle = build_bundle([{ItemBin, ItemId}]),

    {ok, [Item]} = ar_bundle_parser:parse(Bundle),
    ?assertEqual(ItemId, ar_bundle_parser:item_id(Item)),
    ?assertEqual(<<"hello">>, item_field(data, Item)),
    ?assertEqual(Sig,   item_field(signature, Item)),
    ?assertEqual(Owner, item_field(owner, Item)),
    ?assertEqual(Tags,  item_field(tag_bytes, Item)),
    ?assertEqual(undefined, item_field(target, Item)),
    ?assertEqual(undefined, item_field(anchor, Item)).

multi_item_bundle_test() ->
    Sig1 = filled(?SIG_LEN, $X),
    Sig2 = filled(?SIG_LEN, $Y),
    Owner1 = filled(?OWNER_LEN, $1),
    Owner2 = filled(?OWNER_LEN, $2),
    Target = filled(32, $T),
    Anchor = filled(32, $K),

    {Item1Bin, Item1Id} =
        build_item(?SIGTYPE_ARWEAVE, Sig1, Owner1,
                   undefined, undefined, 0, <<>>, <<"first">>),
    {Item2Bin, Item2Id} =
        build_item(?SIGTYPE_ARWEAVE, Sig2, Owner2,
                   Target, Anchor, 0, <<>>, <<"second">>),

    Bundle = build_bundle([{Item1Bin, Item1Id}, {Item2Bin, Item2Id}]),

    {ok, [I1, I2]} = ar_bundle_parser:parse(Bundle),
    ?assertEqual(<<"first">>,  item_field(data, I1)),
    ?assertEqual(<<"second">>, item_field(data, I2)),
    ?assertEqual(undefined, item_field(target, I1)),
    ?assertEqual(Target,    item_field(target, I2)),
    ?assertEqual(Anchor,    item_field(anchor, I2)).

%%%-------------------------------------------------------------------
%%% U7: count vs items disagreement
%%%-------------------------------------------------------------------

entry_table_truncated_test() ->
    %% Header claims 2 items but the entry table cannot fit (need 128 bytes,
    %% only 64 are present and there is nothing after).
    Sig = filled(?SIG_LEN, $A),
    Owner = filled(?OWNER_LEN, $B),
    {ItemBin, ItemId} =
        build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                   undefined, undefined, 0, <<>>, <<"x">>),
    Header = u256_le(2),
    Entry  = <<(u256_le(byte_size(ItemBin)))/binary, ItemId/binary>>,
    Bin    = <<Header/binary, Entry/binary>>,
    ?assertMatch({error, entry_table_truncated},
                 ar_bundle_parser:parse(Bin)).

trailing_bytes_after_items_test() ->
    %% Header & entries claim 1 item, but extra bytes appear past it.
    Sig = filled(?SIG_LEN, $A),
    Owner = filled(?OWNER_LEN, $B),
    {ItemBin, ItemId} =
        build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                   undefined, undefined, 0, <<>>, <<"x">>),
    Bundle = build_bundle([{ItemBin, ItemId}]),
    Bad    = <<Bundle/binary, "GARBAGE">>,
    ?assertMatch({error, trailing_bytes_after_items},
                 ar_bundle_parser:parse(Bad)).

item_payload_truncated_test() ->
    %% Entry size exceeds remaining bytes for the item.
    Sig = filled(?SIG_LEN, $A),
    Owner = filled(?OWNER_LEN, $B),
    {ItemBin, ItemId} =
        build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                   undefined, undefined, 0, <<>>, <<"x">>),
    Header = u256_le(1),
    %% advertise size 9999 but supply only ItemBin
    Entry  = <<(u256_le(9999))/binary, ItemId/binary>>,
    Bin    = <<Header/binary, Entry/binary, ItemBin/binary>>,
    ?assertMatch({error, item_payload_truncated},
                 ar_bundle_parser:parse(Bin)).

%%%-------------------------------------------------------------------
%%% U8: id mismatch
%%%-------------------------------------------------------------------

item_id_mismatch_test() ->
    Sig    = filled(?SIG_LEN, $A),
    Owner  = filled(?OWNER_LEN, $B),
    {ItemBin, _RealId} =
        build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                   undefined, undefined, 0, <<>>, <<"hello">>),
    %% Use a fabricated wrong id
    WrongId = filled(32, $Z),
    Header  = u256_le(1),
    Entry   = <<(u256_le(byte_size(ItemBin)))/binary, WrongId/binary>>,
    Bin     = <<Header/binary, Entry/binary, ItemBin/binary>>,
    ?assertMatch({error, {item_id_mismatch, signed, _, _}},
                 ar_bundle_parser:parse(Bin)).

%%%-------------------------------------------------------------------
%%% A2: Avro tag decoding
%%%-------------------------------------------------------------------

decode_tags_empty_test() ->
    ?assertEqual({ok, []}, ar_bundle_parser:decode_tags(<<>>)),
    ?assertEqual({ok, []}, ar_bundle_parser:decode_tags(<<0>>)).

decode_tags_single_block_test() ->
    Tags = [{<<"App-Name">>, <<"ChannelChain">>},
            {<<"Type">>, <<"Post">>}],
    Bin  = avro_tags(Tags),
    ?assertEqual({ok, Tags}, ar_bundle_parser:decode_tags(Bin)).

decode_tags_utf8_test() ->
    %% Tag values may contain UTF-8 sequences (e.g., post body in name tag).
    Tags = [{<<"Name">>, <<"名無しさん"/utf8>>}],
    Bin  = avro_tags(Tags),
    ?assertEqual({ok, Tags}, ar_bundle_parser:decode_tags(Bin)).

decode_tags_multi_block_test() ->
    %% Two positive-count blocks back-to-back, terminated by 0.
    R1 = avro_record(<<"a">>, <<"1">>),
    R2 = avro_record(<<"b">>, <<"2">>),
    Bin = <<(avro_long(1))/binary, R1/binary,
            (avro_long(1))/binary, R2/binary,
            (avro_long(0))/binary>>,
    ?assertEqual({ok, [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}]},
                 ar_bundle_parser:decode_tags(Bin)).

decode_tags_negative_count_block_test() ->
    %% Negative count carries a byte-size hint; we honor the records
    %% by absolute count and accept (but do not enforce) the size.
    R1 = avro_record(<<"k">>, <<"v">>),
    Bin = <<(avro_long(-1))/binary,             %% count = -1
            (avro_long(byte_size(R1)))/binary,   %% block byte size
            R1/binary,
            (avro_long(0))/binary>>,
    ?assertEqual({ok, [{<<"k">>, <<"v">>}]},
                 ar_bundle_parser:decode_tags(Bin)).

decode_tags_truncated_string_test() ->
    %% String length declares 5 bytes but only 2 are present.
    Bad = <<(avro_long(1))/binary,        %% 1 record
            (avro_long(5))/binary,        %% name len
            "ab",                          %% truncated payload
            (avro_long(0))/binary>>,
    ?assertMatch({error, string_truncated},
                 ar_bundle_parser:decode_tags(Bad)).

decode_tags_truncated_varint_test() ->
    %% Continuation bit set but no following byte.
    ?assertMatch({error, varint_truncated},
                 ar_bundle_parser:decode_tags(<<16#80>>)).

%%%-------------------------------------------------------------------
%%% Tag-aware item integration
%%%-------------------------------------------------------------------

item_with_tags_round_trips_test() ->
    Sig    = filled(?SIG_LEN, $A),
    Owner  = filled(?OWNER_LEN, $B),
    Tags   = [{<<"App-Name">>, <<"ChannelChain">>},
              {<<"Type">>, <<"Post">>}],
    TagBytes = avro_tags(Tags),
    {ItemBin, ItemId} = build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                                   undefined, undefined,
                                   length(Tags), TagBytes, <<"hi">>),
    Bundle = build_bundle([{ItemBin, ItemId}]),

    {ok, [Item]} = ar_bundle_parser:parse(Bundle),
    ?assertEqual(Tags,     item_field(tags, Item)),
    ?assertEqual(TagBytes, item_field(tag_bytes, Item)),
    ?assertEqual(2,        item_field(tag_count, Item)).

tag_count_mismatch_test() ->
    %% Header advertises 2 tags but encoded array carries only 1.
    Sig    = filled(?SIG_LEN, $A),
    Owner  = filled(?OWNER_LEN, $B),
    OneTag = avro_tags([{<<"k">>, <<"v">>}]),
    {ItemBin, ItemId} = build_item(?SIGTYPE_ARWEAVE, Sig, Owner,
                                   undefined, undefined,
                                   2, OneTag, <<"x">>),
    Bundle = build_bundle([{ItemBin, ItemId}]),
    ?assertMatch({error, {tag_count_mismatch, 2, 1}},
                 ar_bundle_parser:parse(Bundle)).

%%%-------------------------------------------------------------------
%%% E3 / U10: hard limit — too many items
%%%-------------------------------------------------------------------

too_many_items_rejected_test() ->
    %% MAX_ITEMS_PER_BUNDLE = 256 in ar_bundle_parser.
    Header = u256_le(257),
    ?assertMatch({error, {too_many_items, 257}},
                 ar_bundle_parser:parse(Header)).

%% Boundary: exactly 256 items would be accepted structurally (and
%% then rejected on entry_table_truncated since we supply no entries),
%% but the count itself is not the rejection reason.
exactly_max_items_not_rejected_for_count_test() ->
    Header = u256_le(256),
    case ar_bundle_parser:parse(Header) of
        {error, {too_many_items, _}} ->
            erlang:error(unexpected_too_many_items_error);
        _ ->
            ok
    end.

%%%-------------------------------------------------------------------
%%% A3: cross-check vs arweave-js (arbundles) fixture
%%%
%%% The fixture is generated by test/fixtures/bundle_v2_gen.mjs and
%%% committed alongside the binary so this test is deterministic
%%% without requiring Node.js to run.
%%%-------------------------------------------------------------------

cross_check_arbundles_fixture_test_() ->
    %% 5s timeout in case the parser ever regresses into a tight loop
    %% on a malformed fixture.
    {timeout, 5, fun cross_check_arbundles_fixture/0}.

cross_check_arbundles_fixture() ->
    BundleBin = read_fixture("bundle_v2.bin"),
    {ok, [Expected]} = file:consult(fixture_path("bundle_v2.fixt")),
    {ok, Items} = ar_bundle_parser:parse(BundleBin),
    ?assertEqual(length(Expected), length(Items)),
    lists:foreach(fun({Exp, Actual}) -> assert_item_matches(Exp, Actual) end,
                  lists:zip(Expected, Items)).

assert_item_matches(Exp, Actual) ->
    ?assertEqual(maps:get(id, Exp),             item_field(id, Actual)),
    ?assertEqual(maps:get(signature_type, Exp), item_field(signature_type, Actual)),
    ?assertEqual(maps:get(owner, Exp),          item_field(owner, Actual)),
    ?assertEqual(maps:get(signature, Exp),      item_field(signature, Actual)),
    ?assertEqual(maps:get(target, Exp),         item_field(target, Actual)),
    ?assertEqual(maps:get(anchor, Exp),         item_field(anchor, Actual)),
    ?assertEqual(maps:get(tags, Exp),           item_field(tags, Actual)),
    ?assertEqual(maps:get(tag_bytes, Exp),      item_field(tag_bytes, Actual)),
    ?assertEqual(maps:get(data, Exp),           item_field(data, Actual)),

    Computed = ar_deep_hash:hash([
        <<"dataitem">>,
        <<"1">>,
        integer_to_binary(maps:get(signature_type, Exp)),
        item_field(owner, Actual),
        empty_or_bin(item_field(target, Actual)),
        empty_or_bin(item_field(anchor, Actual)),
        item_field(tag_bytes, Actual),
        item_field(data, Actual)
    ]),
    ?assertEqual(maps:get(deep_hash, Exp), Computed).

empty_or_bin(undefined) -> <<>>;
empty_or_bin(Bin) when is_binary(Bin) -> Bin.

read_fixture(Name) ->
    {ok, Bin} = file:read_file(fixture_path(Name)),
    Bin.

fixture_path(Name) ->
    %% eunit may run with cwd set to apps/arweave or to the project root.
    case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end.

%%%-------------------------------------------------------------------
%%% B0: anonymous-aware parsing (ChannelChain extension)
%%%
%%% docs/l2-bundle-chain-spec.md §2-2 (B):
%%%   anonymous = signature_type=1
%%%             + owner == ZERO_OWNER (512 × 0x00)
%%%             + signature == ZERO_SIG (512 × 0x00)
%%%             + PoW-Nonce tag present
%%%   AnonItemID = SHA-256(deepHash(item))
%%%   Partial-zero asymmetry → reject (parser-level structural error).
%%%-------------------------------------------------------------------

-define(ZERO_OWNER, binary:copy(<<0>>, 512)).
-define(ZERO_SIG,   binary:copy(<<0>>, 512)).

anonymous_item_parses_test() ->
    Tags = [{<<"App-Name">>, <<"ChannelChain">>},
            {<<"Type">>, <<"Post">>},
            {<<"PoW-Nonce">>, <<"42">>}],
    TagBytes = avro_tags(Tags),
    Data = <<"hello-anon">>,
    AnonId = compute_anon_id(?ZERO_OWNER, undefined, undefined,
                             TagBytes, Data),
    {ItemBin, _SigBasedId} = build_item(?SIGTYPE_ARWEAVE, ?ZERO_SIG,
                                        ?ZERO_OWNER, undefined,
                                        undefined, length(Tags),
                                        TagBytes, Data),
    Bundle = build_bundle([{ItemBin, AnonId}]),
    {ok, [Item]} = ar_bundle_parser:parse(Bundle),
    ?assertEqual(anonymous, item_field(kind, Item)),
    ?assertEqual(AnonId,    item_field(id, Item)),
    ?assertEqual(true,      ar_bundle_parser:is_anonymous(Item)).

%% U8b: entry table id of an anonymous item uses the wrong rule
%% (SHA-256 of zero signature). Parser must reject — the legitimate
%% AnonItemID will not match.
anonymous_entry_id_mismatch_test() ->
    Tags = [{<<"PoW-Nonce">>, <<"1">>}],
    TagBytes = avro_tags(Tags),
    {ItemBin, SigBasedId} = build_item(?SIGTYPE_ARWEAVE, ?ZERO_SIG,
                                       ?ZERO_OWNER, undefined,
                                       undefined, length(Tags),
                                       TagBytes, <<"x">>),
    Bundle = build_bundle([{ItemBin, SigBasedId}]),
    ?assertMatch({error, {item_id_mismatch, anonymous, _, _}},
                 ar_bundle_parser:parse(Bundle)).

%% U8c.1: owner == ZERO but signature non-zero → reject.
partial_zero_owner_only_test() ->
    Sig = filled(?SIG_LEN, $S),         %% non-zero
    Tags = [{<<"PoW-Nonce">>, <<"1">>}],
    TagBytes = avro_tags(Tags),
    {ItemBin, ItemId} = build_item(?SIGTYPE_ARWEAVE, Sig, ?ZERO_OWNER,
                                   undefined, undefined,
                                   length(Tags), TagBytes, <<"x">>),
    Bundle = build_bundle([{ItemBin, ItemId}]),
    ?assertMatch({error, partial_zero_owner_only},
                 ar_bundle_parser:parse(Bundle)).

%% U8c.2: signature == ZERO but owner non-zero → reject.
partial_zero_signature_only_test() ->
    Owner = filled(?OWNER_LEN, $O),     %% non-zero
    Tags = [{<<"PoW-Nonce">>, <<"1">>}],
    TagBytes = avro_tags(Tags),
    {ItemBin, ItemId} = build_item(?SIGTYPE_ARWEAVE, ?ZERO_SIG, Owner,
                                   undefined, undefined,
                                   length(Tags), TagBytes, <<"x">>),
    Bundle = build_bundle([{ItemBin, ItemId}]),
    ?assertMatch({error, partial_zero_signature_only},
                 ar_bundle_parser:parse(Bundle)).

%% U8c.3: ZERO_OWNER + ZERO_SIG but no PoW-Nonce tag → reject.
anonymous_missing_pow_nonce_test() ->
    Tags = [{<<"App-Name">>, <<"ChannelChain">>}],   %% no PoW-Nonce
    TagBytes = avro_tags(Tags),
    {ItemBin, SigBasedId} = build_item(?SIGTYPE_ARWEAVE, ?ZERO_SIG, ?ZERO_OWNER,
                                       undefined, undefined,
                                       length(Tags), TagBytes, <<"x">>),
    Bundle = build_bundle([{ItemBin, SigBasedId}]),
    ?assertMatch({error, anonymous_missing_pow_nonce},
                 ar_bundle_parser:parse(Bundle)).

signed_item_kind_test() ->
    %% Sanity: existing arbundles fixture parses as kind=signed.
    BundleBin = read_fixture("bundle_v2.bin"),
    {ok, Items} = ar_bundle_parser:parse(BundleBin),
    [?assertEqual(signed, item_field(kind, I)) || I <- Items].

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

filled(N, Char) ->
    binary:copy(<<Char>>, N).

u16_le(V) -> <<V:16/little-unsigned-integer>>.

u64_le(V) -> <<V:64/little-unsigned-integer>>.

u256_le(V) -> <<V:256/little-unsigned-integer>>.

%% Build a single ANS-104 item binary and the corresponding ItemID.
%% Returns {ItemBin, ItemId}.
build_item(SigType, Sig, Owner, Target, Anchor, TagCount, TagBytes, Data) ->
    TargetBin = optional_32(Target),
    AnchorBin = optional_32(Anchor),
    TagHeader = <<(u64_le(TagCount))/binary,
                  (u64_le(byte_size(TagBytes)))/binary>>,
    ItemBin = <<(u16_le(SigType))/binary,
                Sig/binary,
                Owner/binary,
                TargetBin/binary,
                AnchorBin/binary,
                TagHeader/binary,
                TagBytes/binary,
                Data/binary>>,
    ItemId  = crypto:hash(sha256, Sig),
    {ItemBin, ItemId}.

optional_32(undefined) -> <<0>>;
optional_32(V) when byte_size(V) =:= 32 -> <<1, V/binary>>.

%% Build a full bundle binary from [{ItemBin, ItemId}].
build_bundle(Items) ->
    N = length(Items),
    Header = u256_le(N),
    Entries = << <<(u256_le(byte_size(IB)))/binary, Id/binary>>
                 || {IB, Id} <- Items >>,
    Body = << <<IB/binary>> || {IB, _Id} <- Items >>,
    <<Header/binary, Entries/binary, Body/binary>>.

%% Cross-module field accessor (avoids leaking the record into tests).
%% Mirrors the field order in ar_bundle_parser.erl.
item_field(Field, Tuple) ->
    Names = [id, kind, signature_type, signature, owner, target, anchor,
             tag_count, tag_bytes, tags, data],
    Index = lookup(Field, Names, 2),  %% +1 for record tag
    element(Index, Tuple).

lookup(Field, [Field | _], Idx) -> Idx;
lookup(Field, [_ | Rest], Idx)  -> lookup(Field, Rest, Idx + 1).

%%% --- AnonItemID computation (mirrors parser logic) ---

compute_anon_id(Owner, Target, Anchor, TagBytes, Data) ->
    DH = ar_deep_hash:hash([
        <<"dataitem">>, <<"1">>, <<"1">>,
        Owner,
        case Target of undefined -> <<>>; _ -> Target end,
        case Anchor of undefined -> <<>>; _ -> Anchor end,
        TagBytes,
        Data
    ]),
    crypto:hash(sha256, DH).

%%% --- Avro encoding helpers (for tag fixtures) ---

zigzag_enc(N) when N >= 0 -> N * 2;
zigzag_enc(N) when N <  0 -> -N * 2 - 1.

varint_enc(N) when N >= 0, N < 128 -> <<N>>;
varint_enc(N) when N >= 128 ->
    Lo = N band 16#7F,
    Hi = N bsr 7,
    <<(Lo bor 16#80), (varint_enc(Hi))/binary>>.

avro_long(N) -> varint_enc(zigzag_enc(N)).

avro_string(Bin) ->
    <<(avro_long(byte_size(Bin)))/binary, Bin/binary>>.

avro_record(Name, Value) ->
    <<(avro_string(Name))/binary, (avro_string(Value))/binary>>.

%% Single-block array followed by 0 end marker.
avro_tags(Tags) ->
    Records = << <<(avro_record(N, V))/binary>> || {N, V} <- Tags >>,
    <<(avro_long(length(Tags)))/binary, Records/binary, (avro_long(0))/binary>>.
