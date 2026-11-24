class ReservationStore
  def initialize(stock)
    @stock = stock
    @lock = Mutex.new
  end

  def reserve
    commit(read_stock)
  end

  private

  def read_stock
    @lock.synchronize { @stock }
  end

  def commit(observed)
    @lock.synchronize do
      next_stock = ReservationDecision.next_stock(observed, @stock)
      return false if next_stock.negative?

      @stock = next_stock
      true
    end
  end
end
