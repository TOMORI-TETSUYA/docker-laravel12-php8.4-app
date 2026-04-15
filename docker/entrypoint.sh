#!/bin/bash
# ================================================================
# docker/entrypoint.sh — コンテナ起動時の初期化スクリプト (汎用版)
# ----------------------------------------------------------------
# Docker コンテナが起動すると、Dockerfile の ENTRYPOINT で指定された
# このスクリプトが最初に走ります。
# 役割は「Laravel 12 アプリを自動でセットアップして Apache を起動」。
#
# ★ 量産テンプレート対応 ★
#   Laravel 本体のフォルダ名は docker-compose.yml の環境変数
#   LARAVEL_DIR で受け取ります。デフォルトは laravel_app。
#   別プロジェクトで `backend` や `api` にしたい場合も、
#   `.env` で LARAVEL_DIR=backend と書くだけで OK。
#
# 処理の流れ:
#  ① vendor が無ければ composer install
#  ② .env が無ければ .env.example をコピー + 値上書き + APP_KEY 生成
#  ③ storage / bootstrap/cache の書き込み権限を修正
#  ④ 古いキャッシュをクリア
#  ⑤ 最後に Apache を起動 (exec で置き換え)
#
# ★ set -e ★
#   コマンドが 1 個でも失敗したら即スクリプト終了。
#   エラーを見逃さないためのおまじないです。
# ================================================================

set -e

# ------------------------------------------------
# 環境変数から Laravel 本体の場所を決定
# ------------------------------------------------
# docker-compose.yml の environment: LARAVEL_DIR から受け取る。
# 未指定の場合は laravel_app をデフォルトに。
# ------------------------------------------------
LARAVEL_DIR_NAME="${LARAVEL_DIR:-laravel_app}"
LARAVEL_PATH="/var/www/html/${LARAVEL_DIR_NAME}"

echo "=========================================="
echo "  Laravel 12 Docker Bootstrap"
echo "=========================================="
echo "  PHP Version : $(php -r 'echo PHP_VERSION;')"
echo "  Laravel Dir : ${LARAVEL_PATH}"
echo "  App Env     : ${APP_ENV:-local}"
echo "=========================================="

# ----------------------------------------------------------------
# 事前チェック: Laravel 本体フォルダが存在するか
# ----------------------------------------------------------------
if [ ! -d "$LARAVEL_PATH" ]; then
    echo "⚠️  Laravel ディレクトリが見つかりません: $LARAVEL_PATH"
    echo "    .env の LARAVEL_DIR 設定を確認してください。"
    echo "    それでも起動を続行し、Apache のみ立ち上げます..."
    exec "$@"
fi

# ================================================================
# ① vendor フォルダが無ければ composer install
# ================================================================
# Composer は PHP のパッケージ管理人。
# composer.json に書かれたライブラリを vendor/ にダウンロードします。
# Laravel 12 本体もこれで入手されます。
# ================================================================
if [ ! -f "$LARAVEL_PATH/vendor/autoload.php" ]; then
    if [ -d "$LARAVEL_PATH/vendor" ]; then
        echo "[1/4] vendor/ はありますが autoload.php が欠落しています。"
        echo "      composer install が途中で失敗した状態とみなし、再インストールします..."
    else
        echo "[1/4] vendor/ が見つかりません。composer install を実行します..."
    fi
    echo "      (初回は数分かかります☕)"

    cd "$LARAVEL_PATH"

    # --prefer-dist       : zip でダウンロード (速い)
    # --optimize-autoloader : 読み込み高速化
    # --no-interaction    : 対話プロンプトを出さない
    composer install \
        --no-interaction \
        --prefer-dist \
        --optimize-autoloader

    echo "[1/4] ✓ composer install 完了"
else
    echo "[1/4] ✓ vendor/autoload.php 確認済み (スキップ)"
fi


# ================================================================
# ② .env が無ければ作成 + 値上書き + APP_KEY 自動生成
# ================================================================
# .env は Laravel の『秘密のメモ帳』で、DB 情報や APP_KEY が入ります。
# docker-compose.yml の environment: から受け取った値で上書きします。
# ================================================================
if [ ! -f "$LARAVEL_PATH/.env" ]; then
    echo "[2/4] .env が無いので .env.example からコピーします..."

    if [ -f "$LARAVEL_PATH/.env.example" ]; then
        cp "$LARAVEL_PATH/.env.example" "$LARAVEL_PATH/.env"
    else
        # .env.example が無い場合は最小限の .env を自作
        cat > "$LARAVEL_PATH/.env" <<'EOF'
APP_NAME=Laravel
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=laravel
DB_USERNAME=root
DB_PASSWORD=

