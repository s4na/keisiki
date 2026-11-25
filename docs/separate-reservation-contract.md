# 在庫確保の契約を別ファイルに書く案

調査 issue #10 の案 b。Rails の処理や SQL を読まずに、[契約](../contracts/separate-file/reservation.yml)で、実行前に満たす条件と実行後に満たす条件を確認できます。[受け入れ例](../contracts/separate-file/examples/histories.yml)は契約とは別に記述し、条件の解釈と正負の判定を確認します。

| 性質 | 受け入れ例が確認する条件 | 拒否する観測例 |
| --- | --- | --- |
| P1 冪等性 | 同じ ID の再送と同時要求で、残在庫は１個、確保記録は１件。成功応答は同じ確保結果 | 同じ ID で在庫を２回減らす、確保を２件記録する |
| P2 原子性 | 更新の間で失敗すると在庫と確保記録は元に戻る。コミット後に応答を失う場合は、再送しても確定状態が変わらず既存の結果が返る | 確保記録だけが残る、再送で別 ID が返る、再送で在庫をもう一度減らす |
| P3 過剰確保の防止 | 在庫１個で異なる２件が競合したとき、確定は最大１件で、残在庫は非負 | 在庫が負になり２件が確定する |
| P4 正常時の成功 | 競合や障害のない有効な初回要求では、在庫を１個減らし、要求どおりの確保記録と成功応答を返す | すべての要求を拒否する |

## 検査エンジンへの入力

`given` の `requests` と `initial_reservations`、および観測値の `reservations` の各要素は `[予約 ID, 数量]` です。`stock` と `reservations` は実行後に別の DB 接続で観測する確定状態、`receipts` はクライアントが観測した `[HTTP ステータス, 予約 ID, 数量]` です。本文のない応答ではステータスだけを記録します。`stock_at_first_commit` と `reservations_at_first_commit` は応答を失うケースの初回コミット直後の観測です。`execution` には実際に成立した実行条件を記録します。

コンパイラは操作、実行条件、性質 ID、比較条件をバージョン付き JSON に変換します。別プロセスの観測チェッカーがその JSON を読み込みます。比較条件は値の一致、整数の下限、配列の件数の上限です。実行条件の不一致や必須観測の欠落は、契約違反とは区別して実験エラーにします。

```sh
mkdir -p /tmp/keisiki-contract-proposal
ruby contracts/separate-file/check.rb compile contracts/separate-file/reservation.yml \
  > /tmp/keisiki-contract-proposal/engine-input.json
ruby contracts/separate-file/check.rb verify /tmp/keisiki-contract-proposal/engine-input.json \
  contracts/separate-file/examples/histories.yml
```

今回の検証範囲は、在庫１〜２個、１個ずつの要求１〜２件についての固定例です。同時に届く同一 ID のケースでは、両方が成功応答を受け取る具体例を確認します。Rails と PostgreSQL の履歴の収集・入力変換、各案の比較、H4 の計測は後続の調査です。
