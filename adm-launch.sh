# 認証モジュール (function authenticate_admin)
# 1. AES256復号 (OpenSSL)
# 2. SHA256ハッシュ照合 (Salt付き)
# 3. 2要素認証 (TOTP/oathtool) ※任意
# 4. セキュア抹消 (shred/dd)
# ==============================================================================

# --- 設定 ---
ENC_DB=~/.config/.admin/".password.enc"
SALT="340f0e46c08d3dc857e8fa8c0f5343ba"
LOG_FILE=~/.config/.admin/".usr_access.log"
CONFIG_FILE_LAUNCH_ADMIN=~/.config/.admin/".adm_launcher_config.txt"
# ランチャー最大登録数・バックアップパス最大登録数の設定
LIMIT=50

# --- クリーンアップ関数と trap の設定 ---
function _cleanup_on_exit() {
  # メモリ上の機密変数を完全に上書きして破棄
  master_key="00000000000000000000"
  user_pass="00000000000000000000"
  decrypted_data="00000000000000000000"
  totp_secret="00000000000000000000"
  input_otp="000000"
  correct_otp="000000"

  unset master_key user_pass decrypted_data totp_secret input_otp correct_otp
}

# EXIT, SIGINT, SIGTERM を捕捉
trap _cleanup_on_exit EXIT SIGINT SIGTERM

# --- 関数: セキュア抹消 ---
function _secure_cleanup() {
  local target="$1"
  [ ! -f "$target" ] && return

  if command -v shred &>/dev/null; then
    shred -u -n 1 "$target" 2>/dev/null
  else
    local size
    size=$(wc -c <"$target" | tr -d ' ')
    [ "$size" -gt 0 ] && dd if=/=/urandom of="$target" bs=1 count="$size" conv=notrunc &>/dev/null
    rm -f "$target"
  fi
}

# --- 関数: ユーザー認証 ---
function authenticate_admin() {
  if ! command -v openssl &>/dev/null; then
    echo "Error: openssl is required." >&2
    return 1
  fi

  read -sp "Enter Master Key: " master_key
  echo

  decrypted_data=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -k "$master_key" -in "$ENC_DB" 2>/dev/null)

  if [ $? -ne 0 ] || [ -z "$decrypted_data" ]; then
    echo "Error: Decryption failed." >&2
    _log_event "FAILURE" "Decryption failed (Invalid Master Key)"
    return 1
  fi

  stored_hash=$(echo "$decrypted_data" | cut -d',' -f1)
  totp_secret=$(echo "$decrypted_data" | cut -d',' -f2)

  decrypted_data="0000000000"
  unset decrypted_data

  read -sp "Enter Admin Password: " user_pass
  echo
  input_hash=$(echo -n "${user_pass}${SALT}" | openssl dgst -sha256 -r | awk '{print $1}')

  if [[ "$input_hash" != "$stored_hash" ]]; then
    echo "Error: Authentication failed." >&2
    _log_event "FAILURE" "Admin password mismatch"
    return 1
  fi

  if [[ -n "$totp_secret" ]] && ! command -v oathtool &>/dev/null; then
    echo "Error: totp_secret が設定されていますが、oathtool がインストールされていません。" >&2
    _log_event "FAILURE" "Not Installed oathtool"
    return 1
  fi

  if command -v oathtool &>/dev/null && [[ -n "$totp_secret" ]]; then
    read -p "Enter OTP: " input_otp
    correct_otp=$(oathtool --totp -b "$totp_secret")

    if [[ "$input_otp" != "$correct_otp" ]]; then
      echo "Error: Invalid OTP." >&2
      _log_event "FAILURE" "Invalid OTP"
      return 1
    fi
  fi

  _log_event "SUCCESS" "Authentication successful"
  echo "Authentication Success."
  return 0
}

# ログ記録用関数（登録名や実行コマンド情報を追記できるよう拡張可能）
function _log_event() {
  local status="$1"
  local message="$2"

  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
  fi

  printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$message" >>"$LOG_FILE"
}

# --- 認証実行 ---
authenticate_admin || exit 1
_cleanup_on_exit

echo "中核処理実行へ移行します"
sleep 1

# 設定ファイル初期化
touch "$CONFIG_FILE_LAUNCH_ADMIN"

# --- 関数: リストの読み込み（虫食いインデックス防止の再インデックス化） ---
load_config() {
  local raw_titles=()
  local raw_targets=()

  # ファイルから一時的に読み込み
  while IFS=',' read -r title target; do
    [[ -z "$title" ]] && continue
    raw_titles+=("$title")
    raw_targets+=("$target")
  done <"$CONFIG_FILE_LAUNCH_ADMIN"

  # グローバル配列を綺麗に詰め直して再代入（RASIS: 信頼性・保守性の向上）
  titles=("${raw_titles[@]}")
  targets=("${raw_targets[@]}")
}

# --- 関数: ファイルへの保存 ---
save_config() {
  >"$CONFIG_FILE_LAUNCH_ADMIN"
  for i in "${!titles[@]}"; do
    # 既にヘッダが付与されているため、そのまま保存
    echo "${titles[$i]},${targets[$i]}" >>"$CONFIG_FILE_LAUNCH_ADMIN"
  done
}

