# ================================================================
# Dockerfile — Laravel 12 汎用 Web コンテナ設計図 (量産テンプレート)
# ----------------------------------------------------------------
# このファイルは『どんな Laravel 12 アプリでも動かせる』ように
# 汎用化された Docker レシピです。
# docker-compose.yml から ARG を受け取り、PHP バージョンや
# DocumentRoot フォルダ名をプロジェクトごとに差し替えられます。
#
# ★ ビルドコマンド ★
#   docker compose up -d --build
#
# ★ 用語メモ ★
#   ARG        : ビルド時だけ使える変数 (docker build 時に渡される)
#   ENV        : 実行時も残る環境変数 (コンテナの中で有効)
#   レイヤー    : RUN 1 個ごとに作られる差分 (キャッシュ単位)
#   multi-stage: 軽量化のため複数の FROM を使う高度なテクニック
# ================================================================


# ================================================================
# ① ARG の先行宣言 (FROM より前に書くとベースイメージで使える)
# ----------------------------------------------------------------
# docker-compose.yml から受け取る値の『初期値』を宣言します。
# こうすることで「単体で docker build する時」でも安全に動きます。
# ================================================================
ARG PHP_VERSION=8.4


# ================================================================
# ② ベースイメージ
# ----------------------------------------------------------------
# `php:${PHP_VERSION}-apache` は Docker Hub の公式イメージで、
# 中に PHP と Apache が入っています。
# Laravel 12 は PHP 8.2 以上が必須。
# ================================================================
FROM php:${PHP_VERSION}-apache

# FROM より後で使う ARG はもう一度宣言が必要 (Docker の仕様)
ARG PUBLIC_DIR=task-manager
ARG TZ=Asia/Tokyo
ARG UPLOAD_MAX=64M
ARG MEMORY_LIMIT=512M

# ENV にも保存して、コンテナ内の実行時にも参照できるようにする
ENV PUBLIC_DIR=${PUBLIC_DIR}
ENV APP_TZ=${TZ}


# ================================================================
# ③ OS パッケージと PHP 拡張モジュールのインストール
# ----------------------------------------------------------------
# apt-get は Linux (Debian 系) のソフト管理コマンド。
# Windows でいう『インストーラー』にあたります。
#
# インストールする OS パッケージ:
#   locales        : 日本語 (ja_JP.UTF-8) サポート
#   git            : Composer が GitHub からパッケージを取る時に必須
#   unzip          : zip 解凍 (Composer が使う)
#   curl           : URL からファイルをダウンロードする道具
#   libzip-dev     : PHP の zip 拡張ビルド用ヘッダ
#   libicu-dev     : PHP の intl (国際化) 拡張ビルド用
#   libonig-dev    : PHP の mbstring 拡張ビルド用
#   libxml2-dev    : PHP の xml 拡張ビルド用
#   libpng-dev     : gd (画像処理) 拡張のための PNG サポート
#   libjpeg-dev    : gd の JPEG サポート
#   libfreetype6-dev: gd のフォント描画サポート
#
# インストールする PHP 拡張 (Laravel 12 必須のセット):
#   pdo / pdo_mysql  : DB 接続
#   mbstring         : 日本語処理
#   intl             : 国際化・日付
#   zip              : zip 操作 (Composer も使う)
#   bcmath           : 高精度計算 (Laravel の大きな数値処理)
#   xml              : XML 処理
#   exif             : 画像メタデータ読み取り
#   gd               : 画像処理 (リサイズ等)
#   opcache          : PHP 高速化 (★本番で必須級★)
#
# ★ -j$(nproc) とは? ★
#   CPU コア数ぶん並列コンパイルすることでビルドを高速化する
#   おまじない。マルチコア PC では体感 2〜4 倍速くなる。
# ================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        locales \
        git \
        unzip \
        curl \
        libzip-dev \
        libicu-dev \
        libonig-dev \
        libxml2-dev \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
    && locale-gen ja_JP.UTF-8 \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mysqli \
        mbstring \
        intl \
        zip \
        bcmath \
        xml \
        exif \
        gd \
        opcache \
        pcntl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ================================================================
# ④ Composer (PHP のパッケージ管理人) をインストール
# ----------------------------------------------------------------
# Composer は PHP のライブラリ自動ダウンロードツール。
# Laravel 本体も Composer 経由で入手します:
#   composer install
#
# ★ multi-stage COPY ★
#   composer 公式イメージからバイナリだけを /usr/local/bin に
#   持ってくる書き方。これが公式推奨の最軽量インストール。
# ================================================================
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer


