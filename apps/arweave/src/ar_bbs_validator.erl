%% ar_bbs_validator.erl
%%
%% ChannelChain BBS 固有の TX バリデーション。
%% TX 受信時にデータサイズ・JSON形式・必須タグを検証し、不正TXを拒否する。
%% Board-Config (ETS) の設定値を参照し、板ごとの制限を適用する。

-module(ar_bbs_validator).

-export([validate/1]).

-include_lib("arweave/include/ar.hrl").

%% ── ハード上限（Board-Config でこれを超えることはできない） ──
-define(HARD_MAX_POST_BODY, 10000).
-define(HARD_MAX_POST_LINES, 200).
-define(HARD_MAX_POST_NAME, 60).
-define(HARD_MAX_THREAD_TITLE, 200).
-define(HARD_MAX_BOARD_NAME, 100).
-define(HARD_MAX_BOARD_DESC, 500).
-define(HARD_MAX_PROFILE_NAME, 60).
-define(HARD_MAX_PROFILE_BIO, 1000).
-define(HARD_MAX_DATA_SIZE, 32768).

%% ── デフォルト値（Board-Config 未設定時） ──
-define(DEFAULT_MAX_POST_BODY, 10000).
-define(DEFAULT_MAX_POST_LINES, 200).
-define(DEFAULT_MAX_POST_NAME, 30).
-define(DEFAULT_MAX_THREAD_TITLE, 100).
-define(DEFAULT_MAX_BOARD_NAME, 50).
-define(DEFAULT_MAX_BOARD_DESC, 200).
-define(DEFAULT_MAX_PROFILE_NAME, 30).
-define(DEFAULT_MAX_PROFILE_BIO, 500).

%% ── ISO 639-1 言語コード（184 件）+ und (Undetermined, ISO 639-2) ──
-define(ISO_639_1_CODES, [
	<<"aa">>, <<"ab">>, <<"ae">>, <<"af">>, <<"ak">>, <<"am">>, <<"an">>, <<"ar">>,
	<<"as">>, <<"av">>, <<"ay">>, <<"az">>,
	<<"ba">>, <<"be">>, <<"bg">>, <<"bh">>, <<"bi">>, <<"bm">>, <<"bn">>, <<"bo">>,
	<<"br">>, <<"bs">>,
	<<"ca">>, <<"ce">>, <<"ch">>, <<"co">>, <<"cr">>, <<"cs">>, <<"cu">>, <<"cv">>,
	<<"cy">>,
	<<"da">>, <<"de">>, <<"dv">>, <<"dz">>,
	<<"ee">>, <<"el">>, <<"en">>, <<"eo">>, <<"es">>, <<"et">>, <<"eu">>,
	<<"fa">>, <<"ff">>, <<"fi">>, <<"fj">>, <<"fo">>, <<"fr">>, <<"fy">>,
	<<"ga">>, <<"gd">>, <<"gl">>, <<"gn">>, <<"gu">>, <<"gv">>,
	<<"ha">>, <<"he">>, <<"hi">>, <<"ho">>, <<"hr">>, <<"ht">>, <<"hu">>, <<"hy">>,
	<<"hz">>,
	<<"ia">>, <<"id">>, <<"ie">>, <<"ig">>, <<"ii">>, <<"ik">>, <<"io">>, <<"is">>,
	<<"it">>, <<"iu">>,
	<<"ja">>, <<"jv">>,
	<<"ka">>, <<"kg">>, <<"ki">>, <<"kj">>, <<"kk">>, <<"kl">>, <<"km">>, <<"kn">>,
	<<"ko">>, <<"kr">>, <<"ks">>, <<"ku">>, <<"kv">>, <<"kw">>, <<"ky">>,
	<<"la">>, <<"lb">>, <<"lg">>, <<"li">>, <<"ln">>, <<"lo">>, <<"lt">>, <<"lu">>,
	<<"lv">>,
	<<"mg">>, <<"mh">>, <<"mi">>, <<"mk">>, <<"ml">>, <<"mn">>, <<"mr">>, <<"ms">>,
	<<"mt">>, <<"my">>,
	<<"na">>, <<"nb">>, <<"nd">>, <<"ne">>, <<"ng">>, <<"nl">>, <<"nn">>, <<"no">>,
	<<"nr">>, <<"nv">>, <<"ny">>,
	<<"oc">>, <<"oj">>, <<"om">>, <<"or">>, <<"os">>,
	<<"pa">>, <<"pi">>, <<"pl">>, <<"ps">>, <<"pt">>,
	<<"qu">>,
	<<"rm">>, <<"rn">>, <<"ro">>, <<"ru">>, <<"rw">>,
	<<"sa">>, <<"sc">>, <<"sd">>, <<"se">>, <<"sg">>, <<"si">>, <<"sk">>, <<"sl">>,
	<<"sm">>, <<"sn">>, <<"so">>, <<"sq">>, <<"sr">>, <<"ss">>, <<"st">>, <<"su">>,
	<<"sv">>, <<"sw">>,
	<<"ta">>, <<"te">>, <<"tg">>, <<"th">>, <<"ti">>, <<"tk">>, <<"tl">>, <<"tn">>,
	<<"to">>, <<"tr">>, <<"ts">>, <<"tt">>, <<"tw">>, <<"ty">>,
	<<"ug">>, <<"uk">>, <<"ur">>, <<"uz">>,
	<<"ve">>, <<"vi">>, <<"vo">>,
	<<"wa">>, <<"wo">>,
	<<"xh">>,
	<<"yi">>, <<"yo">>,
	<<"za">>, <<"zh">>, <<"zu">>,
	<<"und">>
]).

