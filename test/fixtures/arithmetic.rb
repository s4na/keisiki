module ArithmeticFixture
  def self.combine(first, second, third)
    first + (second - third)
  end

  def self.fallback
    -7
  end

  def self.choose(first, second, third)
    if first - second > 0
      self.combine(first, second, third)
    else
      self.fallback()
    end
  end
end
