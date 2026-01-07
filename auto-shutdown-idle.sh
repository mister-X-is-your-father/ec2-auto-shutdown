#!/bin/bash
#
# auto-shutdown-idle.sh - SSHユーザーとClaude Codeのアイドル時間を監視してEC2インスタンスを自動終了
#
# 目的: AWS料金節約のため、一定時間アイドル状態の場合にインスタンスを停止
#
# 使用方法:
#   このスクリプトはcronで定期実行されることを前提としています。
#
# cronの設定方法:
#   1. cronを編集: crontab -e
#   2. 以下の行を追加（1分ごとに実行する場合）:
#      * * * * * /home/ec2-user/scripts/auto-shutdown-idle.sh >> /var/log/auto-shutdown.log 2>&1
#   3. cronを保存して終了
#
# cronの確認方法:
#   crontab -l
#
# cronの削除方法:
#   crontab -e で該当行を削除、または crontab -r で全削除
#
# 設定ファイル:
#   /home/ec2-user/scripts/auto-shutdown-idle.conf
#
# ログファイル: /var/log/auto-shutdown.log
#

# ==============================================================================
# 設定ファイルの読み込み
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/auto-shutdown-idle.conf"

# デフォルト値（設定ファイルがない場合に使用）
USER_MONITOR_ENABLED=true
USER_IDLE_THRESHOLD_SECONDS=180
CLAUDE_MONITOR_ENABLED=true
CLAUDE_IDLE_THRESHOLD_SECONDS=180
CLAUDE_WATCH_PATHS="$HOME/.claude/history.jsonl $HOME/.claude/todos $HOME/.claude/debug"

# 設定ファイルを読み込む
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告: 設定ファイルが見つかりません: $CONFIG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] デフォルト値を使用します"
fi

# ログファイル
LOG_FILE="/var/log/auto-shutdown.log"

# ==============================================================================
# 関数
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Claude Codeが処理中かどうかをチェックする関数（ファイル更新時刻ベース）
# 戻り値: 0 = 処理中, 1 = アイドル
is_claude_processing() {
    local now=$(date +%s)
    local most_recent_update=0
    local most_recent_file=""

    # claudeプロセスが存在するか確認
    local claude_pids=$(pgrep -f "claude" 2>/dev/null)
    if [[ -z "$claude_pids" ]]; then
        log "Claudeプロセス: 検出されず"
        return 1
    fi

    local proc_count=$(echo "$claude_pids" | wc -l)
    log "Claudeプロセス: ${proc_count}個検出"

    # 監視対象ファイルの更新時刻をチェック
    for path in $CLAUDE_WATCH_PATHS; do
        # パスを展開（$HOMEなど）
        local expanded_path=$(eval echo "$path")

        if [[ -e "$expanded_path" ]]; then
            local mtime
            if [[ -d "$expanded_path" ]]; then
                # ディレクトリの場合、中の最新ファイルを確認
                mtime=$(find "$expanded_path" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
            else
                # ファイルの場合
                mtime=$(stat -c %Y "$expanded_path" 2>/dev/null)
            fi

            if [[ -n "$mtime" && "$mtime" -gt "$most_recent_update" ]]; then
                most_recent_update=$mtime
                most_recent_file=$expanded_path
            fi
        fi
    done

    if [[ $most_recent_update -eq 0 ]]; then
        log "Claude関連ファイル: 監視対象ファイルが見つかりません"
        return 1
    fi

    local idle_seconds=$((now - most_recent_update))
    local last_update_time=$(date -d "@$most_recent_update" '+%Y-%m-%d %H:%M:%S')

    log "Claude最終活動: $last_update_time ($idle_seconds 秒前) - $most_recent_file"

    if [[ $idle_seconds -lt $CLAUDE_IDLE_THRESHOLD_SECONDS ]]; then
        log "Claude: 処理中（閾値 ${CLAUDE_IDLE_THRESHOLD_SECONDS}秒 未満）"
        return 0
    else
        log "Claude: アイドル状態（閾値 ${CLAUDE_IDLE_THRESHOLD_SECONDS}秒 以上）"
        return 1
    fi
}

# ユーザーセッションがアイドルかどうかをチェックする関数
# 戻り値: 0 = 全てアイドル, 1 = アクティブなセッションあり
check_user_sessions_idle() {
    # SSHセッションを確認（wコマンドを使用）
    # pts/X はSSH経由のセッション
    local ssh_sessions=$(w -h 2>/dev/null | grep -E 'pts/')

    if [[ -z "$ssh_sessions" ]]; then
        log "SSHセッションがありません。"
        return 0  # セッションなし = アイドル扱い
    fi

    log "検出されたSSHセッション:"
    echo "$ssh_sessions" | while read line; do
        log "  $line"
    done

    # 全セッションのアイドル時間をチェック
    local all_idle=true
    local min_idle_seconds=999999

    while IFS= read -r line; do
        # wコマンドの出力: USER TTY FROM LOGIN@ IDLE JCPU PCPU WHAT
        # 例: ec2-user pts/0    1.2.3.4    10:00    1:23   0.05s  0.05s -bash

        local user=$(echo "$line" | awk '{print $1}')
        local tty=$(echo "$line" | awk '{print $2}')
        local idle_str=$(echo "$line" | awk '{print $5}')

        local idle_seconds=$(parse_idle_time "$idle_str")

        log "ユーザー: $user, TTY: $tty, アイドル時間: $idle_str ($idle_seconds 秒)"

        if [[ $idle_seconds -lt $min_idle_seconds ]]; then
            min_idle_seconds=$idle_seconds
        fi

        if [[ $idle_seconds -lt $USER_IDLE_THRESHOLD_SECONDS ]]; then
            all_idle=false
            log "  → アクティブ（閾値: $USER_IDLE_THRESHOLD_SECONDS 秒未満）"
        else
            log "  → アイドル（閾値: $USER_IDLE_THRESHOLD_SECONDS 秒以上）"
        fi
    done <<< "$ssh_sessions"

    log "最小アイドル時間: $min_idle_seconds 秒, 閾値: $USER_IDLE_THRESHOLD_SECONDS 秒"

    if $all_idle; then
        return 0
    else
        return 1
    fi
}

# アイドル時間を秒に変換する関数
# w コマンドの出力形式: "1:23" (時:分), "23:45" (分:秒), "1.00s" (秒), "1days" など
parse_idle_time() {
    local idle_str="$1"
    local seconds=0

    # "1days" 形式
    if [[ "$idle_str" =~ ([0-9]+)days ]]; then
        seconds=$((${BASH_REMATCH[1]} * 86400))
    # "1.00s" 形式（秒）
    elif [[ "$idle_str" =~ ^([0-9]+)\.([0-9]+)s$ ]]; then
        seconds=${BASH_REMATCH[1]}
    # "0.00s" または純粋な秒数
    elif [[ "$idle_str" =~ ^([0-9]+)s$ ]]; then
        seconds=${BASH_REMATCH[1]}
    # "HH:MM" 形式（時:分 または 分:秒）
    elif [[ "$idle_str" =~ ^([0-9]+):([0-9]+)$ ]]; then
        local part1=${BASH_REMATCH[1]}
        local part2=${BASH_REMATCH[2]}
        # 60以上なら時:分、それ以外は分:秒として扱う
        if [[ $part1 -ge 24 ]]; then
            # 分:秒
            seconds=$((part1 * 60 + part2))
        else
            # 時:分として扱う（wコマンドの仕様上）
            seconds=$((part1 * 3600 + part2 * 60))
        fi
    # "HH:MMm" 形式
    elif [[ "$idle_str" =~ ^([0-9]+):([0-9]+)m$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]}))
    # 数字のみ（分として扱う）
    elif [[ "$idle_str" =~ ^([0-9]+)$ ]]; then
        seconds=$((${BASH_REMATCH[1]} * 60))
    fi

    echo $seconds
}

