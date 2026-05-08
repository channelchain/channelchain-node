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
    ?assertMatch({error, {item_id_mismatch, _, _}},
                 ar_bundle_parser:parse(Bin)).

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
    Names = [id, signature_type, signature, owner, target, anchor,
             tag_count, tag_bytes, data],
    Index = lookup(Field, Names, 2),  %% +1 for record tag
    element(Index, Tuple).

lookup(Field, [Field | _], Idx) -> Idx;
lookup(Field, [_ | Rest], Idx)  -> lookup(Field, Rest, Idx + 1).
