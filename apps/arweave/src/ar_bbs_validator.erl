%% ar_bbs_validator.erl
%%
%% ChannelChain BBS 固有の TX バリデーション。
%% TX 受信時にデータサイズ・JSON形式・必須タグを検証し、不正TXを拒否する。

-module(ar_bbs_validator).

-export([validate/1]).

-include_lib("arweave/include/ar.hrl").

%% ── サイズ制限 ──
-define(MAX_POST_BODY, 10000).       %% 投稿本文: 10,000文字
-define(MAX_POST_LINES, 200).        %% 投稿本文: 200行
-define(MAX_POST_NAME, 30).          %% 投稿者名: 30文字
-define(MAX_THREAD_TITLE, 100).      %% スレタイ: 100文字
-define(MAX_BOARD_NAME, 50).         %% 板名: 50文字
-define(MAX_BOARD_DESC, 200).        %% 板説明: 200文字
-define(MAX_PROFILE_NAME, 30).       %% プロフィール名: 30文字
-define(MAX_PROFILE_BIO, 500).       %% プロフィールBio: 500文字
-define(MAX_DATA_SIZE, 32768).       %% TX data 最大サイズ (32KB)

%% @doc ChannelChain TX を検証する。
%% 戻り値: ok | {error, Reason}
validate(TX) ->
	case ar_admin:is_channelchain_tx(TX) of
		false -> ok; %% ChannelChain TX でなければスキップ
		true -> validate_channelchain_tx(TX)
	end.

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
						ok -> validate_data_content(TX, Type)
					end
			end
	end.

%% ── データサイズ検証 ──
validate_data_size(TX) ->
	case TX#tx.data_size > ?MAX_DATA_SIZE of
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
validate_required_tags(TX, <<"Profile">>) ->
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

%% ── データ内容検証 ──
validate_data_content(TX, <<"Post">>) ->
	case parse_json_data(TX) of
		{error, _} = E -> E;
		{ok, Json} ->
			Body = maps:get(<<"body">>, Json, <<>>),
			Name = maps:get(<<"name">>, Json, <<>>),
			case validate_string_length(Body, ?MAX_POST_BODY) of
				{error, _} -> {error, <<"Post body too long">>};
				ok ->
					case validate_line_count(Body, ?MAX_POST_LINES) of
						{error, _} -> {error, <<"Post body too many lines">>};
						ok ->
							case validate_string_length(Name, ?MAX_POST_NAME) of
								{error, _} -> {error, <<"Post name too long">>};
								ok -> ok
							end
					end
			end
	end;
validate_data_content(TX, <<"Thread">>) ->
	Title = get_tag(TX, <<"Thread-Title">>),
	case validate_string_length(Title, ?MAX_THREAD_TITLE) of
		{error, _} -> {error, <<"Thread title too long">>};
		ok -> ok
	end;
validate_data_content(TX, <<"Board">>) ->
	Name = get_tag(TX, <<"Board-Name">>),
	Desc = get_tag(TX, <<"Description">>),
	case validate_string_length(Name, ?MAX_BOARD_NAME) of
		{error, _} -> {error, <<"Board name too long">>};
		ok ->
			case Desc of
				undefined -> ok;
				_ -> case validate_string_length(Desc, ?MAX_BOARD_DESC) of
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
			case validate_string_length(DisplayName, ?MAX_PROFILE_NAME) of
				{error, _} -> {error, <<"Profile name too long">>};
				ok ->
					case validate_string_length(Bio, ?MAX_PROFILE_BIO) of
						{error, _} -> {error, <<"Profile bio too long">>};
						ok -> ok
					end
			end
	end;
validate_data_content(_TX, _Type) ->
	ok.

%% ── ヘルパー ──
get_tag(TX, TagName) ->
	case lists:keyfind(TagName, 1, TX#tx.tags) of
		{TagName, Value} -> Value;
		false ->
			%% base64url エンコードされたタグも検索
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
	%% UTF-8 文字数でカウント
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
