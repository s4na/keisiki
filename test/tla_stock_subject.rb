require ENV.fetch("STOCK_SOURCE")

module TlaUnitSubject
  def self.call(stock, quantity)
    Stock.remaining(stock, quantity)
  end
end
