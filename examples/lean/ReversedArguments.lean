import GeneratedRuby
import VerificationClaim

open Keisiki

namespace Verification

def witness : Witness := ⟨[1, 3], 0⟩

theorem certificate : claim.RefutesAt GeneratedRuby.program witness := by
  refine ⟨?_, rfl, ?_⟩
  · change 0 ≤ (1 : Int) ∧ 0 ≤ (3 : Int)
    decide
  · change ¬ ((0 : Int) = expected 1 3 ∧ 0 ≤ (0 : Int))
    decide

end Verification
