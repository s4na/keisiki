# keisiki

Rails の HTTP リクエスト、Ruby の業務処理、SQL、PostgreSQL の確定状態を業務操作の契約と照合する実験です。

## コミット後に応答を失った在庫確保の再送

テスト用 Puma が実際の Rails エンドポイントを起動します。１個の確保がコミットされた後、別の PostgreSQL 接続で確定状態を読み、最初の HTTP 応答を送信する前に接続を閉じます。クライアントは EOF を受け取った後、同じ予約 ID で再送します。

| 版 | 初回コミット後 | 再送後 | 契約判定 |
| --- | --- | --- | --- |
| 正常版 | 確保１件、残在庫１個 | 確保１件、残在庫１個 | 一致 |
| 二重更新する版 | 確保１件、残在庫１個 | 確保１件、残在庫０個 | 在庫条件に違反 |

両方の版で、再送時の HTTP 応答は最初に生成された確保結果と同じです。履歴には HTTP の要求と結果、Active Record が実行した更新・コミットの SQL とバインド値、別接続で読み取った在庫と確保記録を時系列で保存します。検査は、初回コミットと応答の破棄が再送より先に起きたことも確認します。

## 再現

Ruby 4.0.9 とテスト専用の PostgreSQL 18 を用意します。検証用 DB ユーザーにはスキーマの作成権限が必要です。実行ごとに作ったテストスキーマは終了時に削除します。

```sh
bundle install
export KEISIKI_POSTGRES_TEST_URL=postgresql://postgres:password@127.0.0.1:5432/postgres
bundle exec ruby test/retry_after_commit.rb baseline tmp/retry/baseline.json
bundle exec ruby test/retry_after_commit.rb double_update tmp/retry/double_update.json
bundle exec ruby test/retry_contract.rb tmp/retry/baseline.json
bundle exec ruby test/retry_contract.rb tmp/retry/double_update.json
```

履歴チェッカーは一致で終了コード `0`、契約違反で `1`、前提を確認できない履歴で `2` を返します。CI は正常版の成功と、不具合版が `retry_stock_unchanged` だけで失敗することを要求します。実測の履歴と判定は `reservation-retry-history` アーティファクトに保存します。

今の検証範囲は同じ予約 ID・数量での、応答喪失後の再送１回です。並行実行や任意の操作列に対する証明は、[#8 の調査計画](https://github.com/s4na/keisiki/issues/8) の後続範囲です。
