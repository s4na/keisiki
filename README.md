# keisiki

Rails の HTTP リクエストから呼ばれる Ruby メソッドを形式検証する最初の実装です。
`GET /stock/remaining?stock=7&quantity=2` は、残る在庫を JSON で返します。

`Stock.remaining` の実行時メソッドが指す Ruby ソースを Prism で読み取り、整数、引数参照、減算、大小比較を使った分岐を SMT-LIB に変換します。
非負の整数を２つ渡したときに負の値を返す入力があるか Z3 に問い合わせます。
`UNSAT` はこの条件で反例が存在しないというソルバーの判定です。
反例が見つかると、同じ値を Rails の Rack エントリポイントに送り、負の値が HTTP レスポンスで返ることを確認します。

## 実行

Ruby 4.0、Bundler、PATH 上の `z3` が必要です。

```sh
bundle install
bundle exec ruby script/verify_stock.rb
bundle exec ruby test/smoke.rb
```

GitHub Actions のスモーク検証は、通常の HTTP 応答、入力エラー、ソルバーの `UNSAT` 判定を確認します。
サンプルを一時ディレクトリにコピーして在庫チェックを外した場合には、ソルバーが見つけた反例を同じ Rails ルートで再現します。
在庫と数量がともにゼロの場合や、両方が符号付き 64 ビット整数の上限を超える同値の場合にだけ残数が負になるよう変更した版でも、入力を指定せずに反例を導出して再現します。
対応していない Ruby 構文は `UNSUPPORTED` として検証を止めます。

検証対象は `Stock.remaining` の戻り値です。標準の Ruby 整数演算、Ruby から SMT-LIB への変換、Z3 の判定を前提とします。
残数が非負のまま誤るケースを形式検証で検出するには、期待する残数を表す条件も必要です。
Rails のルーティング・入力変換・レスポンスは代表的な HTTP リクエストで実行確認します。
DB、永続状態、複数プロセスでの並行処理、独立した証明検査は今後の対象です。

## 並行注文のモデル検査

`POST /stock/reservations` は、プロセス内の在庫から１個を確保します。初期在庫は１個で、確保できれば HTTP 201、在庫切れなら HTTP 409 を返します。

Quint の状態遷移モデルでは、２件の注文がそれぞれ在庫の読み取りと確保の２ステップを実行します。確保時の更新式は、Rails が実行する `ReservationDecision.next_stock` のソースから生成します。読み取りと確保がそれぞれアトミックだと仮定し、Apalache で最大４ステップまで調べて「２件とも確保されることはない」を検査します。

確保時に読み取り時点の古い在庫を使うよう、一時コピーの Ruby を変更します。Quint が出力する ITF の反例を読み、２件の Rails リクエストを反例と同じ順序で実行します。変更版は両方とも HTTP 201 を返し、元の実装は同じ順序で HTTP 201 と 409 を返します。

Node.js 24 と Java 21 があれば、GitHub Actions と同じ検査を実行できます。

```sh
npm ci --ignore-scripts --no-audit --no-fund
bundle exec ruby test/reservations_smoke.rb
```

状態遷移モデルの在庫の読み取り、確保、HTTP ステータスとの対応は手書きです。現在の検査対象は、単一プロセスの共有メモリ、初期在庫１個、注文２件です。

## TLA+ の反例トレースをユニットテストで再生

TLC で在庫１個・注文２件の状態遷移を検査します。在庫確保の更新式は Ruby ソースから変換し、期待する確保結果は TLA+ の仕様で定義します。反例の操作順と期待値は JSON に保存し、同じ Minitest が `ReservationStore` に対して再生します。再生ライブラリにはモデル上の操作と Ruby メソッドの対応を渡します。

CI では古い在庫値を使う競合、残り１個を誤って拒否するケース、購入しても在庫が減らないケースを検出します。どの反例でも変更版はアサーション失敗、元のコードは成功することを確認します。モデルの範囲は、単一プロセスの在庫１個と注文２件です。読み取り・確保をアトミックなステップとして扱います。

Java 21 とチェックサムを検証した TLC 1.8.0 の JAR を使い、`TLA2TOOLS_JAR=/path/to/tla2tools.jar bundle exec ruby test/tla_smoke.rb` で実行できます。

GitHub Actions の `tla-replay` アーティファクトから、この検査で出力した反例と再生用 JSONをダウンロードできます。
