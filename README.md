# Colima UI

macOS のメニューバーに常駐し、[Colima](https://github.com/abiosoft/colima) の状態を表示・操作する小さなアプリ。

## 機能

- メニューバーアイコンで Colima の状態を表示(実行中: 塗りつぶし / 停止中: アウトライン)
- クリックで起動中のコンテナを一覧表示
  - docker compose のプロジェクトはグループ化され、サブメニューから `compose stop` 可能
- Colima が停止中なら「起動」、実行中なら「再起動」「停止」
- 15 秒ごとに状態を自動更新

## 必要なもの

- macOS 14.4+
- `colima` / `docker`(Homebrew でインストールされていること)

## 実行

```sh
swift run
```

## .app としてビルド

```sh
./scripts/bundle.sh
open dist   # "Colima UI.app" をアプリケーションフォルダへ
```

ログイン時に自動起動したい場合は、システム設定 > 一般 > ログイン項目 に `Colima UI.app` を追加してください。
