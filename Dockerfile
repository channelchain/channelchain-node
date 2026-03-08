FROM erlang:26

WORKDIR /app

# Arweave Fork のソースをコピー（フォーク後のソースが必要）
COPY . .

# 依存関係（C/C++ NIFコンパイル用）をインストール
RUN apt-get update && apt-get install -y cmake gcc g++ git make libssl-dev netcat-openbsd

# 依存関係のインストールとビルド
# We will run `rebar3 as prod release` through a builder container bound to the _build directory.
COPY config/genesis_block.json /app/config/genesis_block.json

# ポート公開
EXPOSE 1984

# 起動スクリプト
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
