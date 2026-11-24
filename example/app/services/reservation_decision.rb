module ReservationDecision
  def self.next_stock(observed, available)
    if available > 0
      available - 1
    else
      -1
    end
  end
end
