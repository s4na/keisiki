module TlaStockMutations
  SUBTRACTION = "      stock - quantity\n"

  def self.small(original)
    {
      "zero_returns_one" => replace_subtraction(original, <<~RUBY),
        if stock > 0
          stock - quantity
        else
          1
        end
      RUBY
      "oversell" => original.sub(/    if quantity > stock\n.*?    end\n/m, "    stock - quantity\n"),
      "exact_small_stock" => replace_subtraction(original, <<~RUBY)
        if quantity > 1
          stock - quantity - 1
        else
          stock - quantity
        end
      RUBY
    }
  end

  def self.ruby_method_call(original)
    replace_subtraction(original, <<~RUBY)
      if stock.zero?
        1
      else
        stock - quantity
      end
    RUBY
  end

  def self.replace_subtraction(original, expression)
    raise "Could not locate stock subtraction" unless original.include?(SUBTRACTION)

    original.sub(SUBTRACTION, expression.lines.map { |line| "      #{line}" }.join)
  end
  private_class_method :replace_subtraction
end
