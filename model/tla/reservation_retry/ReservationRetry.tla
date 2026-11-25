--------------------------- MODULE ReservationRetry ---------------------------
EXTENDS Integers

CONSTANT DoubleUpdate
VARIABLES phase, stock, reservations, firstResult, retryResult

vars == <<phase, stock, reservations, firstResult, retryResult>>
InitialStock == 2
Request == [reservation_id |-> "reservation-1", quantity |-> 1]
NoResult == [reservation_id |-> "", quantity |-> 0]

Init ==
  /\ phase = "ready"
  /\ stock = InitialStock
  /\ reservations = {}
  /\ firstResult = NoResult
  /\ retryResult = NoResult

Commit ==
  /\ phase = "ready"
  /\ phase' = "committed"
  /\ stock' = stock - Request.quantity
  /\ reservations' = {Request}
  /\ firstResult' = Request
  /\ UNCHANGED retryResult

LoseResponse ==
  /\ phase = "committed"
  /\ phase' = "response_lost"
  /\ UNCHANGED <<stock, reservations, firstResult, retryResult>>

Retry ==
  /\ phase = "response_lost"
  /\ phase' = "retried"
  /\ stock' = IF DoubleUpdate THEN stock - Request.quantity ELSE stock
  /\ retryResult' = firstResult
  /\ UNCHANGED <<reservations, firstResult>>

Next == Commit \/ LoseResponse \/ Retry

P1 ==
  /\ (phase # "ready") =>
        /\ stock = InitialStock - Request.quantity
        /\ reservations = {Request}
        /\ firstResult = Request
  /\ (phase = "retried") => retryResult = firstResult
=============================================================================
