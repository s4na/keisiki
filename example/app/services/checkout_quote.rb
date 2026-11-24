module CheckoutQuote
  def self.call(requested:, available:, volume_offer:, coupon:)
    fulfilled = CheckoutFulfillment.units(requested, available)
    subtotal = CheckoutPricing.subtotal(fulfilled)
    volume_discount = CheckoutPricing.volume_discount(fulfilled, volume_offer)
    coupon_discount = CheckoutPricing.coupon_discount(fulfilled, coupon)
    merchandise = [subtotal - volume_discount - coupon_discount, 0].max
    shipping = CheckoutShipping.fee(fulfilled, merchandise)

    { fulfilled: fulfilled, merchandise: merchandise, shipping: shipping, total: merchandise + shipping }
  end
end
