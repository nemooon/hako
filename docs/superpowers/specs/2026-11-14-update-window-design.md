# アップデートウィンドウ 設計

## 目的

Homebrew で入れた Hako と Colima を、アプリの中からボタン 1 つで更新できるようにする。
今はターミナルで `brew upgrade` を打つ必要があり、Hako は Developer ID 署名がないため
`xattr -dr com.apple.quarantine` も忘れると起動できない。Track の更新ボタンと同じ体験にそろえる。

## ゴール

- 専用の「アップデート」ウィンドウに Hako と Colima の欄を並べ、それぞれバージョンの変化・変更内容・実行するコマンドを確認してから、欄ごとのボタンで個別に更新できる
- Hako: `brew upgrade --cask --no-quit --no-ask nemooon/tap/hako` → `xattr -dr com.apple.quarantine <Hako.app>`。完了後「再起動」で新しいバージョンへ切り替えられる(「あとで」も選べる)
- Colima: `brew upgrade --no-ask colima`。完了後、VM が動いていれば「Colima を再起動」で新しいバージョンへ切り替えられる(「あとで」も選べる)
- 入口は 3 つ
  - アプリ名メニュー「Hako」→「アップデートを確認…」(「Hako について」の直後)
  - メニューバーの「Hako の新しいバージョン X があります」(今はリリースページを開くだけ → このウィンドウを開く)
  - メニューバーの「Colima の新しいバージョン X があります」(同上)

## 非ゴール

- Homebrew 以外の方法(zip を直接ダウンロードして置き換える等)での更新
- 自動更新(確認なしでの更新)
- docker CLI や lima など、Colima 以外の Homebrew パッケージを個別に更新すること
  (`brew upgrade colima` が依存として一緒に上げる分はそのまま任せる)

## アンチゴール

- 更新途中でウィンドウを閉じたりアプリを終了したりして、中途半端な状態になること
- Homebrew にまだ新しい版が来ておらず古い版のままなのに「完了」と表示すること
- Colima の更新で、ユーザーの確認なしに VM を再起動してコンテナを止めること

## 選んだ作り方

整理画面(CleanupWindow)と同じく、SwiftUI の画面を AppKit の NSWindowController に載せる。
Homebrew・xattr・colima を呼ぶ部分は `StatusStore.Backend` と同じく差し替えられる形にし、テストで偽の結果を返せるようにする。

検討して外した案:
- NSAlert を順に出す。リリースノートを見せにくく、ウィンドウを追加したいという要望に合わない
- Hako と Colima を 1 つのボタンでまとめて更新する。Colima の更新はコンテナに影響しうるので個別に選べるほうがよく、完了後の「再起動」が 2 種類になって分かりにくい

## 画面

```
┌ アップデート ────────────────────────────────┐
│ Hako    0.6 → 0.7                     [アップデート] │
│   変更内容: (Hako のリリースノート)                  │
│   実行するコマンド: brew upgrade … / xattr …         │
├──────────────────────────────────────────┤
│ Colima  0.10.3 → 0.11.0               [アップデート] │
│   変更内容: (Colima のリリースノート)                │
│   実行するコマンド: brew upgrade --no-ask colima     │
└──────────────────────────────────────────┘
```

### 欄ごとの状態

| 状態 | 表示 | ボタン |
|---|---|---|
| 確認中 | 「新しいバージョンを確認しています…」 | なし |
| 最新 | 「0.6 は最新です」 | なし |
| 更新あり | 現在 → 新バージョン、変更内容、実行するコマンド | アップデート |
| 更新中 | 「アップデート中…」 | 無効 |
| 完了(Hako) | 「0.7 のインストールが完了しました。再起動すると切り替わります」 | あとで / 再起動 |
| 完了(Colima、VM 実行中) | 「0.11.0 のインストールが完了しました。Colima を再起動すると切り替わります(再起動中はコンテナが止まります)」 | あとで / Colima を再起動 |
| 完了(Colima、VM 停止中) | 「0.11.0 のインストールが完了しました。次に Colima を起動したときから使われます」 | なし |
| エラー | 赤字で理由(下記)。更新ありの表示は残す | アップデート(再試行) |
| 対象外 | 理由(.app として動いていない / Homebrew が無い / Homebrew で入れていない)。新しい版があればリリースページへのリンク | なし |

- どちらかが更新中の間は、もう一方の「アップデート」も無効にする(Homebrew は同時に動かせないため)
- 更新中はウィンドウを閉じられない
- ウィンドウを開くたびに GitHub の最新リリースを確認し直す。結果は `StatusStore` の `availableUpdate` / `availableColimaUpdate` / `colimaVersion` にも反映し、メニューバー表示と食い違わないようにする
- 「Colima を再起動」は既存の再起動操作(`CommandCenter.restartColima`)を使い、メニューバーの「処理中」表示もそのまま出る

## 更新の手順とエラー

共通
1. brew を `/opt/homebrew/bin/brew`、`/usr/local/bin/brew` の順に探す → 無ければ「Homebrew が見つかりません」(両方の欄が対象外)

Hako
1. `brew list --cask --versions hako` で Homebrew 管理か確認 → 無ければ対象外「Homebrew でインストールされていません」
2. `brew upgrade --cask --no-quit --no-ask nemooon/tap/hako` → 失敗なら出力を添えて「アップデートに失敗しました」
3. もう一度 `brew list --cask --versions hako` → 期待するバージョンでなければ「Homebrew にまだ 0.7 が反映されていません。しばらくしてから再試行してください」
4. `xattr -dr com.apple.quarantine <実行中の Hako.app のパス>` → 失敗なら「アップデートは完了しましたが隔離属性を削除できませんでした」と、手で打つコマンドを表示

Colima
1. `brew list --formula --versions colima` で Homebrew 管理か確認 → 無ければ対象外「Homebrew でインストールされていません」
2. `brew upgrade --no-ask colima` → 失敗なら出力を添えて「アップデートに失敗しました」
3. もう一度 `brew list --formula --versions colima` → 期待するバージョンでなければ「Homebrew にまだ 0.11.0 が反映されていません。しばらくしてから再試行してください」
   (Colima の新版は GitHub で公開されてから homebrew-core に入るまで時間がかかることがあるため)

## Hako の再起動

小さなシェル処理を別プロセスで起動し、今の Hako の終了を待ってから `open <Hako.app>` させ、
今の Hako は自分を終了する(新しい Hako をすぐ立ち上げると、メニューバーのアイコンが一瞬 2 つ並ぶため)。

## 実装者に任せること

- リリースノート本文の取得方法(今の `UpdateChecker` を拡張して tag と本文を一緒に返す想定)と、Markdown の表示方法
- ウィンドウの大きさ、余白、ボタンの見た目(整理画面に合わせる)。最新・対象外の欄は小さくまとめる
- ファイル分け(`UpdateWindow.swift` / 更新処理の型 など)
