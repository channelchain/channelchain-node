%%% @doc ANS-104 binary bundle parser.
%%%
%%% Decodes an ANS-104 v2.0.0 bundle binary into a list of #bundle_item{}.
%%% This is part of the ChannelChain L2 bundle settlement work
%%% (see docs/l2-bundle-chain-spec.md, Phase A1).
%%%
%%% A1 scope: structural decoding only.
%%%   - Item-level signature / PoW verification: deferred to ar_bundle_verify (Phase B).
%%%   - Avro tag decoding: deferred to A2 — tag bytes are kept raw in this phase.
%%%   - deepHash cross-check vs arweave-js: deferred to A3.
%%%
%%% Bundle binary layout (Bundle-Version 2.0.0):
%%%   [ N : u256 LE (32 bytes)                ]   item count
%%%   [ entries : N * 64 bytes                ]   each = (size : u256 LE) || (id : 32 bytes)
%%%   [ items : concatenation of N items      ]   each item is `size` bytes
%%%
%%% Each item layout:
%%%   [ signature_type : u16 LE (2 bytes)     ]
%%%   [ signature      : sig_len bytes        ]
%%%   [ owner          : owner_len bytes      ]
%%%   [ target_marker  : 1 byte (0x00 / 0x01) ]
%%%   [ target         : 32 bytes (if marker=0x01) ]
%%%   [ anchor_marker  : 1 byte (0x00 / 0x01) ]
%%%   [ anchor         : 32 bytes (if marker=0x01) ]
%%%   [ tag_count      : u64 LE (8 bytes)     ]
%%%   [ tag_bytes_size : u64 LE (8 bytes)     ]
%%%   [ tag_bytes      : tag_bytes_size bytes ]
%%%   [ data           : remaining bytes      ]

-module(ar_bundle_parser).

-export([parse/1, item_id/1, decode_tags/1, is_anonymous/1]).
-export_type([bundle_item/0, tag/0, item_kind/0]).

-type tag() :: {Name :: binary(), Value :: binary()}.

-type item_kind() :: signed | anonymous.

-record(bundle_item, {
    id              :: binary(),     %% 32 bytes
    kind            :: item_kind(),
    signature_type  :: pos_integer(),
    signature       :: binary(),
    owner           :: binary(),
    target          :: binary() | undefined,
    anchor          :: binary() | undefined,
    tag_count       :: non_neg_integer(),
    tag_bytes       :: binary(),     %% raw Avro bytes (kept for deepHash)
    tags            :: [tag()],
    data            :: binary()
}).

-type bundle_item() :: #bundle_item{}.

%% Hard limits (mirrors docs/l2-bundle-chain-spec.md §6).
-define(MAX_ITEMS_PER_BUNDLE, 256).
-define(MAX_BUNDLE_DATA_SIZE, 1048576).   %% 1 MiB
-define(MAX_ITEM_DATA_SIZE,   32768).     %% 32 KiB

%% Signature type → (signature length, owner length).
%% Reference: ANS-104 §"Signature types".
%% Only type 1 (Arweave RSA-PSS 4096) is required for ChannelChain;
%% other types are accepted structurally so that future expansion does
%% not require parser changes.
sig_layout(1) -> {512, 512};   %% Arweave RSA-PSS 4096
sig_layout(2) -> {64, 32};     %% Ed25519
sig_layout(3) -> {65, 65};     %% Ethereum secp256k1
sig_layout(4) -> {64, 32};     %% Solana Ed25519
sig_layout(_) -> unknown.

