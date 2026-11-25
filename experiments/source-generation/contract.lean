import Lean

namespace ReserveStockSource

inductive Attempt where
  | conflict
  | reused (write : Option Int)
  | created (write : Option Int)
  deriving DecidableEq

def finish (previous : Option Int) (write : Option Int) : Attempt :=
  match previous with
  | none => .created write
  | some _ => .reused write

def expected (stock requested : Int) (previous : Option Int) : Attempt :=
  match previous with
  | some reserved =>
    if reserved = requested then .reused none else .conflict
  | none =>
    if stock < requested then .conflict else .created (some (stock - requested))
