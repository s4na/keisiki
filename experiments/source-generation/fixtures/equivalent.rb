class ReserveStock
  class Conflict < StandardError; end

  def call(reservation_id:, quantity:)
    Stock.transaction do
      stock = Stock.lock.find(1)
      reservation = Reservation.find_by(id: reservation_id)
      raise Conflict if reservation && reservation.quantity != quantity

      if debit_stock?(reservation)
        raise Conflict if quantity > stock.quantity
        stock.update!(quantity: stock.quantity + (0 - quantity))
      end

      reservation || Reservation.create!(id: reservation_id, stock_id: stock.id, quantity: quantity)
    end
  end

  private

  def debit_stock?(reservation)
    !reservation
  end
end
