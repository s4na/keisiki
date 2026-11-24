import GeneratedRuby
import VerificationClaim

open Keisiki

namespace Verification

def witness : Witness := ⟨[2, 2], 2⟩

theorem certificate : claim.RefutesAt GeneratedRuby.program witness := by
  refine ⟨?_, rfl, ?_⟩
  · change 0 ≤ (2 : Int) ∧ 0 ≤ (2 : Int)
    decide
  · change ¬ ((2 : Int) = expected 2 2 ∧ 0 ≤ (2 : Int))
    decide

end Verification
