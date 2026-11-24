# keisiki

Ruby ソースを決定論的に取り込み、Lean カーネルで性質を検査する基盤の初期実装です。Rails 固有のモデルを置かず、Ruby の部分言語に対して意味論を定義しています。

[先行技術の調査](docs/research.md)と[設計・保証範囲・ロードマップ](docs/design.md)を参照してください。

## 実行

CRuby 4.0、Bundler、`lean-toolchain` で固定した Lean が必要です。

```sh
bundle install
lake build
bundle exec ruby script/verify.rb \
  examples/lean/BudgetContract.lean examples/lean/BudgetProof.lean \
  examples/ruby/budget.rb examples/ruby/budget_rules.rb
bundle exec ruby test/smoke.rb
```

検証例では、２ファイルの３メソッドが連携する残額計算を使います。任意の非負整数の残額・要求額に対して、要求を受理できる場合の引き算、受理できない場合の残額維持と、結果の非負性を証明します。実装を変換した Lean ファイルは以下で確認できます。

```sh
bundle exec ruby script/ruby_to_lean.rb examples/ruby/budget.rb examples/ruby/budget_rules.rb
```

| 結果 | 意味 | 終了コード |
| --- | --- | --- |
| `PROVEN_CONDITIONAL` | 形式意味論上は `PROVEN`。実際の Ruby への適用には出力中の前提が必要です。 | 0 |
| `COUNTEREXAMPLE` | `--counterexample` で渡した具体例が、形式意味論上で性質を破ることを証明しました。 | 10 |
| `UNSUPPORTED` | サブセット外の構文・呼び出しを検出しました。 | 2 |
| `UNKNOWN` | 証明の検査に通りませんでした。 | 3 |
| `ERROR` | セットアップや入力ファイルなどにエラーがありました。 | 4 |

アプリケーション側は事前・事後条件と証明ファイルを用意します。互換性のある形は `examples/lean` にあります。変換と証明検査はソースから毎回やり直します。

GitHub Actions は、同じソースからの出力の一致、CRuby との照合、引数を入れ替えた版と等号境界を変えた版の反例、未対応構文と証明のすり抜けの拒否を検証します。`ruby-lean-verification` に生成した Lean ソースと検証結果を保存します。
