# PostgreSQL の在庫確保を検証する

## 実行する SQL と証明する性質

Ruby の [Reservation](../examples/postgres/reservation.rb) は、[SQL ファイル](../examples/postgres/reserve.sql)の内容を `pg` の `exec_params` に渡します。同じ SQL を `pg_query` で解析し、対応する UPDATE の形と一致する場合だけ Lean の命令を生成します。生成ファイルには、SQL の SHA-256 と、在庫・正数の２つの条件の有無を記録します。条件が異なる変更版も、同じ変換器に掛けます。

Lean 上では、在庫が足り、要求が正のときだけ更新して新しい在庫を返します。条件が偽なら更新件数はゼロです。ロールバックされた更新は、確保済み数量にも在庫にも反映しません。

定理は、初期在庫が非負なら、この命令のコミット・ロールバックの任意の有限履歴について、残在庫と確保済み数量が非負で、合計が初期在庫に等しく、確保済み数量が初期在庫を超えないことを示します。さらに成功した更新では、残在庫は更新前以下です。証明の入力範囲は CI の再現ケースに限定されません。

## PostgreSQL への対応

対象は PostgreSQL 18 の `READ COMMITTED` 上で、１トランザクションにつき１回、同じ既存行を更新する場合です。[DDL](../examples/postgres/schema.sql) で `id` を主キー、在庫を `BIGINT NOT NULL` とします。正の要求が在庫以下のときだけ減算するので、入力の在庫が非負の BIGINT なら、成功した減算結果も BIGINT に収まります。同じ行の在庫を別経路から変更しないこと、トリガー・ルール・行レベルセキュリティが挙動を変えないことを前提とします。

実行順序との対応には、競合する UPDATE が先行トランザクションを待ち、コミット後に更新済みの行へ WHERE 条件を再評価する PostgreSQL の仕様を使います。この前提を、CI で PostgreSQL を起動して確かめます。２接続を使い、`pg_blocking_pids` が待機を示してから先行トランザクションをコミットまたはロールバックします。 [PostgreSQL のトランザクション分離](https://www.postgresql.org/docs/18/transaction-iso.html#XACT-READ-COMMITTED) · [UPDATE と RETURNING](https://www.postgresql.org/docs/18/sql-update.html)

| SQL と実行順序 | 実際の PostgreSQL の結果 |
| --- | --- |
| 正常版。在庫１個で先行がコミット | 先行は残数０を返す。後続は更新件数ゼロ |
| 正常版。在庫１個で先行がロールバック | 両方の文が残数０を返す。確保としてコミットされたのは後続の１件 |
| 在庫条件を削除。在庫１個で先行がコミット | ２件とも更新し、残在庫が −1 |
| 正数条件を削除。在庫０で −1 を要求 | 更新して在庫が１になる |

変更版では正常版と同じ定理が通らず、それぞれの具体的な反例を Lean で証明します。実際の PostgreSQL が返した各 UPDATE の値、最終在庫、コミット済み数量を Lean の評価結果と照合します。正常版の追加ケースでゼロ・負の要求の拒否、BIGINT 上限の計算、別行が変わらないことも確認します。

## 残る保証の境界

証明の対象は、限定した UPDATE と、コミット・ロールバックの形式意味論です。SQL AST を取り込むコードや、PostgreSQL エンジンがその意味論に従うことは、今回の証明の前提です。パーサーは `pg_query` の PostgreSQL 17 系構文木を使い、実行側は PostgreSQL 18.6 で比較します。SQL 全体の構文、複数行・複数文のトランザクション、分離レベル全般、Active Record の動的な SQL 生成には、個別の意味論と対応の検証が必要です。

現在受理するのは、`UPDATE ONLY`、単一列から `$1::bigint` を減算する SET、`id = 1` と２種類の対応済みの条件、および更新列１個の RETURNING です。結合、対象行を複数に広げる OR、複数文は未対応です。 [pg_query](https://github.com/pganalyze/pg_query)

## 再現

テスト専用の PostgreSQL 18 を用意し、接続 URL を渡します。テストは自分で作成した一時用途のスキーマを削除します。

```sh
KEISIKI_POSTGRES_TEST_URL=postgresql://postgres@127.0.0.1:5432/postgres \
  bundle exec ruby test/postgres_smoke.rb
```

GitHub Actions の `postgres-sql-verification` に、SQL、生成した Lean、証明、実DBの照合結果を保存します。
