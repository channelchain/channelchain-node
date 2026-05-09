%%% @doc Per-item verifier for ChannelChain L2 bundle items.
%%%
%%% B1 scope: signed-item RSA-PSS verification.
%%%   - signature_type = 1 (Arweave RSA-4096) only.
%%%   - PSS padding, MGF1-SHA256, salt length = AUTO / max (-2),
%%%     public exponent = 65537. These match arweave-js / arbundles —
%%%     both omit the saltLength option in Node.js, which defaults to
%%%     RSA_PSS_SALTLEN_AUTO (max: keylen - hLen - 2).
%%%   - The signed message is the deepHash byte string built per ANS-104:
%%%       deep_hash(["dataitem", "1", "<sigtype>", owner, target, anchor,
%%%                  tag_bytes, data])
%%%     i.e. exactly the input cross-checked in A3.
%%%
%%% Anonymous items (kind = anonymous) are out of scope for this module
%%% and return {error, anonymous_not_verifiable_here}; their PoW check
%%% lives in B2.

-module(ar_bundle_verify).

-export([verify_item/1, deep_hash/1]).

-include_lib("arweave/include/ar_bundle.hrl").

%% Arweave RSA convention.
-define(ARWEAVE_RSA_EXPONENT, <<1, 0, 1>>).   %% 65537, big-endian
-define(ARWEAVE_RSA_DIGEST,    sha256).
-define(ARWEAVE_RSA_SALT_LEN,  -2).            %% auto / max — matches Node.js default

%% @doc Verify an item parsed by ar_bundle_parser:parse/1.
-spec verify_item(#bundle_item{}) -> ok | {error, term()}.
verify_item(#bundle_item{kind = anonymous}) ->
    {error, anonymous_not_verifiable_here};
verify_item(#bundle_item{kind = signed, signature_type = 1} = Item) ->
    verify_arweave_rsa(Item);
verify_item(#bundle_item{kind = signed, signature_type = Other}) ->
    {error, {unsupported_signature_type, Other}}.

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
