# 保証段階の報告

保証の根拠、範囲、実測結果を性質ごとの表にします。`report` ジョブは各検査ジョブの JSON を読み、Job Summary と `assurance-report` アーティファクトに保存します。アーティファクトには元の JSON も含めます。

## 入力形式

各ジョブは成果物 `assurance-results-<方式>` に JSON を置きます。集約時に上書きが起きないよう、ファイル名はジョブごとに異なるものを使います。JSON の最上位には形式番号 `version`（現在は 1）、根拠にたどれる `source`、１件以上の `rows` を置きます。

| フィールド | 記録する内容 |
| --- | --- |
| `property`, `method`, `case` | 性質、検査方式、不具合またはシナリオ |
| `role` | `normal`、`positive_control`、`experiment_check`、`comparison` |
| `expected`, `observed` | 事前に決めた期待と実測。`detected`、`not_detected`、`out_of_scope`、`execution_error`。方式の比較で期待を置かない場合は `expected` に `null` を指定 |
| `assurance` | `proof`、`conditional_proof`、`finite_model_check`、`bounded_execution`、`execution_check`、`unchecked` |
| `target`, `assumptions`, `scope`, `checker` | 根拠となる対象、前提、入力・探索の範囲、共通チェッカー |
| `trials`, `trial_budget`, `duration_ms`, `time_budget_ms`, `replay_steps` | 試行の実績と上限、所要時間と上限（ミリ秒）、再生できる反例の長さ。未計測・未記録は `null` |
| `evidence` | 結果を裏づける測定値などを格納するオブジェクト |

正常系、陽性対照、実験自体の確認は、実測が期待から外れると CI が失敗します。方式の比較で「未検出」「対象外」が出た場合は、その成績を表に残します。実行エラーは表に残し、CI も失敗します。

## 初回の入力

[PR #16 の app-smoke](https://github.com/s4na/keisiki/actions/runs/45400133924/job/138466228020)（コミット `1b67c63b8406715bfe4112b2a5ae8d4ef1200575`）から `reservation-retry-history` をダウンロードし、チェッカーの出力２件を `retry-example/` に収録しました。正常版の残在庫は１個、陽性対照は初回コミット時点で１個、再送後に０個です。このジョブは記録済みの測定を入力に集約を検証します。ケース単位の時間と再生ステップ数は元データで未計測です。共通アプリが main に入った後は、実行したジョブの出力を直接集約し、比較方式の結果を追加できます。

```sh
ruby reporting/import_retry.rb \
  https://github.com/s4na/keisiki/actions/runs/45400133924/job/138466228020 \
  reporting/retry-example/baseline-result.json \
  reporting/retry-example/double_update-result.json > /tmp/keisiki-retry-result.json
ruby reporting/summary.rb /tmp/keisiki-retry-result.json
```
