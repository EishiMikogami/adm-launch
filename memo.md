```bash


# 認証モジュール (function authenticate_admin)
# 1. AES256復号 (OpenSSL)
# 2. SHA256ハッシュ照合 (Salt付き)
# 3. 2要素認証 (TOTP/oathtool) ※任意
# 4. セキュア抹消 (shred/dd)
# ==============================================================================

# --- 設定 ---
ENC_DB=~/".passcode.enc"
SALT="SaltSpecificValueCode"
LOG_FILE=~/".usr_access.log"
CONFIG_FILE_LAUNCH_ADMIN=~/".adm_launcher_config.txt"

# ランチャー最大登録数・バックアップパス最大登録数の設定
LIMIT=50

# --- [新規追加] クリーンアップ関数と trap の設定 ---
# スクリプト終了時（正常・異常問わず）に必ず実行される後始末処理
function _cleanup_on_exit() {
  # 1. メモリ上の機密変数を完全に上書きして破棄
  master_key="00000000000000000000"
  user_pass="00000000000000000000"
  decrypted_data="00000000000000000000"
  totp_secret="00000000000000000000"
  input_otp="000000"
  correct_otp="000000"

  unset master_key user_pass decrypted_data totp_secret input_otp correct_otp
}

# EXIT (通常終了), SIGINT (Ctrl+C), SIGTERM (強制終了の要求) を捕捉
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
    [ "$size" -gt 0 ] && dd if=/dev/urandom of="$target" bs=1 count="$size" conv=notrunc &>/dev/null
    rm -f "$target"
  fi
}

# --- 関数: ユーザー認証 ---
function authenticate_admin() {
  # 1. 必要ツールの確認
  if ! command -v openssl &>/dev/null; then
    echo "Error: openssl is required." >&2
    return 1
  fi

  # 2. マスターキー入力と復号 (オンメモリ)
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

  # 元データはここで一旦上書きしてから消去（よりセキュアに）
  decrypted_data="0000000000"
  unset decrypted_data

  # 3. 本人認証パスワードの照合
  read -sp "Enter Admin Password: " user_pass
  echo
  # input_hash=$(echo -n "${user_pass}${SALT}" | openssl dgst -sha256 | awk '{print $2}')
  # openssl dgst -sha256 -r を使うと、常に「ハッシュ値 [スペース] *stdin」の形式になるため、確実に1番目を抜き出せます
  input_hash=$(echo -n "${user_pass}${SALT}" | openssl dgst -sha256 -r | awk '{print $1}')

  # --- デバッグ用の一時挿入 ---
  # echo "--- DEBUG ---"
  # printf "Stored Hash (HEX): %s\n" "$(echo -n "$stored_hash" | xxd -p)"
  # printf "Input  Hash (HEX): %s\n" "$(echo -n "$input_hash" | xxd -p)"
  # echo "--------------"

  if [[ "$input_hash" != "$stored_hash" ]]; then
    echo "Error: Authentication failed." >&2
    _log_event "FAILURE" "Admin password mismatch"
    return 1
  fi

  # 4. 2要素認証 (TOTP) - oathtool導入確認

  if [[ -n "$totp_secret" ]] && ! command -v oathtool &>/dev/null; then
    echo "Error: totp_secret が設定されていますが、oathtool がインストールされていません。" >&2
    _log_event "FAILURE" "Not Installed oathtool"
    return 1
  fi

  # 4. 3要素認証 (TOTP) - オプション
  if command -v oathtool &>/dev/null && [[ -n "$totp_secret" ]]; then
    read -p "Enter OTP: " input_otp
    correct_otp=$(oathtool --totp -b "$totp_secret")

    if [[ "$input_otp" != "$correct_otp" ]]; then
      echo "Error: Invalid OTP." >&2
      _log_event "FAILURE" "Invalid OTP"
      return 1
    fi
  fi

  # 5. 後始末
  _log_event "SUCCESS" "Authentication successful"
  echo "Authentication Success."
  return 0
}

# ログ記録用関数
function _log_event() {
  local status="$1"
  local message="$2"

  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
  fi

  printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$message" >>"$LOG_FILE"
}

# 実行
authenticate_admin || exit 1

# 認証成功後、これ以降の処理で不要ならここで明示的に破棄しても良い
_cleanup_on_exit

echo "中核処理実行へ移行します"

# 設定ファイルがなければ作成
touch "$CONFIG_FILE_LAUNCH_ADMIN"

# --- 関数: リストの読み込み ---
load_config() {
  titles=()
  paths=()
  while IFS=',' read -r title path; do
    [[ -z "$title" ]] && continue
    titles+=("$title")
    paths+=("$path")
  done <"$CONFIG_FILE_LAUNCH_ADMIN"
}

# --- 関数: ファイルへの保存 ---
save_config() {
  >"$CONFIG_FILE_LAUNCH_ADMIN"
  for i in "${!titles[@]}"; do
    echo "${titles[$i]},${paths[$i]}" >>"$CONFIG_FILE_LAUNCH_ADMIN"
  done
}

# --- メインメニュー表示 ---
while true; do
  load_config
  clear
  echo "=================================="
  echo "   管理者仕様 Script Launcher (Total: ${#titles[@]}/$LIMIT)"
  echo "=================================="

  if [ ${#titles[@]} -eq 0 ]; then
    echo " (登録されているスクリプトはありません)"
  else
    for i in "${!titles[@]}"; do
      printf "%2d) %-20s [%s]\n" $((i + 1)) "${titles[$i]}" "${paths[$i]}"
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
        script_path="${paths[$idx]}"
        if [[ -f "$script_path" ]]; then
          echo "--- 実行中: $script_path ---"
          bash "$script_path"
          echo "----------------------------"
          echo "完了。Enterキーで戻ります。"
          read -r
        else
          echo "エラー: ファイルが見つかりません。($script_path)"
          sleep 2
        fi
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
      echo -n "スクリプトのフルパスを入力: "
      read -r new_path
      titles+=("$new_title")
      paths+=("$new_path")
      save_config
      ;;
    e)
      echo -n "編集する番号を選択: "
      read -r num
      idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt ${#titles[@]} ]]; then
        echo "現在のタイトル: ${titles[$idx]}"
        echo -n "新しいタイトル (空欄で維持): "
        read -r edit_title
        echo "現在のパス: ${paths[$idx]}"
        echo -n "新しいパス (空欄で維持): "
        read -r edit_path
        [[ -n "$edit_title" ]] && titles[$idx]="$edit_title"
        [[ -n "$edit_path" ]] && paths[$idx]="$edit_path"
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
      if [[ $i1 -lt ${#titles[@]} && $i2 -lt ${#titles[@]} ]]; then
        # 配列要素の入れ替え
        tmp_t="${titles[$i1]}"
        titles[$i1]="${titles[$i2]}"
        titles[$i2]="$tmp_t"

        tmp_p="${paths[$i1]}"
        paths[$i1]="${paths[$i2]}"
        paths[$i2]="$tmp_p"
        save_config
      fi
      ;;
    d)
      echo -n "削除する番号を選択: "
      read -r num
      idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt ${#titles[@]} ]]; then
        unset 'titles[idx]'
        unset 'paths[idx]'
        # 配列のインデックスを詰め直して保存
        save_config
      fi
      ;;
    q)
      echo "終了します。"
      exit 0
      ;;
  esac
done

```

# このコードに改修を行いたいと考えます。 内容として,は現行のシェルスクリプトを登録する機能に加え、コマンド構文を登録する機能も実装する。　また、RASISの観点から通常のターミナルからコマンドを叩くときより、安全性を下げないもしくは、より高いものとする。 登録したものへヘッダを付加する（シェルスクリプトの場合は「shell:」,コマンドの場合は「cmd:」）。　実行ログとして、登録名を記録する。

このような内容の改修に最適な、コードの提案をお願いしたいのですが、可能でしょうか？
