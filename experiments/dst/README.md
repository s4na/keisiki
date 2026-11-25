# PostgreSQL で競合順序を再生する

在庫１個に対し、異なる予約 ID の要求 A・B が各１個を確保する。PR #3 の古い在庫値を読む競合を PostgreSQL の二つの `READ COMMITTED` トランザクションに対応付け、P3 の確定件数と残在庫を照合する。

1. A が `SELECT … FOR UPDATE` で在庫を読み、行ロックを保持する。
2. B が在庫を読む SQL を非同期で送る。第三の接続は、A のコミット前に B の読み取りが完了するか、`pg_blocking_pids` が B をブロックしている A を報告するまで待つ。
3. 観測結果が得られたら A をコミットする。B が取得した在庫で確保の可否を決め、B の終了後に第三の接続が確定結果を読む。

正常版の B は A のロック解除後に在庫０を読み、確保を拒否する。陽性対照では B の `FOR UPDATE` を外す。B は A のコミット前に在庫１を読み、古い値を使って A と B がともに確定する。残在庫だけを見れば両方とも０なので、確定した予約 ID も照合する。読み取り完了とロック待ちを確認できない場合は実行エラーにする。

Ruby と `pg` 1.7.0 を用い、一時スキーマを作成できるテスト用 PostgreSQL の接続文字列を `KEISIKI_DST_DATABASE_URL` に設定して実行する。

```sh
ruby experiments/dst/postgres_replay.rb baseline
ruby experiments/dst/postgres_replay.rb stale_read
```

標準出力に観測したステップ、確定結果、実行時間を JSON で出す。終了コードは正常が `0`、契約違反が `1`、実行エラーが `2`。CI の `dst-postgres-replay` に両方の試行を保存する。結果の範囲は同期点を決めた１順序の実 DB 照合で、Rails 経由の再生、再送時の応答喪失、インターリーブ列挙は #12 の後続で扱う。
