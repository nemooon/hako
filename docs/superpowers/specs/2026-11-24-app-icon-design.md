# アプリアイコンの作り直し（段ボール箱案）

## 目的
今のアイコンは、オレンジの背景に SF Symbols の `shippingbox` を白で小さく置いただけ。Hako らしさがなく、物足りない。
「コンテナっぽさ」と「箱っぽさ」が伝わるアイコンにしたい。

## 決めたこと（ユーザー）
- モチーフは **B. 段ボール箱**：斜め上から見た立体的な段ボール。天面と側面にテープ、側面に白いラベル、背景は青緑のグラデーション
- 作り方は **箱の絵を Icon Composer のレイヤーにして仕上げる**。最初は SVG で描き切る案（v1）だったが、背景が単純なグラデーションなら Icon Composer で仕上げたほうが macOS らしいとして切り替えた

## 検討した作り方
| 案 | 内容 | トレードオフ | 結果 |
|---|---|---|---|
| SVG で描き切る | SVG → PNG → icns | 細部と色を思いどおりに出せる。ガラスのつや、ダーク・色付き表示は付かない | v1 まで作って不採用 |
| Icon Composer で仕上げる | 箱をレイヤー PNG にして `Hako.icon` に入れる。ビルド時に `actool` で `Assets.car` と `Hako.icns` を作る | macOS 26 以降でガラスのつや、ダーク・色付き・クリア表示が出る。actool で書き出しも自動になる。ガラス効果で段ボールの色がぼやけないよう調整が要る | **採用** |

`xcrun actool Resources/Hako.icon --compile <出力先> --platform macosx --minimum-deployment-target 14.4 --app-icon Hako` で `Assets.car`（macOS 26 以降用）と `Hako.icns`（古い macOS 用）ができることを確認済み。

## やること
- 箱の元データとして `Resources/Hako.svg` を残す。中身は箱だけで背景は透明。`<g id="box">` `<g id="tape">` `<g id="label">` に分ける
- 箱の各グループを、背景が透明な 1024×1024 の PNG として `Resources/Hako.icon/Assets/` に書き出す。Icon Composer のキャンバスは角丸の全面にあたるので、箱の幅はキャンバスの 6 割前後にする
- 背景は `icon.json` の `fill` で青緑のグラデーションにする（#63C6D8 → #1D6A8C）
- ガラス効果で段ボールの色が白っぽくならないようにする。箱の色が v1 と同じ印象で見えればよい
- `scripts/bundle.sh` で actool を呼び、`Assets.car` と `Hako.icns` を `Contents/Resources` に入れる。Info.plist に `CFBundleIconName` を足す
- `Resources/Hako.icns`（生成物になる）と `scripts/icon-to-icns.sh`（不要になる）は削除する
- SVG からレイヤー PNG を作り直すスクリプトを `scripts/icon-layers.sh` として置く

## やらないこと
- メニューバーのアイコン（SF Symbols で状態を出している部分）は変えない
- コンテナ柄や複数の箱など、他の案の要素は混ぜない

## 失敗とみなすもの
- 小さいサイズで、ただの茶色い四角に見える
- ガラス効果で段ボールらしい色が抜ける
- macOS 14.4 から 25 で、アイコンが出ない

## 作る人に任せること
- ガラス・影・透明度の細かい設定（actool が書き出した icns で見た目を確かめ、ユーザーに見せる）
