module CheckoutFulfillment
  def self.units(requested, available)
    [requested, available].min
  end
end