%% @doc Parse an ANS-104 v2.0.0 bundle binary.
%% Returns {ok, [bundle_item()]} on success, {error, Reason} on malformed input.
-spec parse(binary()) -> {ok, [bundle_item()]} | {error, term()}.
parse(Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    if
        Size > ?MAX_BUNDLE_DATA_SIZE ->
            {error, {bundle_too_large, Size}};
        Size < 32 ->
            {error, bundle_truncated_header};
        true ->
            parse_header(Bin)
    end;
parse(_) ->
    {error, not_binary}.

parse_header(<<NBin:32/binary, Rest/binary>>) ->
    case decode_u256_le(NBin) of
        N when N > ?MAX_ITEMS_PER_BUNDLE ->
            {error, {too_many_items, N}};
        0 ->
            case Rest of
                <<>> -> {ok, []};
                _    -> {error, trailing_bytes_after_zero_count}
            end;
        N when byte_size(Rest) < N * 64 ->
            {error, entry_table_truncated};
        N ->
            EntryBytes = N * 64,
            <<EntryTableBin:EntryBytes/binary, ItemsBin/binary>> = Rest,
            case parse_entries(EntryTableBin, []) of
                {error, _} = E -> E;
                {ok, Entries}  -> parse_items(Entries, ItemsBin, [])
            end
    end.

parse_entries(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
parse_entries(<<SizeBin:32/binary, IdBin:32/binary, Rest/binary>>, Acc) ->
    Size = decode_u256_le(SizeBin),
    parse_entries(Rest, [{Size, IdBin} | Acc]).

parse_items([], <<>>, Acc) ->
    {ok, lists:reverse(Acc)};
parse_items([], _Trailing, _Acc) ->
    {error, trailing_bytes_after_items};
parse_items([{Size, _Id} | _], Bin, _Acc) when byte_size(Bin) < Size ->
    {error, item_payload_truncated};
parse_items([{Size, ExpectedId} | Rest], Bin, Acc) ->
    <<ItemBin:Size/binary, MoreBin/binary>> = Bin,
    case decode_item(ItemBin, ExpectedId) of
        {error, _} = E -> E;
        {ok, Item}     -> parse_items(Rest, MoreBin, [Item | Acc])
    end.

decode_item(<<SigTypeLE:2/binary, Body0/binary>>, ExpectedId) ->
    SigType = decode_u16_le(SigTypeLE),
    case sig_layout(SigType) of
        unknown ->
            {error, {unknown_signature_type, SigType}};
        {SigLen, OwnerLen} ->
            case Body0 of
                <<Sig:SigLen/binary, Owner:OwnerLen/binary, Body1/binary>> ->
                    case decode_optional_32(Body1) of
                        {error, _} = E -> E;
                        {Target, Body2} ->
                            case decode_optional_32(Body2) of
                                {error, _} = E -> E;
                                {Anchor, Body3} ->
                                    decode_tags_and_data(SigType, Sig, Owner,
                                        Target, Anchor, Body3, ExpectedId)
                            end
                    end;
                _ ->
                    {error, item_sig_or_owner_truncated}
            end
    end;
decode_item(_, _) ->
    {error, item_header_truncated}.

decode_optional_32(<<0:8, Rest/binary>>) ->
    {undefined, Rest};
decode_optional_32(<<1:8, V:32/binary, Rest/binary>>) ->
    {V, Rest};
decode_optional_32(_) ->
    {error, optional_field_truncated}.

decode_tags_and_data(SigType, Sig, Owner, Target, Anchor, Body, ExpectedId) ->
    case Body of
        <<TagCountLE:8/binary, TagBytesSizeLE:8/binary, Rest0/binary>> ->
            TagCount = decode_u64_le(TagCountLE),
            TagBytesSize = decode_u64_le(TagBytesSizeLE),
            case Rest0 of
                <<TagBytes:TagBytesSize/binary, Data/binary>> ->
                    DataSize = byte_size(Data),
                    if
                        DataSize > ?MAX_ITEM_DATA_SIZE ->
                            {error, {item_data_too_large, DataSize}};
                        true ->
                            finalize_item(SigType, Sig, Owner, Target, Anchor,
                                          TagCount, TagBytes, Data, ExpectedId)
                    end;
                _ ->
                    {error, tag_bytes_truncated}
            end;
        _ ->
            {error, tag_header_truncated}
    end.

finalize_item(SigType, Sig, Owner, Target, Anchor, TagCount, TagBytes, Data, ExpectedId) ->
    case decode_tags(TagBytes) of
        {error, _} = E -> E;
        {ok, Tags} when length(Tags) =/= TagCount ->
            {error, {tag_count_mismatch, TagCount, length(Tags)}};
        {ok, Tags} ->
            case classify_item(SigType, Sig, Owner, Target, Anchor, TagBytes, Data, Tags) of
                {error, _} = E -> E;
                {Kind, ComputedId} ->
                    case ComputedId of
                        ExpectedId ->
                            {ok, #bundle_item{
                                id = ComputedId,
                                kind = Kind,
                                signature_type = SigType,
                                signature = Sig,
                                owner = Owner,
                                target = Target,
                                anchor = Anchor,
                                tag_count = TagCount,
                                tag_bytes = TagBytes,
                                tags = Tags,
                                data = Data
                            }};
                        _ ->
                            {error, {item_id_mismatch, Kind, ExpectedId, ComputedId}}
                    end
            end
    end.

%% Classify the item as signed / anonymous, or reject as malformed.
%%
%% Anonymous (per docs/l2-bundle-chain-spec.md §2-2 (B)):
%%   signature_type == 1
%%   owner          == 512 × 0x00
%%   signature      == 512 × 0x00
%%   PoW-Nonce tag present
%% All four conditions must hold simultaneously. Partial-zero asymmetry
%% (only owner zero, only signature zero, missing PoW-Nonce) is rejected
%% so we never silently treat half-anonymous items as signed.
classify_item(SigType, Sig, Owner, Target, Anchor, TagBytes, Data, Tags) ->
    OwnerZero = is_zero_bytes(Owner),
    SigZero   = is_zero_bytes(Sig),
    PowNonce  = lists:keymember(<<"PoW-Nonce">>, 1, Tags),
    case {OwnerZero, SigZero, SigType, PowNonce} of
        {true, true, 1, true} ->
            {anonymous, anon_item_id(SigType, Owner, Target, Anchor, TagBytes, Data)};
        {true, true, 1, false} ->
            {error, anonymous_missing_pow_nonce};
        {true, true, _Other, _} ->
            {error, {anonymous_wrong_signature_type, SigType}};
        {true, false, _, _} ->
            {error, partial_zero_owner_only};
        {false, true, _, _} ->
            {error, partial_zero_signature_only};
        {false, false, _, _} ->
            {signed, item_id_from_signature(Sig)}
    end.

is_zero_bytes(Bin) when is_binary(Bin) ->
    Size = byte_size(Bin),
    Size > 0 andalso Bin =:= binary:copy(<<0>>, Size).

%% AnonItemID = SHA-256(deepHash(item)) per §2-4.
%% deepHash inputs follow the ANS-104 list verified in A3.
anon_item_id(SigType, Owner, Target, Anchor, TagBytes, Data) ->
    DeepHash = ar_deep_hash:hash([
        <<"dataitem">>,
        <<"1">>,
        integer_to_binary(SigType),
        Owner,
        target_or_empty(Target),
        target_or_empty(Anchor),
        TagBytes,
        Data
    ]),
    crypto:hash(sha256, DeepHash).

target_or_empty(undefined) -> <<>>;
target_or_empty(Bin) when is_binary(Bin) -> Bin.

%% @doc Whether the parsed item is the ChannelChain anonymous variant.
-spec is_anonymous(bundle_item()) -> boolean().
is_anonymous(#bundle_item{kind = anonymous}) -> true;
is_anonymous(#bundle_item{kind = signed})    -> false.

%% @doc The ItemID this parser used to validate the entry table.
%%   - signed item:    SHA-256(signature)            (standard ANS-104)
%%   - anonymous item: SHA-256(deepHash(item))       (ChannelChain extension)
-spec item_id(bundle_item()) -> binary().
item_id(#bundle_item{id = Id}) -> Id.

item_id_from_signature(Sig) ->
    crypto:hash(sha256, Sig).

%% Little-endian unsigned integer decoders.
%% ANS-104 fields are byte-reversed relative to most Erlang big-endian patterns,
%% so we decode by reversing then matching as big-endian.
decode_u16_le(<<A, B>>) ->
    <<V:16/big-unsigned-integer>> = <<B, A>>,
    V.

decode_u64_le(<<B0, B1, B2, B3, B4, B5, B6, B7>>) ->
    <<V:64/big-unsigned-integer>> = <<B7, B6, B5, B4, B3, B2, B1, B0>>,
    V.

decode_u256_le(Bin) when byte_size(Bin) =:= 32 ->
    Reversed = list_to_binary(lists:reverse(binary_to_list(Bin))),
    <<V:256/big-unsigned-integer>> = Reversed,
    V.

%%%-------------------------------------------------------------------
%%% Avro tag decoding
%%%
%%% Tag encoding per ANS-104 (Avro Array of Record{name, value}):
%%%   array  := block* end
%%%   block  := count (records) | -count block_size (records)
%%%   end    := 0           (zigzag varint)
%%%   record := name_string value_string
%%%   string := length:zigzag-varint  utf8_bytes
%%%
%%% A negative count signals a block whose total byte size follows; we
%%% accept and ignore the size hint, recovering the records by their
%%% absolute count.
%%%-------------------------------------------------------------------

%% @doc Decode an Avro-encoded tag block into [{Name, Value}, ...].
-spec decode_tags(binary()) -> {ok, [tag()]} | {error, term()}.
decode_tags(<<>>) ->
    {ok, []};
decode_tags(Bin) ->
    decode_tag_blocks(Bin, []).

decode_tag_blocks(Bin, Acc) ->
    case decode_zigzag_varint(Bin) of
        {error, _} = E -> E;
        {0, Rest} ->
            case Rest of
                <<>> -> {ok, lists:reverse(Acc)};
                _    -> {error, trailing_bytes_after_tag_end}
            end;
        {Count, Rest0} when Count > 0 ->
            case decode_tag_records(Count, Rest0, Acc) of
                {error, _} = E -> E;
                {ok, NewAcc, Rest1} -> decode_tag_blocks(Rest1, NewAcc)
            end;
        {Count, Rest0} when Count < 0 ->
            case decode_zigzag_varint(Rest0) of
                {error, _} = E -> E;
                {_BlockBytes, Rest1} ->
                    case decode_tag_records(-Count, Rest1, Acc) of
                        {error, _} = E -> E;
                        {ok, NewAcc, Rest2} -> decode_tag_blocks(Rest2, NewAcc)
                    end
            end
    end.

decode_tag_records(0, Rest, Acc) ->
    {ok, Acc, Rest};
decode_tag_records(N, Bin, Acc) when N > 0 ->
    case decode_avro_string(Bin) of
        {error, _} = E -> E;
        {Name, Rest0} ->
            case decode_avro_string(Rest0) of
                {error, _} = E -> E;
                {Value, Rest1} ->
                    decode_tag_records(N - 1, Rest1, [{Name, Value} | Acc])
            end
    end.

decode_avro_string(Bin) ->
    case decode_zigzag_varint(Bin) of
        {error, _} = E -> E;
        {Len, _} when Len < 0 -> {error, negative_string_length};
        {Len, Rest} ->
            case Rest of
                <<S:Len/binary, More/binary>> -> {S, More};
                _ -> {error, string_truncated}
            end
    end.

%% Avro long: zigzag-encoded variable-length integer (LSB-first 7-bit groups).
decode_zigzag_varint(Bin) ->
    decode_varint(Bin, 0, 0).

decode_varint(<<0:1, Group:7, Rest/binary>>, Shift, Acc) ->
    Raw = Acc bor (Group bsl Shift),
    {zigzag_to_signed(Raw), Rest};
decode_varint(<<1:1, Group:7, Rest/binary>>, Shift, Acc) ->
    NewAcc = Acc bor (Group bsl Shift),
    decode_varint(Rest, Shift + 7, NewAcc);
decode_varint(<<>>, _, _) ->
    {error, varint_truncated}.

zigzag_to_signed(N) ->
    (N bsr 1) bxor -(N band 1).
