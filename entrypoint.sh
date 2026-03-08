#!/bin/bash
set -e

DATA_DIR="/data"
RELEASE_DIR="/app/_build/prod/rel/arweave/bin"

# ピアリストを引数に変換
PEER_ARGS=""
if [ -n "$PEERS" ]; then
  IFS=',' read -ra PEER_LIST <<< "$PEERS"
  for peer in "${PEER_LIST[@]}"; do
    PEER_ARGS="$PEER_ARGS peer $peer"
  done
fi

# マイニングフラグ
MINE_ARG=""
if [ "$MINE" = "true" ]; then
  MINE_ARG="mine"
fi

# 初回起動時にGenesisブロックを生成
if [ ! -f "$DATA_DIR/.initialized" ]; then
  echo "==> Initializing PermaBoard node: $NODE_NAME"
  $RELEASE_DIR/arweave foreground \
    init \
    data_dir "$DATA_DIR" \
    $MINE_ARG \
    $PEER_ARGS
  touch "$DATA_DIR/.initialized"
else
  echo "==> Starting PermaBoard node: $NODE_NAME"
  $RELEASE_DIR/arweave foreground \
    data_dir "$DATA_DIR" \
    $MINE_ARG \
    $PEER_ARGS
fi
