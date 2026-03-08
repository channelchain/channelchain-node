#!/bin/bash

DATA_DIR="/data"
RELEASE_DIR="/app/_build/prod/rel/arweave/bin"

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

# 最初のピアが起動するまで待つ関数
wait_for_peer() {
  if [ -n "$FIRST_PEER_HOST" ]; then
    echo "==> Waiting for peer $FIRST_PEER_HOST:$FIRST_PEER_PORT to be reachable..."
    until nc -z "$FIRST_PEER_HOST" "$FIRST_PEER_PORT" 2>/dev/null; do
      sleep 3
    done
    echo "==> Peer $FIRST_PEER_HOST:$FIRST_PEER_PORT is reachable!"
    # 少し余分に待ってノードが完全に初期化されるのを待つ
    sleep 5
  fi
}

# 初回起動時にGenesisブロックを生成
if [ ! -f "$DATA_DIR/.initialized" ]; then
  touch "$DATA_DIR/.initialized"
  if [ -z "$PEER_ARGS" ]; then
    echo "==> Initializing PermaBoard SEED node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      init \
      data_dir "$DATA_DIR" \
      $MINE_ARG
  else
    wait_for_peer
    echo "==> Joining PermaBoard network as PEER node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $MINE_ARG \
      $PEER_ARGS
  fi
else
  # 再起動時もピアが戻るまで少し待つ
  wait_for_peer
  echo "==> Starting PermaBoard node (from local state): $NODE_NAME"
  exec $RELEASE_DIR/arweave foreground \
    data_dir "$DATA_DIR" \
    start_from_latest_state \
    $MINE_ARG \
    $PEER_ARGS
fi
