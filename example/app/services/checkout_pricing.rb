module CheckoutPricing
  def self.subtotal(fulfilled)
    40 * fulfilled
  end

  def self.volume_discount(quantity, enabled)
    enabled && quantity >= 3 ? 20 : 0
  end

  def self.coupon_discount(fulfilled, enabled)
    enabled && fulfilled.positive? ? 20 : 0
  end
end
