%%% Smoke tests for the ar_bbs_validator → ar_bundle_validator hook
%%% added in C2.
%%%
%%% These tests exercise the *routing* added to ar_bbs_validator:validate/1
%%% — i.e. that Type=Bundle TXs are sent down the bundle pipeline and
%%% non-bundle ChannelChain TXs are not regressed. The deep
%%% per-item-through-bbs_validator path is covered by C3.

-module(ar_bbs_validator_bundle_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("arweave/include/ar.hrl").

%%%-------------------------------------------------------------------
%%% Routing (does not require ETS — fails before any item lookup)
%%%-------------------------------------------------------------------

bundle_carrier_missing_format_routes_into_bundle_validator_test() ->
    Tags = [
        {<<"App-Name">>,        <<"ChannelChain">>},
        {<<"Type">>,            <<"Bundle">>},
        %% Bundle-Format intentionally missing
        {<<"Bundle-Version">>,  <<"2.0.0">>},
        {<<"Bundle-PoW-Nonce">>, <<"0">>}
    ],
    Carrier = #tx{tags = Tags, data = <<>>},
    Result = ar_bbs_validator:validate(Carrier),
    ?assertMatch({error, <<"Bundle rejected:", _/binary>>}, Result).

bundle_carrier_with_bad_pow_routes_into_bundle_validator_test() ->
    Tags = [
        {<<"App-Name">>,         <<"ChannelChain">>},
        {<<"Type">>,             <<"Bundle">>},
        {<<"Bundle-Format">>,    <<"binary">>},
        {<<"Bundle-Version">>,   <<"2.0.0">>},
        {<<"Bundle-PoW-Nonce">>, <<"0">>}
    ],
    BundleBin = read_fixture("bundle_v2.bin"),
    Carrier = #tx{tags = Tags, data = BundleBin},
    Result = ar_bbs_validator:validate(Carrier),
    %% Default carrier PoW difficulty (24) is unreachable with nonce "0"
    ?assertMatch({error, <<"Bundle rejected:", _/binary>>}, Result).

%% A non-Bundle ChannelChain TX must NOT be sent through the bundle
%% validator — it should hit the legacy validate_channelchain_tx path.
%% We confirm this by giving a malformed Post (missing Board-Id) and
%% asserting we get the legacy error string, not the bundle error
%% prefix.
non_bundle_post_unaffected_test() ->
    Tags = [
        {<<"App-Name">>, <<"ChannelChain">>},
        {<<"Type">>,     <<"Post">>}
        %% Board-Id intentionally missing — legacy path should reject.
    ],
    TX = #tx{tags = Tags, data = <<>>},
    Result = ar_bbs_validator:validate(TX),
    ?assertMatch({error, _}, Result),
    {error, Msg} = Result,
    %% The legacy required-tag rejection does NOT start with "Bundle rejected:"
    case Msg of
        <<"Bundle rejected:", _/binary>> ->
            erlang:error({wrongly_routed_to_bundle_validator, Msg});
        _ -> ok
    end.

%% Non-ChannelChain TX (no App-Name tag) must short-circuit to ok
%% before either path. Sanity that we did not regress that early-out.
non_channelchain_tx_short_circuits_test() ->
    TX = #tx{tags = [{<<"App-Name">>, <<"OtherApp">>}], data = <<>>},
    ?assertEqual(ok, ar_bbs_validator:validate(TX)).

%%%-------------------------------------------------------------------
%%% Helpers
%%%-------------------------------------------------------------------

read_fixture(Name) ->
    Path = case filelib:is_file(filename:join(["test", "fixtures", Name])) of
        true  -> filename:join(["test", "fixtures", Name]);
        false -> filename:join(["apps", "arweave", "test", "fixtures", Name])
    end,
    {ok, Bin} = file:read_file(Path),
    Bin.
