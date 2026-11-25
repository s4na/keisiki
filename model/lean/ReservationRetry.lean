import Lean

open Lean

namespace ReservationRetry

structure Request where
  reservation_id : String
  quantity : Nat
  deriving ToJson

structure Snapshot where
  phase : String
  stock : Nat
  reservations : List Request := []
  firstResult : Option Request := none
  retryResult : Option Request := none
  deriving ToJson

def initial (stock : Nat) : Snapshot :=
  { phase := "ready", stock }

def commitReservation (stock : Nat) (request : Request) : Snapshot :=
  if 0 < request.quantity ∧ request.quantity ≤ stock then
    { phase := "committed", stock := stock - request.quantity,
      reservations := [request], firstResult := some request }
  else
    initial stock

def loseResponse (state : Snapshot) : Snapshot :=
  { state with phase := "response_lost" }

def retry (doubleUpdate : Bool) (state : Snapshot) : Snapshot :=
  let stock := if doubleUpdate then
    state.stock - (state.firstResult.map (·.quantity)).getD 0
  else state.stock
  { state with phase := "retried", retryResult := state.firstResult, stock }

def trace (stock : Nat) (request : Request) (doubleUpdate : Bool) : List Snapshot :=
  let committed := commitReservation stock request
  let lost := loseResponse committed
  [initial stock, committed, lost, retry doubleUpdate lost]

theorem normal_retry_is_idempotent (stock : Nat) (request : Request)
    (available : 0 < request.quantity ∧ request.quantity ≤ stock) :
    let committed := commitReservation stock request
    let lost := loseResponse committed
    let retried := retry false lost
    committed.stock = stock - request.quantity ∧
      lost.stock = committed.stock ∧ lost.reservations = committed.reservations ∧
      retried.stock = committed.stock ∧ retried.reservations = [request] ∧
      retried.firstResult = some request ∧ retried.retryResult = some request := by
  simp [commitReservation, available, loseResponse, retry]

def exampleRequest : Request := { reservation_id := "reservation-1", quantity := 1 }

theorem double_update_spends_twice :
    (retry true (loseResponse (commitReservation 2 exampleRequest))).stock = 0 := by
  decide

#print axioms normal_retry_is_idempotent
#print axioms double_update_spends_twice

end ReservationRetry

def main : List String → IO UInt32
  | [output] => do
    let request := ReservationRetry.exampleRequest
    let result := Json.mkObj [
      ("baseline", toJson (ReservationRetry.trace 2 request false)),
      ("double_update", toJson (ReservationRetry.trace 2 request true))]
    IO.FS.writeFile output (result.pretty ++ "\n")
    return 0
  | _ => do
    IO.eprintln "Usage: lean --run model/lean/ReservationRetry.lean OUTPUT.json"
    return 2