# --- メインメニュー表示 ---
while true; do
  load_config
  clear
  echo "=================================="
  echo "    管理者仕様 Multi Launcher (Total: ${#titles[@]}/$LIMIT)"
  echo "=================================="

  if [ ${#titles[@]} -eq 0 ]; then
    echo " (登録されている項目はありません)"
  else
    for i in "${!titles[@]}"; do
      item_target="${targets[$i]}"
      display_type="[UNKNOWN]"

      # 表示用に接頭辞を判定
      if [[ "$item_target" =~ ^shell: ]]; then
        display_type="[Shell]"
      elif [[ "$item_target" =~ ^cmd: ]]; then
        display_type="[Cmd]"
      fi

      printf "%2d) %-20s %-8s %s\n" $((i + 1)) "${titles[$i]}" "$display_type" "${item_target#*:}"
    done
  fi
  echo "----------------------------------"
  echo " a) 新規登録  e) 編集  s) 入れ替え  d) 削除  q) 終了"
  echo "----------------------------------"
  echo -n "実行する番号または操作を選択してください: "
  read -r opt

  case "$opt" in
    [0-9]*)
      idx=$((opt - 1))
      if [[ $idx -ge 0 && $idx -lt ${#titles[@]} ]]; then
        full_target="${targets[$idx]}"
        item_title="${titles[$idx]}"

        # ヘッダと実体の分離
        prefix="${full_target%%:*}"
        body="${full_target#*:}"

        if [[ -z "$body" ]]; then
          echo "エラー: 実行内容が空です。"
          sleep 2
          continue
        fi

        case "$prefix" in
          shell)
            if [[ -f "$body" ]]; then
              echo "--- [Shell] 実行中: $item_title ---"
              _log_event "EXEC_SHELL" "Name: $item_title, Path: $body"
              bash "$body"
              echo "----------------------------"
            else
              echo "エラー: ファイルが見つかりません。($body)"
              _log_event "EXEC_ERROR" "Shell file not found: $body"
              sleep 2
            fi
            ;;
          cmd)
            echo "--- [Command] 実行中: $item_title ---"
            _log_event "EXEC_CMD" "Name: $item_title, Cmd: $body"
            # 安全のため、直でevalする前にコンテキストを明確化して実行
            /usr/bin/env bash -c "$body"
            echo "----------------------------"
            ;;
          *)
            echo "エラー: 不明なフォーマットです。($prefix)"
            sleep 2
            ;;
        esac
        echo "完了。Enterキーで戻ります。"
        read -r
      fi
      ;;

    a)
      if [ ${#titles[@]} -ge $LIMIT ]; then
        echo "制限数($LIMIT)に達しています。削除してから登録してください。"
        sleep 2
        continue
      fi

      echo -n "表示タイトルを入力: "
      read -r new_title
      [[ -z "$new_title" ]] && continue

      echo "登録種別を選択してください:"
      echo "  1) シェルスクリプト (shell:)"
      echo "  2) コマンド構文     (cmd:)"
      echo -n "選択 (1-2): "
      read -r type_opt

      case "$type_opt" in
        1)
          echo -n "スクリプトのフルパスを入力: "
          read -r new_path
          titles+=("$new_title")
          targets+=("shell:$new_path")
          ;;
        2)
          echo -n "実行するコマンド構文を入力: "
          read -r new_cmd
          titles+=("$new_title")
          targets+=("cmd:$new_cmd")
          ;;
        *)
          echo "無効な選択です。登録をキャンセルします。"
          sleep 1
          continue
          ;;
      esac
      save_config
      ;;

    e)
      echo -n "編集する番号を選択: "
      read -r num
      idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt ${#titles[@]} ]]; then
        full_target="${targets[$idx]}"
        prefix="${full_target%%:*}"
        body="${full_target#*:}"

        echo "現在のタイトル: ${titles[$idx]}"
        echo -n "新しいタイトル (空欄で維持): "
        read -r edit_title

        echo "現在の内容 ($prefix): $body"
        echo -n "新しい内容 (空欄で維持): "
        read -r edit_body

        [[ -n "$edit_title" ]] && titles[$idx]="$edit_title"
        [[ -n "$edit_body" ]] && targets[$idx]="${prefix}:${edit_body}"

        save_config
      fi
      ;;

    s)
      echo -n "入れ替え元(No): "
      read -r n1
      echo -n "入れ替え先(No): "
      read -r n2
      i1=$((n1 - 1))
      i2=$((n2 - 1))
      if [[ $i1 -ge 0 && $i1 -lt ${#titles[@]} && $i2 -ge 0 && $i2 -lt ${#titles[@]} ]]; then
        tmp_t="${titles[$i1]}"
        titles[$i1]="${titles[$i2]}"
        titles[$i2]="$tmp_t"

        tmp_p="${targets[$i1]}"
        targets[$i1]="${targets[$i2]}"
        targets[$i2]="$tmp_p"
        save_config
      fi
      ;;

    d)
      echo -n "削除する番号を選択: "
      read -r num
      idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt ${#titles[@]} ]]; then
        unset 'titles[idx]'
        unset 'targets[idx]'
        save_config
        echo "削除しました。"
        sleep 1
      fi
      ;;

    q)
      echo "終了します。"
      exit 0
      ;;
  esac
done
