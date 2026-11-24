import Keisiki.Semantics

namespace Keisiki

mutual
  def lower : Source.Expr → IR.Expr
    | .literal value => .constant value
    | .parameter index => .load index
    | .add lhs rhs => .binary .add (lower lhs) (lower rhs)
    | .subtract lhs rhs => .binary .subtract (lower lhs) (lower rhs)
    | .ifGreater lhs rhs yes no => .branchLe (lower lhs) (lower rhs) (lower no) (lower yes)
    | .call name arguments => .invoke name (lowerArguments arguments)

  def lowerArguments : Source.Arguments → IR.Arguments
    | .none => .empty
    | .next first rest => .push (lower first) (lowerArguments rest)
end

mutual
  theorem lower_sound (dispatch : Dispatch) (locals : List Int) (term : Source.Expr) :
      IR.eval dispatch locals (lower term) = Source.eval dispatch locals term := by
    cases term with
    | literal => rfl
    | parameter => rfl
    | add lhs rhs =>
      simp only [lower, IR.eval, Source.eval, lower_sound dispatch locals lhs,
        lower_sound dispatch locals rhs, IR.IntOp.apply]
    | subtract lhs rhs =>
      simp only [lower, IR.eval, Source.eval, lower_sound dispatch locals lhs,
        lower_sound dispatch locals rhs, IR.IntOp.apply]
    | ifGreater lhs rhs yes no =>
      simp only [lower, IR.eval, Source.eval, lower_sound dispatch locals lhs,
        lower_sound dispatch locals rhs, lower_sound dispatch locals yes,
        lower_sound dispatch locals no]
      apply congrArg ((Source.eval dispatch locals lhs).bind)
      funext left
      apply congrArg ((Source.eval dispatch locals rhs).bind)
      funext right
      by_cases le : left ≤ right
      · have notGreater : ¬ left > right := by omega
        simp [le, notGreater]
      · have greater : left > right := by omega
        simp [le, greater]
    | call name arguments =>
      simp only [lower, IR.eval, Source.eval, lower_arguments_sound dispatch locals arguments]

  theorem lower_arguments_sound (dispatch : Dispatch) (locals : List Int) (terms : Source.Arguments) :
      IR.evalArguments dispatch locals (lowerArguments terms) = Source.evalArguments dispatch locals terms := by
    cases terms with
    | none => rfl
    | next first rest =>
      simp only [lowerArguments, IR.evalArguments, Source.evalArguments,
        lower_sound dispatch locals first, lower_arguments_sound dispatch locals rest]
end

def lowerMethod (method : Method Source.Expr) : Method IR.Expr :=
  ⟨method.name, method.arity, lower method.body⟩

def lowerProgram (program : Program Source.Expr) : Program IR.Expr :=
  program.map lowerMethod

theorem lookup_lower (program : Program Source.Expr) (name : String) :
    lookup name (lowerProgram program) = (lookup name program).map lowerMethod := by
  induction program with
  | nil => rfl
  | cons method rest ih =>
    simp only [lowerProgram, List.map_cons] at ih ⊢
    simp only [lookup, lowerMethod]
    split <;> simp_all [lowerMethod]

theorem execute_lower (program : Program Source.Expr) (budget : Nat) :
    execute IR.eval (lowerProgram program) budget = execute Source.eval program budget := by
  induction budget with
  | zero => rfl
  | succ budget ih =>
    funext name arguments
    simp only [execute, lookup_lower]
    cases lookup name program with
    | none => rfl
    | some method =>
      simp only [Option.map_some, lowerMethod, ih]
      split
      · exact lower_sound _ _ _
      · rfl

theorem invoke_lower (program : Program Source.Expr) :
    IR.invoke (lowerProgram program) = Source.invoke program := by
  unfold IR.invoke Source.invoke
  rw [show (lowerProgram program).length = program.length by simp [lowerProgram]]
  exact execute_lower program program.length

end Keisiki
