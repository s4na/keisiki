module Stock
  def self.remaining(stock, quantity)
    if quantity > stock
      stock
    else
      stock - quantity
    end
  end
end
