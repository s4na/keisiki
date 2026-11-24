module CheckoutShipping
  def self.fee(fulfilled, merchandise)
    fulfilled.zero? || merchandise >= 100 ? 0 : 12
  end
end
