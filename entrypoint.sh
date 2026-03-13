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

# 初回起動: SEEDノードはgenesisを生成、PEERノードはJOIN
if [ ! -f "$DATA_DIR/.initialized" ]; then
  touch "$DATA_DIR/.initialized"
  if [ -z "$PEER_ARGS" ]; then
    # SEEDノード: genesis生成してスタート
    echo "==> Initializing ChannelChain SEED node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      init \
      data_dir "$DATA_DIR" \
      $MINE_ARG
  else
    # PEERノード: SEEDが準備できるまで待ってからJOIN
    wait_for_peer
    echo "==> Joining ChannelChain network as PEER node: $NODE_NAME"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $MINE_ARG \
      $PEER_ARGS
  fi
else
  # 再起動時: ピアとの接続を確認してから通常起動
  # start_from_latest_stateは使わず、ピアから再同期する
  wait_for_peer
  echo "==> Restarting ChannelChain node: $NODE_NAME"
  if [ -z "$PEER_ARGS" ]; then
    # SEEDノードの再起動: ローカル状態から復旧を試みる
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      start_from_latest_state \
      $MINE_ARG
  else
    # PEERノードの再起動: ピアから再同期（start_from_latest_stateは使わない）
    echo "==> Rejoining network from peers: $PEER_ARGS"
    exec $RELEASE_DIR/arweave foreground \
      data_dir "$DATA_DIR" \
      $MINE_ARG \
      $PEER_ARGS
  fi
fi
