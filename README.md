# EC2 Auto Shutdown Script

AWS EC2インスタンスのアイドル時間を監視し、自動的にシャットダウンするスクリプトです。AWS料金を節約するために、一定時間アイドル状態が続いた場合にインスタンスを自動停止します。

## 機能

- **SSHユーザー監視**: SSHセッションのアイドル時間を監視
- **Claude Code監視**: Claude Codeの活動を監視（ファイル更新時刻ベース）
- **柔軟な設定**: 各監視機能を個別に有効/無効化可能
- **ログ出力**: 詳細なログを出力

## ファイル構成

```
ec2-auto-shutdown/
├── auto-shutdown-idle.sh      # メインスクリプト
├── auto-shutdown-idle.conf    # 設定ファイル
├── logrotate.conf             # ログローテーション設定（オプション）
└── README.md                  # このファイル
```

## インストール

### 1. スクリプトを配置

```bash
# スクリプトディレクトリを作成
mkdir -p ~/scripts

# ファイルをコピー
cp auto-shutdown-idle.sh ~/scripts/
cp auto-shutdown-idle.conf ~/scripts/

# 実行権限を付与
chmod +x ~/scripts/auto-shutdown-idle.sh
```

### 2. ログファイルを作成

```bash
sudo touch /var/log/auto-shutdown.log
sudo chown $USER:$USER /var/log/auto-shutdown.log
```

### 3. cronを設定

```bash
# cronを編集
crontab -e

# 以下の行を追加（1分ごとに実行）
* * * * * /home/ec2-user/scripts/auto-shutdown-idle.sh >> /var/log/auto-shutdown.log 2>&1
```

### 4. （オプション）ログローテーションを設定

```bash
sudo cp logrotate.conf /etc/logrotate.d/auto-shutdown
```

## 設定

`auto-shutdown-idle.conf` を編集して設定を変更できます：

```bash
# SSHユーザー監視を有効にするか
USER_MONITOR_ENABLED=true

# ユーザーのアイドル時間閾値（秒）
USER_IDLE_THRESHOLD_SECONDS=180

# Claude Code監視を有効にするか
CLAUDE_MONITOR_ENABLED=true

# Claudeのアイドル時間閾値（秒）
CLAUDE_IDLE_THRESHOLD_SECONDS=180

# 監視対象のClaude関連パス
CLAUDE_WATCH_PATHS="$HOME/.claude/debug"
```

### シャットダウン条件

シャットダウンは以下の条件をすべて満たす場合に実行されます：

1. `USER_MONITOR_ENABLED=true` の場合：
   - 全SSHセッションが閾値以上アイドル、またはセッションなし

2. `CLAUDE_MONITOR_ENABLED=true` の場合：
   - Claudeプロセスが存在しない、または関連ファイルが閾値以上更新されていない

### 設定例

#### Claude Code専用モニタリング（推奨）

```bash
USER_MONITOR_ENABLED=false
CLAUDE_MONITOR_ENABLED=true
CLAUDE_IDLE_THRESHOLD_SECONDS=180
```

キーボード操作なしでもClaude Codeが処理中なら停止しません。

#### SSHユーザー専用モニタリング

```bash
USER_MONITOR_ENABLED=true
USER_IDLE_THRESHOLD_SECONDS=300
CLAUDE_MONITOR_ENABLED=false
```

#### 両方の監視を有効化

```bash
USER_MONITOR_ENABLED=true
USER_IDLE_THRESHOLD_SECONDS=300
CLAUDE_MONITOR_ENABLED=true
CLAUDE_IDLE_THRESHOLD_SECONDS=180
```

両方がアイドル状態のときのみシャットダウンします。

## 動作確認

### ログを確認

```bash
tail -f /var/log/auto-shutdown.log
```

### 手動でテスト実行

```bash
~/scripts/auto-shutdown-idle.sh
```

## アンインストール

```bash
# cronから削除
crontab -e
# 該当行を削除

# ファイルを削除
rm ~/scripts/auto-shutdown-idle.sh
rm ~/scripts/auto-shutdown-idle.conf
sudo rm /etc/logrotate.d/auto-shutdown
sudo rm /var/log/auto-shutdown.log
```

## ライセンス

MIT License