# ================================================================
# ④-2 Node.js + npm (JavaScript のパッケージ管理人) をインストール
# ----------------------------------------------------------------
# ★ 何のため? ★
#   Vite (ヴィート) というフロントエンドビルドツールを動かすため。
#   Vite は JS / CSS を 1 個にまとめて圧縮し、ページ読み込みを速くする。
#
# ★ たとえ話 ★
#   Composer = PHP の道具箱管理人
#   npm      = JavaScript の道具箱管理人
#   Node.js  = JavaScript を PC 上で動かすエンジン (ブラウザの外で動かす)
#
# ★ なぜ Node.js を Docker に入れるの? ★
#   開発者それぞれの PC に Node.js を入れなくても、
#   Docker コンテナの中で統一環境で動かせるようにするため。
#
# ★ 使い方 (コンテナ内で) ★
#   cd /var/www/html/laravel_app
#   npm install         # 初回: package.json の依存関係をダウンロード
#   npm run build       # 本番用にビルド (task-manager/build/ に出力)
#   npm run dev         # 開発サーバー起動 (保存で自動リロード)
# ================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ================================================================
# ⑤ 言語環境を日本語に設定
# ----------------------------------------------------------------
# これをしないとエラーメッセージや日付表記が英語になります。
# ================================================================
ENV LANG=ja_JP.UTF-8
ENV LANGUAGE=ja_JP:ja
ENV LC_ALL=ja_JP.UTF-8


# ================================================================
# ⑥ PHP 設定ファイルを外部から取り込む
# ----------------------------------------------------------------
# docker/php/custom.ini を /usr/local/etc/php/conf.d/ にコピー。
# ここに upload_max_filesize や OPcache 設定をまとめています。
#
# ★ さらに docker-compose から渡された ARG で上書き ★
#   ビルド時に PHP_UPLOAD_MAX / PHP_MEMORY_LIMIT が動的に変わる。
# ================================================================
COPY docker/php/custom.ini /usr/local/etc/php/conf.d/zz-custom.ini

RUN sed -i "s|__UPLOAD_MAX__|${UPLOAD_MAX}|g"   /usr/local/etc/php/conf.d/zz-custom.ini \
 && sed -i "s|__MEMORY_LIMIT__|${MEMORY_LIMIT}|g" /usr/local/etc/php/conf.d/zz-custom.ini \
 && sed -i "s|__TZ__|${TZ}|g"                     /usr/local/etc/php/conf.d/zz-custom.ini


# ================================================================
# ⑦ Apache の VirtualHost 設定を外部から取り込む
# ----------------------------------------------------------------
# docker/apache/000-default.conf を Apache の設定フォルダにコピー。
# このファイル内の __PUBLIC_DIR__ を ARG で実際のフォルダ名に置換。
#
# ★ 量産テンプレートのポイント ★
#   PUBLIC_DIR を ARG で渡すことで、
#   「task-manager」でも「public_html」でも「www」でも
#   同じ Dockerfile で対応できます。
# ================================================================
COPY docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf

RUN sed -i "s|__PUBLIC_DIR__|${PUBLIC_DIR}|g" /etc/apache2/sites-available/000-default.conf


# ================================================================
# ⑧ Apache のモジュール有効化
# ----------------------------------------------------------------
#   rewrite : .htaccess の URL 書き換え (Laravel 必須)
#   headers : Header ディレクティブの有効化
#   expires : 静的ファイルのキャッシュ期限
#   deflate : gzip 圧縮 (転送量を削減)
# ================================================================
RUN a2enmod rewrite headers expires deflate


# ================================================================
# ⑨ .htaccess を有効化 (AllowOverride All)
# ----------------------------------------------------------------
# デフォルトの Apache は、セキュリティのため .htaccess が
# 読み込まれない (AllowOverride None) 設定になっています。
# これを All に変更して、Laravel / task-manager の .htaccess を
# 有効化します。
# ================================================================
RUN sed -ri 's!AllowOverride None!AllowOverride All!g' /etc/apache2/apache2.conf


# ================================================================
# ⑩ 作業ディレクトリを指定
# ----------------------------------------------------------------
# コンテナ内のカレントフォルダを /var/www/html に固定。
# docker-compose.yml の volumes: で、ホスト側のプロジェクト
# ルートがここにマウントされます。
# ================================================================
WORKDIR /var/www/html


# ================================================================
# ⑪ エントリポイントスクリプトを配置
# ----------------------------------------------------------------
# コンテナ起動のたびに走る初期化スクリプト。
#   ・vendor が無ければ composer install
#   ・.env が無ければ .env.example からコピー + APP_KEY 生成
#   ・storage の書き込み権限修正
#   ・キャッシュクリア
#   ・最後に Apache を起動
# ================================================================
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]


# ================================================================
# 補足: このテンプレートを新しい Laravel 12 プロジェクトで使うには
# ----------------------------------------------------------------
# 1. このファイル + docker/ フォルダ + docker-compose.yml をコピー
# 2. `.env.docker.example` を `.env` にリネームして値を変更
#    - COMPOSE_PROJECT_NAME
#    - LARAVEL_DIR (Laravel 本体のフォルダ名)
#    - PUBLIC_DIR  (公開フォルダ名)
#    - WEB_PORT / DB_PORT / PMA_PORT
# 3. `docker compose up -d --build`
#
# 【本番化のコツ】
#   - APP_ENV=production / APP_DEBUG=false
#   - composer install --no-dev --optimize-autoloader
#   - php artisan optimize
#   - OPcache の opcache.validate_timestamps を 0 に
# ================================================================
