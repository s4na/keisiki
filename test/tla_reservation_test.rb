require "json"
require "minitest/autorun"
require ENV.fetch("DECISION_SOURCE")
require_relative "../example/app/services/reservation_store"
require_relative "../lib/tlc_trace_replay"

class TlaReservationTest < Minitest::Test
  def test_reservation_outcomes_match_the_model
    fixture = JSON.parse(File.read(ENV.fetch("TLA_TRACE_FIXTURE")))
    store = ReservationStore.new(1)
    actual = TlcTraceReplay.call(
      fixture.fetch("steps"), stages: { "read" => :read_stock, "commit" => :commit },
      target: ReservationStore
    ) { |_request| store.reserve }

    assert_equal fixture.fetch("expected"), actual, "Reservation outcomes differ from the TLA+ trace"
  end
end
