import GeneratedSQL

open Keisiki.Postgres

theorem checkedCertificate (initial : Int) (nonnegative : 0 ≤ initial) (history : List Transaction) :
    NoOversell initial (run GeneratedSQL.update ⟨initial, 0⟩ history) :=
  no_oversell GeneratedSQL.update (by decide) (by decide) initial nonnegative history
