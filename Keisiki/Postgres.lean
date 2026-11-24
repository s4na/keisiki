namespace Keisiki.Postgres

structure Update where
  stockGuard : Bool
  positiveGuard : Bool

def Update.returning (query : Update) (available requested : Int) : Option Int :=
  if (query.stockGuard = true → requested ≤ available) ∧
      (query.positiveGuard = true → 0 < requested) then
    some (available - requested)
  else
    none

inductive End where
  | commit
  | rollback

structure Transaction where
  requested : Int
  finish : End

structure State where
  remaining : Int
  reserved : Int

def step (query : Update) (state : State) (transaction : Transaction) : State :=
  match transaction.finish with
  | .rollback => state
  | .commit =>
    match query.returning state.remaining transaction.requested with
    | none => state
    | some remaining => ⟨remaining, state.reserved + transaction.requested⟩

def run (query : Update) (state : State) (transactions : List Transaction) : State :=
  transactions.foldl (step query) state

def NoOversell (initial : Int) (state : State) : Prop :=
  0 ≤ state.remaining ∧ 0 ≤ state.reserved ∧ state.remaining + state.reserved = initial ∧
    state.reserved ≤ initial

theorem Update.returning_bounded
    (query : Update) (stockGuard : query.stockGuard = true) (positiveGuard : query.positiveGuard = true)
    {available requested remaining : Int} (ran : query.returning available requested = some remaining) :
    0 ≤ remaining ∧ 0 < requested ∧ remaining + requested = available ∧ remaining ≤ available := by
  simp [Update.returning, stockGuard, positiveGuard] at ran
  obtain ⟨⟨enough, positive⟩, balance⟩ := ran
  omega

theorem step_preserves
    (query : Update) (stockGuard : query.stockGuard = true) (positiveGuard : query.positiveGuard = true)
    (transaction : Transaction) (safe : NoOversell initial state) :
    NoOversell initial (step query state transaction) := by
  cases finish : transaction.finish
  · simp only [step, finish]
    cases result : query.returning state.remaining transaction.requested
    · exact safe
    · rename_i remaining
      obtain ⟨remainingNonnegative, requestedPositive, balance, _⟩ :=
        query.returning_bounded stockGuard positiveGuard result
      obtain ⟨_, reservedNonnegative, initialBalance, _⟩ := safe
      change 0 ≤ remaining ∧ 0 ≤ state.reserved + transaction.requested ∧
        remaining + (state.reserved + transaction.requested) = initial ∧
        state.reserved + transaction.requested ≤ initial
      omega
  · simpa [step, finish] using safe

theorem run_preserves
    (query : Update) (stockGuard : query.stockGuard = true) (positiveGuard : query.positiveGuard = true)
    (transactions : List Transaction) (safe : NoOversell initial state) :
    NoOversell initial (run query state transactions) := by
  induction transactions generalizing state with
  | nil => exact safe
  | cons transaction rest ih =>
    exact ih (step_preserves query stockGuard positiveGuard transaction safe)

theorem no_oversell
    (query : Update) (stockGuard : query.stockGuard = true) (positiveGuard : query.positiveGuard = true)
    (initial : Int) (nonnegative : 0 ≤ initial) (transactions : List Transaction) :
    NoOversell initial (run query ⟨initial, 0⟩ transactions) := by
  apply run_preserves query stockGuard positiveGuard
  simp [NoOversell, nonnegative]

end Keisiki.Postgres
