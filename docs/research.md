# Ruby を Lean で検証するための先行技術

| 技術 | 再利用する知見と今回の採用範囲 |
| --- | --- |
| Prism と CRuby | Prism は Ruby ソースを構文木に解析し、CRuby のコンパイラーも消費します。パーサーを再実装せず、バージョンを固定した Prism を構文入口に使います。Prism の構文木が CRuby の評価と対応することは、採用した機能について別途確認します。 [Prism](https://ruby.github.io/prism/) · [CRuby における Prism AST のコンパイル](https://ruby.github.io/prism/rb/docs/cruby_compilation_md.html) |
| Ruby Spec Suite | 言語構文、コア API、C API の振る舞いを実行可能なテストとして記録しています。整数と制御構文の境界を選ぶ資料にし、対応範囲が広がった段階で該当する仕様テストを CI に取り込みます。 [Ruby Spec Suite](https://github.com/ruby/spec) |
| DRuby と Ruby の型システム研究 | Ruby に似た計算体系の型健全性、動的なコード評価、再定義される低水準メソッドが既存の意味論に与える影響を扱っています。メソッド表や動的機能を設計する際の参照先です。 [Static Type Inference for Ruby](https://www.cs.tufts.edu/~jfoster/papers/thesis-furr.pdf) · [Dynamic Features of Ruby](https://www.cs.umd.edu/projects/PL/druby/papers/druby-oopsla09.pdf) |
| Rubyx と Rubicon | Rubyx は Rails に記号実行を適用し、Rubicon は標準 Ruby インタープリターと Alloy を組み合わせて有界検査を行います。実装を経由する検査と、探索範囲の明示が参考になります。 [Rubyx](https://cseweb.ucsd.edu/~dstefan/cse291-winter18/papers/rubyx.pdf) · [Rubicon](https://groups.csail.mit.edu/sdg/pubs/2012/rubicon-fse12.pdf) |
| Lean | Ruby の部分意味論、IR、変換器、意味保存定理を定義する基盤です。`simp` や `omega` が生成する証明はカーネルが検査します。推論手順の自動化と証明の信頼性を分離できます。 [Lean の証明検査](https://lean-lang.org/faq/) · [整数線形演算用の omega](https://lean-lang.org/doc/api/Lean/Elab/Tactic/Omega.html) |

Prism と Lean を採用し、両者をつなぐ決定論的な構文の取り込みと、対応する Ruby の実行意味論を実装しました。比較テストには Ruby Spec Suite の整数加算と減算から４つの境界入力を取り入れ、CRuby と Lean の結果を照合しています。仕様テスト自体の実行は、対象構文を拡張するときの作業です。 [加算の既存テスト](https://github.com/ruby/spec/blob/0260823021feefce01cc18619f3e71825dd55219/core/integer/plus_spec.rb) · [減算の既存テスト](https://github.com/ruby/spec/blob/0260823021feefce01cc18619f3e71825dd55219/core/integer/minus_spec.rb)
