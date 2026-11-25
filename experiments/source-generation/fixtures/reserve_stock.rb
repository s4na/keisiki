class ReserveStock
  class Conflict < StandardError; end

  def call(reservation_id:, quantity:)
    Stock.transaction do
      stock = Stock.lock.find(1)
      reservation = Reservation.find_by(id: reservation_id)
      raise Conflict if reservation && reservation.quantity != quantity

      if debit_stock?(reservation)
        raise Conflict if stock.quantity < quantity

        stock.update!(quantity: stock.quantity - quantity)
      end
      reservation || Reservation.create!(id: reservation_id, stock_id: stock.id, quantity: quantity)
    end
  end

  private

  def debit_stock?(reservation)
    reservation.nil?
  end
end