SESSION_DRIVER=file
CACHE_STORE=file
QUEUE_CONNECTION=sync
EOF
    fi

    # ------------------------------------------------
    # 環境変数で .env を上書き (sed -i でインプレース編集)
    # ------------------------------------------------
    # 関数定義: _env_set KEY VALUE
    #   .env の KEY=... の行を新しい値で書き換える
    # ------------------------------------------------
    _env_set() {
        local key="$1"
        local val="$2"
        if [ -z "$val" ]; then
            return 0
        fi

        # sed のセパレータに | を使うと / を含むパスもそのまま使える
        if grep -q "^${key}=" "$LARAVEL_PATH/.env"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$LARAVEL_PATH/.env"
        else
            echo "${key}=${val}" >> "$LARAVEL_PATH/.env"
        fi
    }

    _env_set APP_NAME     "${APP_NAME}"
    _env_set APP_ENV      "${APP_ENV}"
    _env_set APP_DEBUG    "${APP_DEBUG}"
    _env_set APP_URL      "${APP_URL}"
    _env_set APP_TIMEZONE "${APP_TIMEZONE}"
    _env_set DB_CONNECTION "${DB_CONNECTION:-mysql}"
    _env_set DB_HOST       "${DB_HOST}"
    _env_set DB_PORT       "${DB_PORT}"
    _env_set DB_DATABASE   "${DB_DATABASE}"
    _env_set DB_USERNAME   "${DB_USERNAME}"
    _env_set DB_PASSWORD   "${DB_PASSWORD}"

    # APP_KEY を自動生成 (暗号化の鍵)
    # これが空だと Laravel は起動時にエラーになります
    cd "$LARAVEL_PATH"
    php artisan key:generate --force 2>/dev/null || {
        echo "    ⚠️  key:generate に失敗しました (vendor/ が不完全かも)"
    }

    echo "[2/4] ✓ .env 作成完了 (APP_KEY 自動生成済み)"
else
    # .env は存在するが APP_KEY が空なら生成する
    # (手動で .env をコピーしただけのケースをリカバリ)
    if grep -qE '^APP_KEY=\s*$' "$LARAVEL_PATH/.env"; then
        echo "[2/4] .env は存在しますが APP_KEY が空です。生成します..."
        cd "$LARAVEL_PATH"
        php artisan key:generate --force 2>/dev/null || {
            echo "    ⚠️  key:generate に失敗しました"
        }
        echo "[2/4] ✓ APP_KEY 生成完了"
    else
        echo "[2/4] ✓ .env 確認済み (スキップ)"
    fi
fi


# ================================================================
# ③ 書き込み権限の修正
# ================================================================
# Laravel は以下のフォルダに書き込みを行います:
#   storage/            → ログ / キャッシュ / セッション
#   bootstrap/cache/    → 設定・サービスキャッシュ
#
# Apache は www-data ユーザーで動いているので、そのユーザーが
# 書き込める状態 (775) にします。
#
# ★ 権限 775 の読み方 ★
#   7 (所有者) : 読み + 書き + 実行
#   7 (グループ): 読み + 書き + 実行
#   5 (その他) : 読み + 実行 (書けない)
# ================================================================
echo "[3/4] 書き込み権限を設定中..."

# サブフォルダが存在しなければ事前に作る
mkdir -p "$LARAVEL_PATH/storage/framework/sessions" \
         "$LARAVEL_PATH/storage/framework/cache/data" \
         "$LARAVEL_PATH/storage/framework/views" \
         "$LARAVEL_PATH/storage/logs" \
         "$LARAVEL_PATH/bootstrap/cache" 2>/dev/null || true

# 所有者を www-data に
chown -R www-data:www-data \
    "$LARAVEL_PATH/storage" \
    "$LARAVEL_PATH/bootstrap/cache" 2>/dev/null || true

# 書き込み権限を付与
chmod -R 775 \
    "$LARAVEL_PATH/storage" \
    "$LARAVEL_PATH/bootstrap/cache" 2>/dev/null || true

echo "[3/4] ✓ 権限設定完了"


# ================================================================
# ④ キャッシュ系をクリア
# ================================================================
# 開発中は .env や config/ を変えることが多いので、毎回キャッシュを
# 消しておくと「変更したのに反映されない」事故を防げます。
#
#   config:clear  .env / config/ 変更を反映
#   route:clear   routes/*.php 変更を反映
#   view:clear    Blade 変更を反映
#   cache:clear   アプリのキャッシュを消す
# ================================================================
echo "[4/4] キャッシュをクリア中..."
cd "$LARAVEL_PATH"

php artisan config:clear 2>/dev/null || true
php artisan route:clear  2>/dev/null || true
php artisan view:clear   2>/dev/null || true
php artisan cache:clear  2>/dev/null || true

echo "[4/4] ✓ キャッシュクリア完了"


# ================================================================
# 本番モードの場合は最適化キャッシュを作成
# ================================================================
if [ "${APP_ENV}" = "production" ]; then
    echo "[+] 本番モード検出: optimize を実行..."
    php artisan optimize 2>/dev/null || true
    echo "[+] ✓ 最適化完了"
fi


echo "=========================================="
echo "  準備完了! Apache を起動します..."
echo "=========================================="


# ================================================================
# ⑤ 最後に Apache を起動 (= Dockerfile の CMD を実行)
# ================================================================
# exec を使うと、このスクリプトの『プロセス』自体が
# Apache に置き換わります。
# → コンテナの PID 1 が Apache になる
# → docker compose stop できれいに終了できる
#
# "$@" は『このスクリプトに渡された引数』。Dockerfile の
# CMD ["apache2-foreground"] がここに展開されます。
# ================================================================
exec "$@"
