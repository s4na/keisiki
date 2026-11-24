import Keisiki

open Keisiki

namespace Verification

def expected (available requested : Int) : Int :=
  if requested > available then available else available - requested

def claim : Contract where
  entry := "Budget.remaining"
  pre := fun arguments =>
    match arguments with
    | [available, requested] => 0 ≤ available ∧ 0 ≤ requested
    | _ => False
  post := fun arguments result =>
    match arguments with
    | [available, requested] => result = expected available requested ∧ 0 ≤ result
    | _ => False

end Verification
