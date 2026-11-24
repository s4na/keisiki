require "open3"
require_relative "integer_expression"

class StockVerifier
  Unsupported = IntegerExpression::Unsupported

  PARAMETERS = %i[stock quantity].freeze

  def initialize(method)
    @method = method
  end

  def check
    expression = IntegerExpression.new(@method, module_name: :Stock, parameters: PARAMETERS).to_smt
    query = <<~SMT
      (set-logic QF_LIA)
      (set-option :produce-models true)
      (declare-const stock Int)
      (declare-const quantity Int)
      (assert (and (>= stock 0) (>= quantity 0) (< #{expression} 0)))
      (check-sat)
    SMT

    case solve(query)
    when "unsat"
      [:unsat, nil]
    when "sat"
      model = solve(query + "(get-value (stock quantity))\n")
      match = /\Asat\s+\(\(stock\s+(\d+)\)\s+\(quantity\s+(\d+)\)\)\z/.match(model)
      raise "Unexpected Z3 model: #{model}" unless match

      stock, quantity = match.captures.map(&:to_i)
      [:sat, { stock: stock, quantity: quantity }]
    when "unknown"
      [:unknown, nil]
    else
      raise "Unexpected Z3 response"
    end
  end

  private

  def solve(query)
    output, error, status = Open3.capture3("z3", "-in", "-T:10", stdin_data: query)
    raise "Z3 failed: #{output}#{error}" unless status.success?

    output.strip
  end
end
