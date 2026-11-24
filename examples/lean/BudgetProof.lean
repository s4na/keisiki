import GeneratedRuby
import VerificationClaim

open Keisiki

namespace Verification

theorem computesExpected (available requested : Int) :
    IR.invoke (lowerProgram GeneratedRuby.program) "Budget.remaining" [available, requested] =
      .ok (expected available requested) := by
  by_cases tooLarge : requested > available
  · have notLe : ¬ requested ≤ available := by omega
    simp [IR.invoke, execute, GeneratedRuby.program, lowerProgram, lowerMethod, lookup,
      lower, lowerArguments, IR.eval, IR.evalArguments, IR.IntOp.apply, expected, tooLarge, notLe,
      Except.bind, Except.pure, pure, bind]
  · have le : requested ≤ available := by omega
    simp [IR.invoke, execute, GeneratedRuby.program, lowerProgram, lowerMethod, lookup,
      lower, lowerArguments, IR.eval, IR.evalArguments, IR.IntOp.apply, expected, tooLarge, le,
      Except.bind, Except.pure, pure, bind]

theorem certificate : claim.Holds GeneratedRuby.program := by
  intro arguments pre
  rcases arguments with _ | ⟨available, _ | ⟨requested, _ | ⟨_, _⟩⟩⟩
  · exact False.elim pre
  · exact False.elim pre
  · refine ⟨expected available requested, ?_, rfl, ?_⟩
    · rw [← invoke_lower]
      exact computesExpected available requested
    · have availableNonnegative : 0 ≤ available := pre.1
      simp only [expected]
      split <;> omega
  · exact False.elim pre

end Verification
