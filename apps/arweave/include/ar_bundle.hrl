%%% Shared types for ChannelChain L2 bundle modules.
%%% See docs/l2-bundle-chain-spec.md.
%%%
%%% This header is internal to ar_bundle_* modules. External callers
%%% should use the parser/verifier APIs (parse/1, item_id/1,
%%% is_anonymous/1, verify_item/1).

-ifndef(AR_BUNDLE_HRL).
-define(AR_BUNDLE_HRL, true).

%% Anonymous-item sentinels (§2-2 (B)).
-define(ANON_OWNER_SIZE, 512).
-define(ANON_SIG_SIZE,   512).

-record(bundle_item, {
    id              :: binary(),                 %% 32 bytes
    kind            :: signed | anonymous,
    signature_type  :: pos_integer(),
    signature       :: binary(),
    owner           :: binary(),                 %% RSA modulus N for sig_type=1
    target          :: binary() | undefined,
    anchor          :: binary() | undefined,
    tag_count       :: non_neg_integer(),
    tag_bytes       :: binary(),                 %% raw Avro bytes (deepHash input)
    tags            :: [{binary(), binary()}],
    data            :: binary()
}).

-endif.
