# Ruby・Rails・PostgreSQL の形式検証スタック

在庫確保の P1〜P4 を対象に、Lean 4 を証明の基盤、TLA+／TLC を並行・障害のモデル検査、Rails と実 PostgreSQL の履歴照合を実装との対応確認に使う。最初に同じ業務操作を３つの方法で検査し、証明・有限モデル検査・実行照合の根拠をそれぞれ記録する。 [共通課題 #8](https://github.com/s4na/keisiki/issues/8) · [保証段階 #15](https://github.com/s4na/keisiki/issues/15)

## 実験で確認できたこと

| 実験 | 得られた保証 | 適用範囲 |
| --- | --- | --- |
| [#6 Ruby → Lean](https://github.com/s4na/keisiki/pull/6) | Lean 内の Ruby 部分意味論から中間表現への意味保存と、対象メソッドの契約の証明。CRuby との差分照合 | 整数演算・分岐・閉じた呼び出しグラフ。Prism と構文の取り込み、CRuby との対応は前提 |
| [#7 SQL → Lean](https://github.com/s4na/keisiki/pull/7) | 限定した UPDATE の任意の有限コミット・ロールバック履歴について、在庫の非負性と保存則を証明。実 PostgreSQL のロック待ちと戻り値を照合 | 既存１行を１トランザクションで１回更新する抽象化。SQL 取り込みと PostgreSQL の挙動への対応は前提 |
| [#16 Rails／PostgreSQL](https://github.com/s4na/keisiki/pull/16) | 実 HTTP でコミット後に応答を失い、同じ要求を再送。正常版は在庫１個を保ち、二重更新版は０個になることを実測 | 同一予約 ID・数量での再送１回。Rails の実経路を通した実行照合 |
| [#20 PostgreSQL 競合再生](https://github.com/s4na/keisiki/pull/20) | PostgreSQL の行ロック待ちを観測し、ロックの有無で確定件数が１件と２件に分かれることを確認 | SQL セッション２件の競合順序１件 |
| [#21 TLA+／TLC](https://github.com/s4na/keisiki/pull/21) | 正常モデルの到達可能な４状態で P1 を検査し、二重更新版の３遷移の反例を JSON に出力 | 初期在庫２、予約 ID １種、数量１、再送１回。モデルはコミットを１ステップに抽象化 |

統合で最初に確かめるべき点は、Lean が扱うトランザクションと Rails が実際に実行するトランザクションの対応である。#7 は `quantity = quantity - $1` を行う条件付き `UPDATE ... RETURNING` を扱う。#16 は行をロックして在庫と既存予約を読み、Ruby で差を計算し、Active Record で在庫更新と予約 INSERT を同じトランザクションに入れる。#7 の在庫に関する補題は再利用候補になる。#16 に適用するには、同じ行をロックした順序、引数と更新先、予約 INSERT、コミット・ロールバックを含む別の対応が必要になる。 [#7 の SQL](https://github.com/s4na/keisiki/blob/9a490b0abfdbb79f68445fc13f3de74354d0ce41/examples/postgres/reserve.sql) · [#16 のサービス](https://github.com/s4na/keisiki/blob/1b67c63b8406715bfe4112b2a5ae8d4ef1200575/example/app/services/reserve_stock.rb)

## 推奨する構成

Lean を主軸に選ぶ理由は、対象の Ruby と SQL を形式表現に結び付け、探索範囲に依存しない定理を積み上げられることにある。状態機械も Lean で表現できる。並行・障害の設計段階では、有限の状態探索と反例出力をすでに確認できている TLC を使う。プロトコル設計だけを扱う段階なら TLA+／TLC で着手でき、コードとの対応を強める段階で Lean の意味論と証明が役立つ。

1. **業務操作の仕様。** 操作の入力、成功・拒否・障害時の結果、コミット済みの在庫と予約を定義する。P1〜P4 の受け入れ例は実装と独立に用意し、Lean の定理、TLC のモデル、履歴チェッカーが同じ例を参照できるようにする。要求 ID・数量と結果を比較し、有効な要求が成功する P4 も検査する。全要求拒否を陽性対照に使う。 [契約の比較 #10](https://github.com/s4na/keisiki/issues/10)
2. **Lean 4 で操作と部分プログラムを証明。** まず確保・同一要求の再送・ロールバックを表す遷移を定義し、有限個の操作からなる任意の履歴で在庫の保存・非負性・二重反映の防止を示す。Ruby は副作用のない小さな関数を Prism から取り込み、SQL は `pg_query` で解析して対象構文を限定する。元のソースと発行された SQL を生成物に紐付け、対象の定理型と公理を CI で監査する。パーサーから形式表現への変換は、別に意味保存を示すまで保証の前提とする。 [Lean の証明検査](https://lean-lang.org/doc/reference/latest/ValidatingProofs/) · [Prism](https://github.com/ruby/prism) · [pg_query](https://github.com/pganalyze/pg_query)
3. **TLA+／TLC でプロトコルを探索。** ロック取得と待機、コミット、応答喪失、再送を別ステップにし、同じ ID と異なる ID の２要求を探索する。探索した初期条件・状態数と反例を保存する。反例は操作と同期点に写し、実 PostgreSQL で再生する。小さい状態空間と JSON の反例出力は #21 で実証済みなので、最初の比較は TLC に揃える。Quint／Apalache は #1 で使った候補として、状態数が増えて TLC の実行予算を超えた場合に比較する。 [TLA+ Tools](https://github.com/tlaplus/tlaplus) · [Apalache の探索方式](https://apalache-mc.org/docs/apalache/index.html) · [Quint を使った実験 #1](https://github.com/s4na/keisiki/pull/1)
4. **Rails と PostgreSQL の観測で対応を検査。** HTTP の入力・応答、Active Record が発行した SQL と型変換済みバインド、接続とトランザクション終了、独立接続から読んだ確定行を同じ履歴に集める。在庫と予約に対するレコードの対応を、共有のチェッカーで照合する。接続・隔離レベル・DDL・トリガー・別書き込み経路は前提として明示する。実験では PostgreSQL 18 の `READ COMMITTED` と同一在庫行へのロックで範囲を絞り、設定と実データベースの観測で確かめる。 [Rails の計測イベント](https://guides.rubyonrails.org/active_support_instrumentation.html#sql-active-record) · [PostgreSQL 18 の分離レベル](https://www.postgresql.org/docs/18/transaction-iso.html#XACT-READ-COMMITTED)

Lean の定理の主張は対象の形式意味論に対するものとし、Rails については、仮定付きの保証と観測したケースの照合を結果に残す。HTTP から DB までの全実行へ主張を広げる段階では、実装側の各ステップが業務操作の許容遷移に対応することを、層ごとに示す。TLA+ モデルにも同じ対応が必要で、正常モデルと実装が同じ受け入れ例を通ることはその出発点になる。

## 次に検証する１ケース

#16 のコミット後の応答喪失と同一要求の再送を使う。Lean では、対応する確保が一度だけ確定し、応答喪失が DB を変えず、他の更新を挟まない同一要求の再送が DB を変更せず同じ結果を返すことを示す。#21 の `Commit → LoseResponse → Retry` を同じケースに対応付ける。

- 正常版では確保１件・残在庫１個・同じ成功結果を Lean の遷移と実 DB の履歴で照合する。
- 二重更新版では確保１件・残在庫０個となる履歴を拒否する。TLC の反例と対応する実行の同期点を成果物に残す。
- 次の変更では、在庫更新後・予約 INSERT 前のロールバックを扱う。その後に２要求の競合と P4 の通常成功を接続する。計測に必要なコミットや確定行の記録が欠けた場合は、判定不能として扱う。

統合前の調査として #7 と #16 の現在の HEAD に `git merge-tree --write-tree --name-only` を実行したところ、`Gemfile`、`Gemfile.lock`、`.gitignore`、`README.md` に競合があった。先に #16 を共通アプリの起点として取り込み、#6・#7 の Lean モジュールと検証コマンドを、そのアプリと依存を揃えた差分で追加する。CI では既存の Ruby と SQL の証明・照合に加え、上記の正常版と陽性対照を確認する。 [基盤整理 #9](https://github.com/s4na/keisiki/issues/9) · [形式化 #14](https://github.com/s4na/keisiki/issues/14)