%% @doc ChannelChain TX を検証する。
%% 戻り値: ok | {error, Reason}
%%
%% Type=Bundle (ANS-104 carrier) は ar_bundle_validator に委譲する。
%% その内部で各 item は pseudo TX 化されて再度 ar_bbs_validator:validate/1
%% に通るため、ChannelChain 標準の tag / data 制約は各 item に強制される。
validate(TX) ->
	case ar_admin:is_channelchain_tx(TX) of
		false -> ok;
		true ->
			case is_bundle_tx(TX) of
				true  -> validate_bundle_carrier(TX);
				false -> validate_channelchain_tx(TX)
			end
	end.

is_bundle_tx(TX) ->
	get_tag(TX, <<"Type">>) =:= <<"Bundle">>.

validate_bundle_carrier(TX) ->
	case ar_bundle_validator:validate_bundle(TX) of
		{ok, _PseudoTXs} -> ok;
		{error, Reason}  -> {error, format_bundle_error(Reason)}
	end.

format_bundle_error(Reason) when is_binary(Reason) -> Reason;
format_bundle_error(Reason) ->
	iolist_to_binary(io_lib:format("Bundle rejected: ~p", [Reason])).

validate_channelchain_tx(TX) ->
	Type = get_tag(TX, <<"Type">>),
	case Type of
		undefined -> {error, <<"Missing Type tag">>};
		_ ->
			case validate_data_size(TX) of
				{error, _} = E -> E;
				ok ->
					case validate_required_tags(TX, Type) of
						{error, _} = E -> E;
						ok ->
							case validate_optional_tags(TX, Type) of
								{error, _} = E -> E;
								ok -> validate_data_content(TX, Type)
							end
					end
			end
	end.

%% ── データサイズ検証 ──
validate_data_size(TX) ->
	case TX#tx.data_size > ?HARD_MAX_DATA_SIZE of
		true -> {error, <<"TX data too large">>};
		false -> ok
	end.

%% ── 必須タグ検証 ──
validate_required_tags(TX, <<"Post">>) ->
	require_tags(TX, [<<"Board-Id">>, <<"Thread-Id">>]);
validate_required_tags(TX, <<"Thread">>) ->
	require_tags(TX, [<<"Board-Id">>, <<"Thread-Id">>, <<"Thread-Title">>]);
validate_required_tags(TX, <<"Board">>) ->
	require_tags(TX, [<<"Board-Id">>, <<"Board-Name">>]);
validate_required_tags(TX, <<"Report">>) ->
	require_tags(TX, [<<"Target-TX">>, <<"Reason">>]);
validate_required_tags(TX, <<"Priority-Report">>) ->
	require_tags(TX, [<<"Target-TX">>, <<"Reason">>]);
validate_required_tags(_TX, <<"Profile">>) ->
	ok;
validate_required_tags(TX, <<"Board-Config">>) ->
	require_tags(TX, [<<"Board-Id">>, <<"Config-Key">>]);
validate_required_tags(_TX, _Type) ->
	ok.

require_tags(_TX, []) -> ok;
require_tags(TX, [Tag | Rest]) ->
	case get_tag(TX, Tag) of
		undefined -> {error, <<"Missing required tag: ", Tag/binary>>};
		<<>> -> {error, <<"Empty required tag: ", Tag/binary>>};
		_ -> require_tags(TX, Rest)
	end.

%% ── 任意タグ検証 ──
%% Board TX に Language タグが付いている場合は ISO 639-1 コード（または und）であること。
validate_optional_tags(TX, <<"Board">>) ->
	validate_language_tag(TX);
validate_optional_tags(_TX, _Type) ->
	ok.

validate_language_tag(TX) ->
	case get_tag(TX, <<"Language">>) of
		undefined -> ok;
		<<>> -> ok;
		Code when is_binary(Code) ->
			case lists:member(Code, ?ISO_639_1_CODES) of
				true -> ok;
				false -> {error, <<"Invalid Language tag: must be ISO 639-1 code">>}
			end
	end.

