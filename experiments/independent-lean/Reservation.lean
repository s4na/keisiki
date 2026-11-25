import Std

namespace IndependentLean

-- The reservation field describes the one ID in the request.
structure State where
  stock : Int
  reservation : Option Int

inductive Write where
  | stock (value : Int)
  | reservation (quantity : Int)

inductive Outcome where
  | conflict (state : State)
  | success (state : State) (returnedQuantity : Int) (writes : List Write)

-- Business rules stated on the committed state and observable writes.
def contract (state : State) (quantity : Int) : Outcome :=
  match state.reservation with
  | some recorded =>
    if recorded = quantity then .success state recorded [] else .conflict state
  | none =>
    if state.stock < quantity then
      .conflict state
    else
      let remaining := state.stock - quantity
      .success ⟨remaining, some quantity⟩ quantity [.stock remaining, .reservation quantity]

inductive ExistingConflict where
  | different
  | same
  deriving DecidableEq

inductive DebitWhen where
  | missing
  | present
  | always
  | never
  deriving DecidableEq

inductive StockConflict where
  | less
  | lessOrEqual
  deriving DecidableEq

inductive Adjustment where
  | subtract
  | add
  deriving DecidableEq

structure Program where
  existingConflict : ExistingConflict
  debitWhen : DebitWhen
  stockConflict : StockConflict
  adjustment : Adjustment
  deriving DecidableEq

def ExistingConflict.denies (test : ExistingConflict) (recorded quantity : Int) : Bool :=
  match test with
  | .different => decide (recorded ≠ quantity)
  | .same => decide (recorded = quantity)

def DebitWhen.applies : DebitWhen → Option Int → Bool
  | .missing, none => true
  | .missing, some _ => false
  | .present, none => false
  | .present, some _ => true
  | .always, _ => true
  | .never, _ => false

def StockConflict.denies (test : StockConflict) (stock quantity : Int) : Bool :=
  match test with
  | .less => decide (stock < quantity)
  | .lessOrEqual => decide (stock ≤ quantity)

def Adjustment.apply (op : Adjustment) (stock quantity : Int) : Int :=
  match op with
  | .subtract => stock - quantity
  | .add => stock + quantity

-- The whole-file Ruby grammar fixes the order of both guards and both writes.
def interpret (program : Program) (state : State) (quantity : Int) : Outcome :=
  let existingConflict :=
    match state.reservation with
    | none => false
    | some recorded => program.existingConflict.denies recorded quantity
  let debit := program.debitWhen.applies state.reservation
  if existingConflict || (debit && program.stockConflict.denies state.stock quantity) then
    .conflict state
  else
    let remaining := if debit then program.adjustment.apply state.stock quantity else state.stock
    let writes : List Write := if debit then [.stock remaining] else []
    match state.reservation with
    | some recorded => .success ⟨remaining, some recorded⟩ recorded writes
    | none => .success ⟨remaining, some quantity⟩ quantity (writes ++ [.reservation quantity])

def reference : Program := ⟨.different, .missing, .less, .subtract⟩

def accepts (program : Program) : Bool := decide (program = reference)

set_option linter.unusedSimpArgs false in
theorem reference_matches_contract (state : State) (quantity : Int) :
    interpret reference state quantity = contract state quantity := by
  cases state with
  | mk stock reservation =>
    cases reservation with
    | none =>
      by_cases h : stock < quantity <;>
        simp [interpret, reference, contract, DebitWhen.applies, StockConflict.denies,
          Adjustment.apply, h]
    | some recorded =>
      by_cases h : recorded = quantity <;>
        simp [interpret, reference, contract, ExistingConflict.denies, DebitWhen.applies, h]

theorem accepted_matches_contract (program : Program) (verified : accepts program = true)
    (state : State) (quantity : Int) :
    interpret program state quantity = contract state quantity := by
  have same : program = reference := of_decide_eq_true verified
  subst program
  exact reference_matches_contract state quantity

theorem accepted_first_and_retry (program : Program) (verified : accepts program = true)
    (stock quantity : Int) (available : ¬ stock < quantity) :
    interpret program ⟨stock, none⟩ quantity =
      .success ⟨stock - quantity, some quantity⟩ quantity
        [.stock (stock - quantity), .reservation quantity] ∧
    interpret program ⟨stock - quantity, some quantity⟩ quantity =
      .success ⟨stock - quantity, some quantity⟩ quantity [] := by
  constructor
  · simpa [contract, available] using
      accepted_matches_contract program verified ⟨stock, none⟩ quantity
  · simpa [contract] using
      accepted_matches_contract program verified ⟨stock - quantity, some quantity⟩ quantity

def parseProgram : List String → Option Program
  | [existing, debit, stock, delta] => do
    let conflict : ExistingConflict ← match existing with
      | "different" => some .different
      | "same" => some .same
      | _ => none
    let debitWhen : DebitWhen ← match debit with
      | "missing" => some .missing
      | "present" => some .present
      | "always" => some .always
      | "never" => some .never
      | _ => none
    let stockConflict : StockConflict ← match stock with
      | "less" => some .less
      | "less-or-equal" => some .lessOrEqual
      | _ => none
    let adjustment : Adjustment ← match delta with
      | "subtract" => some .subtract
      | "add" => some .add
      | _ => none
    return ⟨conflict, debitWhen, stockConflict, adjustment⟩
  | _ => none

end IndependentLean

def main (args : List String) : IO UInt32 := do
  let some program := IndependentLean.parseProgram args | return 2
  if IndependentLean.accepts program then
    IO.println "VERIFIED"
    return 0
  else
    IO.println "MISMATCH"
    return 10
