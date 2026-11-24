class CheckoutController < ActionController::API
  def quote
    requested = params[:requested]
    available = params[:available]
    volume_offer = params[:volume_offer]
    coupon = params[:coupon]

    unless [requested, available].all? { |count| count.is_a?(Integer) && count >= 0 } &&
        [volume_offer, coupon].all? { |flag| flag == true || flag == false }
      return head :bad_request
    end

    render json: CheckoutQuote.call(requested: requested, available: available, volume_offer: volume_offer, coupon: coupon)
  end
end
