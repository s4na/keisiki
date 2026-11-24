import GeneratedSQL

open Keisiki.Postgres

def witness : State :=
  run GeneratedSQL.update ⟨1, 0⟩ [⟨1, .commit⟩, ⟨1, .commit⟩]

theorem checkedCertificate : witness.remaining = -1 ∧ witness.reserved = 2 ∧ ¬ NoOversell 1 witness := by
  refine ⟨rfl, rfl, ?_⟩
  intro safe
  have remains := safe.1
  change 0 ≤ (-1 : Int) at remains
  omega
