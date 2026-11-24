import GeneratedSQL

open Keisiki.Postgres

def witness : State :=
  run GeneratedSQL.update ⟨0, 0⟩ [⟨-1, .commit⟩]

theorem checkedCertificate : witness.remaining = 1 ∧ witness.reserved = -1 ∧ ¬ NoOversell 0 witness := by
  refine ⟨rfl, rfl, ?_⟩
  intro safe
  have reserved := safe.2.1
  change 0 ≤ (-1 : Int) at reserved
  omega
