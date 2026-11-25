
def samples : List (Int × Int × Option Int) := do
  let values : List Int := [-3, -2, -1, 0, 1, 2, 3, 4]
  let stock ← values
  let requested ← values
  let previous ← [none, some requested, some (requested + 1)]
  pure (stock, requested, previous)

def mismatch : Option (Int × Int × Option Int) :=
  samples.find? (fun (stock, requested, previous) =>
    decide (generated stock requested previous ≠ expected stock requested previous))

theorem p1_counterexample :
    ∃ (stock requested : Int) (previous : Option Int),
      generated stock requested previous ≠ expected stock requested previous := by
  have found : mismatch.isSome = true := by decide
  unfold mismatch at found
  obtain ⟨⟨stock, requested, previous⟩, _, disagrees⟩ := List.find?_isSome.mp found
  exact ⟨stock, requested, previous, of_decide_eq_true disagrees⟩

#eval mismatch
#print axioms p1_counterexample
end ReserveStockSource