%% ── データ内容検証（Board-Config 参照） ──
validate_data_content(TX, <<"Post">>) ->
	BoardId = get_tag(TX, <<"Board-Id">>),
	MaxBody = get_board_limit(BoardId, <<"max_body_bytes">>, ?DEFAULT_MAX_POST_BODY, ?HARD_MAX_POST_BODY),
	MaxName = get_board_limit(BoardId, <<"max_name_bytes">>, ?DEFAULT_MAX_POST_NAME, ?HARD_MAX_POST_NAME),
	case parse_json_data(TX) of
		{error, _} = E -> E;
		{ok, Json} ->
			Body = maps:get(<<"body">>, Json, <<>>),
			Name = maps:get(<<"name">>, Json, <<>>),
			case validate_string_length(Body, MaxBody) of
				{error, _} -> {error, <<"Post body too long">>};
				ok ->
					case validate_line_count(Body, ?HARD_MAX_POST_LINES) of
						{error, _} -> {error, <<"Post body too many lines">>};
						ok ->
							case validate_string_length(Name, MaxName) of
								{error, _} -> {error, <<"Post name too long">>};
								ok -> ok
							end
					end
			end
	end;
validate_data_content(TX, <<"Thread">>) ->
	BoardId = get_tag(TX, <<"Board-Id">>),
	MaxTitle = get_board_limit(BoardId, <<"max_title_bytes">>, ?DEFAULT_MAX_THREAD_TITLE, ?HARD_MAX_THREAD_TITLE),
	Title = get_tag(TX, <<"Thread-Title">>),
	case validate_string_length(Title, MaxTitle) of
		{error, _} -> {error, <<"Thread title too long">>};
		ok -> ok
	end;
validate_data_content(TX, <<"Board">>) ->
	Name = get_tag(TX, <<"Board-Name">>),
	Desc = get_tag(TX, <<"Description">>),
	case validate_string_length(Name, ?HARD_MAX_BOARD_NAME) of
		{error, _} -> {error, <<"Board name too long">>};
		ok ->
			case Desc of
				undefined -> ok;
				_ -> case validate_string_length(Desc, ?HARD_MAX_BOARD_DESC) of
					{error, _} -> {error, <<"Board description too long">>};
					ok -> ok
				end
			end
	end;
validate_data_content(TX, <<"Profile">>) ->
	case parse_json_data(TX) of
		{error, _} = E -> E;
		{ok, Json} ->
			DisplayName = maps:get(<<"displayName">>, Json, <<>>),
			Bio = maps:get(<<"bio">>, Json, <<>>),
			case validate_string_length(DisplayName, ?HARD_MAX_PROFILE_NAME) of
				{error, _} -> {error, <<"Profile name too long">>};
				ok ->
					case validate_string_length(Bio, ?HARD_MAX_PROFILE_BIO) of
						{error, _} -> {error, <<"Profile bio too long">>};
						ok -> ok
					end
			end
	end;
validate_data_content(_TX, _Type) ->
	ok.

%% ── Board-Config からの制限値取得 ──
%% Board-Config の値 > 0 かつ HardMax 以下ならその値を使う。
%% それ以外はデフォルト値を使う。
get_board_limit(undefined, _Key, Default, _HardMax) -> Default;
get_board_limit(BoardId, Key, Default, HardMax) ->
	case ar_admin:get_board_config(BoardId, Key) of
		undefined -> Default;
		ValBin ->
			try
				Val = binary_to_integer(ValBin),
				case Val > 0 andalso Val =< HardMax of
					true -> Val;
					false -> Default
				end
			catch _:_ -> Default
			end
	end.

%% ── ヘルパー ──
get_tag(TX, TagName) ->
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false ->
			get_tag_decoded(TX#tx.tags, TagName)
	end.

get_tag_decoded([], _TagName) -> undefined;
get_tag_decoded([{EncodedName, EncodedValue} | Rest], TagName) ->
	try
		case ar_util:decode(EncodedName) of
			TagName -> ar_util:decode(EncodedValue);
			_ -> get_tag_decoded(Rest, TagName)
		end
	catch _:_ ->
		get_tag_decoded(Rest, TagName)
	end.

parse_json_data(TX) ->
	Data = TX#tx.data,
	case Data of
		<<>> -> {ok, #{}};
		_ ->
			try
				{ok, jiffy:decode(Data, [return_maps])}
			catch _:_ ->
				{error, <<"Invalid JSON in TX data">>}
			end
	end.

validate_string_length(undefined, _Max) -> ok;
validate_string_length(Bin, Max) when is_binary(Bin) ->
	Len = string:length(unicode:characters_to_list(Bin)),
	case Len > Max of
		true -> {error, <<"String too long">>};
		false -> ok
	end;
validate_string_length(_, _Max) -> ok.

validate_line_count(undefined, _Max) -> ok;
validate_line_count(Bin, Max) when is_binary(Bin) ->
	Lines = length(binary:split(Bin, <<"\n">>, [global])),
	case Lines > Max of
		true -> {error, <<"Too many lines">>};
		false -> ok
	end;
validate_line_count(_, _Max) -> ok.
