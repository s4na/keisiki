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
対応していない Ruby 構文は `UNSUPPORTED` として検証を止めます。

検証対象は `Stock.remaining` の戻り値です。標準の Ruby 整数演算、Ruby から SMT-LIB への変換、Z3 の判定を前提とします。
Rails のルーティング・入力変換・レスポンスは代表的な HTTP リクエストで実行確認します。
DB、永続状態、並行処理、独立した証明検査は今後の対象です。
