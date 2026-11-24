class StockController < ActionController::API
  def reserve
    accepted = Rails.configuration.x.reservations.reserve
    head(accepted ? :created : :conflict)
  end

  def remaining
    stock = nonnegative_integer(params[:stock])
    quantity = nonnegative_integer(params[:quantity])
    return head :bad_request if stock.nil? || quantity.nil?

    render json: { remaining: Stock.remaining(stock, quantity) }
  end

  private

  def nonnegative_integer(value)
    return unless value.is_a?(String)

    integer = Integer(value, 10, exception: false)
    integer if integer && integer >= 0
  end
end
