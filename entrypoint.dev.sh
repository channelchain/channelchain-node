#!/bin/bash
set -e

DATA_DIR="/data"
RELEASE_DIR="/src/_build/prod/rel/arweave/bin"

# NIF のクリーン（ホスト側バイナリ / CMake キャッシュの不整合対応）
clean_host_nifs() {
  # CMake キャッシュが /app 向けに作られている場合はクリーン
  if grep -rq '/app/' /src/apps/arweave/lib/RandomX/build512/CMakeCache.txt 2>/dev/null; then
    echo "==> Cleaning stale CMake caches..."
    rm -rf /src/apps/arweave/lib/RandomX/build512
    rm -rf /src/apps/arweave/lib/RandomX/build4096
    rm -rf /src/apps/arweave/lib/RandomX/buildsquared
    rm -rf /src/apps/arweave/lib/secp256k1/build
  fi

  # .so が存在しないか、アーキテクチャが異なる場合はクリーン
  if [ -f /src/apps/arweave/priv/rx512_arweave.so ]; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      file /src/apps/arweave/priv/rx512_arweave.so 2>/dev/null | grep -q "aarch64" && return 0
    else
      file /src/apps/arweave/priv/rx512_arweave.so 2>/dev/null | grep -q "x86-64" && return 0
    fi
  fi

  echo "==> Cleaning NIF binaries for rebuild..."
  find /src/apps/arweave/lib -name '*.o' -o -name '*.a' -o -name '*.so' | xargs rm -f 2>/dev/null
  find /src/apps/arweave/c_src -name '*.o' -o -name '*.a' | xargs rm -f 2>/dev/null
  rm -f /src/apps/arweave/priv/*.so
}

# openssl-sha-lite を正しいアーキテクチャで configure
configure_openssl() {
  cd /src/apps/arweave/lib/openssl-sha-lite
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    # Makefile の -m64 フラグを除去（ARM では不要）
    if grep -q '\-m64' Makefile 2>/dev/null; then
      echo "==> Reconfiguring openssl-sha-lite for ARM..."
      make clean 2>/dev/null || true
      perl Configure linux-aarch64 no-shared no-threads no-asm -fPIC 2>/dev/null || true
    fi
  fi
  cd /src
}

# 差分ビルド
build() {
  echo "==> Building ChannelChain (incremental)..."
  cd /src
  clean_host_nifs
  configure_openssl
  rebar3 get-deps 2>/dev/null || true
  rebar3 as prod release
  echo "==> Build complete."
}

# ビルド成果物がなければフルビルド、あれば差分ビルド
if [ ! -f "$RELEASE_DIR/arweave" ]; then
  echo "==> First build (this may take a few minutes)..."
  build
else
  echo "==> Incremental build..."
  build
fi

# 以下は通常の entrypoint.sh と同じ起動ロジック

PEER_ARGS=""
FIRST_PEER_HOST=""
FIRST_PEER_PORT=""
if [ -n "$PEERS" ]; then
  IFS=',' read -ra PEER_LIST <<< "$PEERS"
  for peer in "${PEER_LIST[@]}"; do
    PEER_ARGS="$PEER_ARGS peer $peer"
  done
  FIRST_PEER="${PEER_LIST[0]}"
  FIRST_PEER_HOST="${FIRST_PEER%%:*}"
  FIRST_PEER_PORT="${FIRST_PEER##*:}"
fi

MINE_ARG=""
if [ "$MINE" = "true" ]; then
  MINE_ARG="mine"
fi

# Wallet 生成
ensure_wallet() {
  local WALLET_DIR="$DATA_DIR/wallets"
  local WALLET_FILE=$(ls "$WALLET_DIR"/arweave_keyfile_*.json 2>/dev/null | head -1)
  if [ -n "$WALLET_FILE" ]; then
    return 0
  fi
  echo "==> Generating wallet..."
  mkdir -p "$WALLET_DIR"
  erl -noshell -eval '
    {[E, N], [E, N, D, P1, P2, E1, E2, C]} =
        crypto:generate_key(rsa, {4096, 65537}),
    Encode = fun(Bin) ->
        B64 = base64:encode(Bin),
        B64a = binary:replace(B64, <<"+">>, <<"-">>, [global]),
        B64b = binary:replace(B64a, <<"/">>, <<"_">>, [global]),
        binary:replace(B64b, <<"=">>, <<>>, [global])
    end,
    Addr = Encode(crypto:hash(sha256, N)),
    JWK = io_lib:format(
        "{\"kty\":\"RSA\",\"ext\":true,\"e\":\"~s\",\"n\":\"~s\","
        "\"d\":\"~s\",\"p\":\"~s\",\"q\":\"~s\","
        "\"dp\":\"~s\",\"dq\":\"~s\",\"qi\":\"~s\"}",
        [Encode(E), Encode(N), Encode(D),
         Encode(P1), Encode(P2), Encode(E1), Encode(E2), Encode(C)]),
    Filename = "'"$WALLET_DIR"'/arweave_keyfile_" ++ binary_to_list(Addr) ++ ".json",
    ok = file:write_file(Filename, list_to_binary(JWK)),
    io:format("~s~n", [Addr]),
    halt(0).
  '
}

ensure_wallet

if [ -z "$MINING_ADDR" ]; then
  WALLET_FILE=$(ls "$DATA_DIR"/wallets/arweave_keyfile_*.json 2>/dev/null | head -1)
  if [ -n "$WALLET_FILE" ]; then
    MINING_ADDR=$(basename "$WALLET_FILE" .json | sed 's/arweave_keyfile_//')
  fi
fi

MINING_ADDR_ARG=""
if [ -n "$MINING_ADDR" ]; then
  STORAGE_MODULE_ARG="storage_module 0,$MINING_ADDR"
  MINING_ADDR_ARG="mining_addr $MINING_ADDR"
  echo "==> Mining address: $MINING_ADDR"
fi

wait_for_peer() {
  if [ -n "$FIRST_PEER_HOST" ]; then
    echo "==> Waiting for peer $FIRST_PEER_HOST:$FIRST_PEER_PORT..."
    until nc -z "$FIRST_PEER_HOST" "$FIRST_PEER_PORT" 2>/dev/null; do
      sleep 3
    done
    echo "==> Peer reachable!"
    sleep 5
  fi
}

if [ ! -f "$DATA_DIR/.initialized" ]; then
  touch "$DATA_DIR/.initialized"
  if [ -z "$PEER_ARGS" ]; then
    echo "==> Initializing SEED node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      init data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG $MINING_ADDR_ARG $MINE_ARG
  else
    wait_for_peer
    echo "==> Joining as PEER node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG $MINING_ADDR_ARG $MINE_ARG $PEER_ARGS
  fi
else
  wait_for_peer
  echo "==> Restarting node: $NODE_NAME"
  if [ -z "$PEER_ARGS" ]; then
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" start_from_latest_state \
      $STORAGE_MODULE_ARG $MINING_ADDR_ARG $MINE_ARG
  else
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG $MINING_ADDR_ARG $MINE_ARG $PEER_ARGS
  fi
fi