# ==============================================================================
# メイン処理
# ==============================================================================

log "=== アイドル監視チェック開始 ==="
log "設定: ユーザー監視=$USER_MONITOR_ENABLED (閾値:${USER_IDLE_THRESHOLD_SECONDS}秒), Claude監視=$CLAUDE_MONITOR_ENABLED (閾値:${CLAUDE_IDLE_THRESHOLD_SECONDS}秒)"

# 両方の監視が無効の場合は何もしない（安全のため）
if [[ "$USER_MONITOR_ENABLED" != "true" && "$CLAUDE_MONITOR_ENABLED" != "true" ]]; then
    log "警告: ユーザー監視とClaude監視の両方が無効です。シャットダウンは実行されません。"
    log "=== アイドル監視チェック終了 ==="
    exit 0
fi

# 各条件のチェック結果を保持
user_is_idle=true
claude_is_idle=true

# ユーザー監視が有効な場合
if [[ "$USER_MONITOR_ENABLED" == "true" ]]; then
    if check_user_sessions_idle; then
        log "ユーザーセッション: アイドル状態"
        user_is_idle=true
    else
        log "ユーザーセッション: アクティブ"
        user_is_idle=false
    fi
else
    log "ユーザー監視: 無効（スキップ）"
fi

# Claude監視が有効な場合
if [[ "$CLAUDE_MONITOR_ENABLED" == "true" ]]; then
    if is_claude_processing; then
        log "Claude: 処理中"
        claude_is_idle=false
    else
        log "Claude: アイドル状態"
        claude_is_idle=true
    fi
else
    log "Claude監視: 無効（スキップ）"
fi

# シャットダウン判定
should_shutdown=true

if [[ "$USER_MONITOR_ENABLED" == "true" && "$user_is_idle" == "false" ]]; then
    should_shutdown=false
fi

if [[ "$CLAUDE_MONITOR_ENABLED" == "true" && "$claude_is_idle" == "false" ]]; then
    should_shutdown=false
fi

# シャットダウン実行
if $should_shutdown; then
    log "全ての条件を満たしました。インスタンスを停止します。"
    log "実行コマンド: sudo shutdown -h now"
    sudo shutdown -h now
else
    log "アクティブな状態があります。インスタンスは停止しません。"
fi

log "=== アイドル監視チェック終了 ==="
