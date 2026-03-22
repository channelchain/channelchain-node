#!/bin/bash

DATA_DIR="/data"
RELEASE_DIR="/app/_build/prod/rel/arweave/bin"
ERL="erl"

# ピアリストを引数に変換
PEER_ARGS=""
FIRST_PEER_HOST=""
FIRST_PEER_PORT=""
if [ -n "$PEERS" ]; then
  IFS=',' read -ra PEER_LIST <<< "$PEERS"
  for peer in "${PEER_LIST[@]}"; do
    PEER_ARGS="$PEER_ARGS peer $peer"
  done
  # 最初のピアのホスト:ポートを解析
  FIRST_PEER="${PEER_LIST[0]}"
  FIRST_PEER_HOST="${FIRST_PEER%%:*}"
  FIRST_PEER_PORT="${FIRST_PEER##*:}"
fi

# マイニングフラグ
MINE_ARG=""
if [ "$MINE" = "true" ]; then
  MINE_ARG="mine"
fi

# Wallet事前生成: walletがなければErlangで生成し、アドレスを取得する。
# これにより初回起動から packed (spora_2_6) ストレージモジュールを使える。
ensure_wallet() {
  local WALLET_DIR="$DATA_DIR/wallets"
  local WALLET_FILE=$(ls "$WALLET_DIR"/arweave_keyfile_*.json 2>/dev/null | head -1)
  if [ -n "$WALLET_FILE" ]; then
    return 0
  fi
  echo "==> Generating wallet..."
  mkdir -p "$WALLET_DIR"
  $ERL -noshell -eval '
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

# マイニングアドレスとストレージモジュール (SPoRA マイニングに必要)
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
  echo "==> Mining address: $MINING_ADDR (packed spora_2_6)"
else
  echo "==> ERROR: Could not determine mining address"
  exit 1
fi

# 最初のピアが起動するまで待つ関数
wait_for_peer() {
  if [ -n "$FIRST_PEER_HOST" ]; then
    echo "==> Waiting for peer $FIRST_PEER_HOST:$FIRST_PEER_PORT to be reachable..."
    until nc -z "$FIRST_PEER_HOST" "$FIRST_PEER_PORT" 2>/dev/null; do
      sleep 3
    done
    echo "==> Peer $FIRST_PEER_HOST:$FIRST_PEER_PORT is reachable!"
    sleep 5
  fi
}

# 初回起動: SEEDノードはgenesisを生成、PEERノードはJOIN
if [ ! -f "$DATA_DIR/.initialized" ]; then
  touch "$DATA_DIR/.initialized"
  if [ -z "$PEER_ARGS" ]; then
    echo "==> Initializing ChannelChain SEED node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      init \
      data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG \
      $MINING_ADDR_ARG \
      $MINE_ARG
  else
    wait_for_peer
    echo "==> Joining ChannelChain network as PEER node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG \
      $MINING_ADDR_ARG \
      $MINE_ARG \
      $PEER_ARGS
  fi
else
  wait_for_peer
  echo "==> Restarting ChannelChain node: $NODE_NAME"
  if [ -z "$PEER_ARGS" ]; then
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      start_from_latest_state \
      $STORAGE_MODULE_ARG \
      $MINING_ADDR_ARG \
      $MINE_ARG
  else
    echo "==> Rejoining network from peers: $PEER_ARGS"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $STORAGE_MODULE_ARG \
      $MINING_ADDR_ARG \
      $MINE_ARG \
      $PEER_ARGS
  fi
fi
