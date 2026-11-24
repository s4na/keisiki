import Keisiki.Lowering

namespace Keisiki

structure Contract where
  entry : String
  pre : List Int → Prop
  post : List Int → Int → Prop

def Contract.Holds (contract : Contract) (program : Program Source.Expr) : Prop :=
  ∀ arguments, contract.pre arguments →
    ∃ result, Source.invoke program contract.entry arguments = .ok result ∧ contract.post arguments result

structure Witness where
  arguments : List Int
  result : Int

def Contract.RefutesAt (contract : Contract) (program : Program Source.Expr) (witness : Witness) : Prop :=
  contract.pre witness.arguments ∧
  Source.invoke program contract.entry witness.arguments = .ok witness.result ∧
  ¬ contract.post witness.arguments witness.result

theorem Contract.Holds.excludes_refutation
    {contract : Contract} {program : Program Source.Expr} {witness : Witness}
    (holds : contract.Holds program) (refutes : contract.RefutesAt program witness) : False := by
  obtain ⟨result, ran, good⟩ := holds witness.arguments refutes.1
  rw [refutes.2.1] at ran
  cases ran
  exact refutes.2.2 good

end Keisiki
