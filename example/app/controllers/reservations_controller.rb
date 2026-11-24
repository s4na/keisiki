class ReservationsController < ActionController::API
  def create
    reservation_id = params[:reservation_id]
    quantity = params[:quantity]
    return head :bad_request unless valid_request?(reservation_id, quantity)

    reservation = ReserveStock.new.call(reservation_id: reservation_id, quantity: quantity)
    render json: { reservation_id: reservation.id, quantity: reservation.quantity }, status: :created
  rescue ReserveStock::Conflict
    head :conflict
  end

  private

  def valid_request?(reservation_id, quantity)
    reservation_id.is_a?(String) && /\A[a-zA-Z0-9_-]{1,80}\z/.match?(reservation_id) &&
      quantity.is_a?(Integer) && quantity.between?(1, (2**63) - 1)
  end
end
