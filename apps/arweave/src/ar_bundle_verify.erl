%%% @doc Per-item verifier for ChannelChain L2 bundle items.
%%%
%%% Signed-item path (B1):
%%%   - signature_type = 1 (Arweave RSA-4096) only.
%%%   - PSS padding, MGF1-SHA256, salt length = AUTO / max (-2),
%%%     public exponent = 65537. These match arweave-js / arbundles —
%%%     both omit the saltLength option in Node.js, which defaults to
%%%     RSA_PSS_SALTLEN_AUTO (max: keylen - hLen - 2).
%%%   - Signed message: deep_hash(["dataitem", "1", "<sigtype>", owner,
%%%     target, anchor, tag_bytes, data]). Matches A3 cross-check.
%%%
%%% Anonymous-item path (B2):
%%%   - Mirrors the existing ChannelChain anonymous-TX PoW rule
%%%     (ar_pow_verify): SHA-256(item.data || nonce) must have
%%%     `Difficulty` leading zero bits.
%%%   - The nonce comes from the `PoW-Nonce` tag (already required by
%%%     the parser's anonymous classification).
%%%   - In production the difficulty is taken from
%%%     ar_pow_verify:get_difficulty_for_board(Board-Id-tag-value).
%%%     verify_item/2 accepts {difficulty, N} so unit tests do not
%%%     depend on the live ETS difficulty cache.

-module(ar_bundle_verify).

-export([verify_item/1, verify_item/2, deep_hash/1, check_leading_zeros/2]).

-include_lib("arweave/include/ar_bundle.hrl").

%% Arweave RSA convention.
-define(ARWEAVE_RSA_EXPONENT, <<1, 0, 1>>).   %% 65537, big-endian
-define(ARWEAVE_RSA_DIGEST,    sha256).
-define(ARWEAVE_RSA_SALT_LEN,  -2).            %% auto / max — matches Node.js default

%% @doc Verify an item parsed by ar_bundle_parser:parse/1.
%% In production this resolves the PoW difficulty for anonymous items
%% from ar_pow_verify; tests should call verify_item/2.
-spec verify_item(#bundle_item{}) -> ok | {error, term()}.
verify_item(Item) -> verify_item(Item, []).

-spec verify_item(#bundle_item{}, Opts :: [{difficulty, integer()}])
    -> ok | {error, term()}.
verify_item(#bundle_item{kind = signed, signature_type = 1} = Item, _Opts) ->
    verify_arweave_rsa(Item);
verify_item(#bundle_item{kind = signed, signature_type = Other}, _Opts) ->
    {error, {unsupported_signature_type, Other}};
verify_item(#bundle_item{kind = anonymous} = Item, Opts) ->
    verify_anonymous_pow(Item, Opts).

verify_arweave_rsa(#bundle_item{signature = Sig, owner = Owner} = Item) ->
    Msg = deep_hash(Item),
    Key = [?ARWEAVE_RSA_EXPONENT, Owner],
    Opts = [{rsa_padding, rsa_pkcs1_pss_padding},
            {rsa_pss_saltlen, ?ARWEAVE_RSA_SALT_LEN},
            {rsa_mgf1_md, ?ARWEAVE_RSA_DIGEST}],
    case crypto:verify(rsa, ?ARWEAVE_RSA_DIGEST, Msg, Sig, Key, Opts) of
        true  -> ok;
        false -> {error, bad_signature}
    end.

%% @doc Compute the ANS-104 deepHash bytes for an item.
%% Input list mirrors arbundles' DataItem.getSignatureData() and was
%% byte-equal to arbundles in A3.
-spec deep_hash(#bundle_item{}) -> binary().
deep_hash(#bundle_item{
        signature_type = SigType,
        owner          = Owner,
        target         = Target,
        anchor         = Anchor,
        tag_bytes      = TagBytes,
        data           = Data}) ->
    ar_deep_hash:hash([
        <<"dataitem">>,
        <<"1">>,
        integer_to_binary(SigType),
        Owner,
        opt(Target),
        opt(Anchor),
        TagBytes,
        Data
    ]).

opt(undefined) -> <<>>;
opt(Bin) when is_binary(Bin) -> Bin.

%%%-------------------------------------------------------------------
%%% Anonymous PoW verification
%%%-------------------------------------------------------------------

verify_anonymous_pow(#bundle_item{tags = Tags, data = Data}, Opts) ->
    case lists:keyfind(<<"PoW-Nonce">>, 1, Tags) of
        false ->
            %% Should not occur — parser's classify_item/8 already
            %% requires PoW-Nonce for anonymous items, but treat as a
            %% defensive error if a downstream caller hand-builds a
            %% bundle_item record.
            {error, missing_pow_nonce};
        {_, Nonce} ->
            case effective_difficulty(Tags, Opts) of
                {error, _} = E -> E;
                Difficulty ->
                    Hash = crypto:hash(sha256, <<Data/binary, Nonce/binary>>),
                    case check_leading_zeros(Hash, Difficulty) of
                        true  -> ok;
                        false -> {error, bad_pow}
                    end
            end
    end.

effective_difficulty(Tags, Opts) when is_list(Opts) ->
    case lists:keyfind(difficulty, 1, Opts) of
        {difficulty, N} when is_integer(N), N >= 0 -> N;
        false -> board_difficulty_from_tags(Tags);
        _ -> {error, invalid_difficulty_option}
    end.

board_difficulty_from_tags(Tags) ->
    BoardId = case lists:keyfind(<<"Board-Id">>, 1, Tags) of
        {_, B} -> B;
        false  -> undefined
    end,
    %% Production path: defer to the live difficulty index. We tolerate
    %% the call failing (e.g. ETS not running in some test setups) and
    %% surface a structured error rather than crash.
    try ar_pow_verify:get_difficulty_for_board(BoardId)
    catch _:_ -> {error, no_difficulty_source}
    end.

%% Returns true iff the first `Bits` bits of Hash are zero.
%% Local implementation so this module remains useful in test
%% environments that do not load ar_pow_verify.
-spec check_leading_zeros(binary(), non_neg_integer()) -> boolean().
check_leading_zeros(_Hash, 0) -> true;
check_leading_zeros(<<Byte:8, Rest/binary>>, Bits) when Bits >= 8 ->
    Byte =:= 0 andalso check_leading_zeros(Rest, Bits - 8);
check_leading_zeros(<<Byte:8, _/binary>>, Bits) when Bits > 0 ->
    Mask = 16#FF bsl (8 - Bits),
    (Byte band Mask) =:= 0;
check_leading_zeros(<<>>, _Bits) ->
    false.
