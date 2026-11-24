require "open3"
require "prism"

class StockVerifier
  class Unsupported < StandardError; end

  PARAMETERS = %i[stock quantity].freeze

  def initialize(method)
    @method = method
  end

  def check
    expression = translate_method
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

  def translate_method
    path, line = @method.source_location
    raise Unsupported, "method has no Ruby source" unless path

    parsed = Prism.parse_file(path)
    raise Unsupported, "unable to parse #{path}" unless parsed.success?

    wrapper = only_statement(parsed.value.statements)
    unless wrapper.is_a?(Prism::ModuleNode) &&
        wrapper.constant_path.is_a?(Prism::ConstantReadNode) &&
        wrapper.constant_path.name == :Stock
      raise Unsupported, "expected a single Stock module in #{path}"
    end

    definition = only_statement(wrapper.body)
    unless definition.is_a?(Prism::DefNode) && definition.receiver.is_a?(Prism::SelfNode) &&
        definition.name == @method.name && definition.location.start_line == line &&
        @method.parameters == PARAMETERS.map { |name| [:req, name] }
      raise Unsupported, "expected def self.remaining(stock, quantity) at #{path}:#{line}"
    end

    integer(only_statement(definition.body))
  end

  def only_statement(statements)
    unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1
      raise Unsupported, "expected a single expression"
    end

    statements.body.first
  end

  def integer(node)
    case node
    when Prism::LocalVariableReadNode
      return node.name.to_s if PARAMETERS.include?(node.name)
    when Prism::IntegerNode
      return node.value.negative? ? "(- #{-node.value})" : node.value.to_s
    when Prism::CallNode
      left, right = operands(node, :-)
      return "(- #{left} #{right})"
    when Prism::IfNode
      if node.subsequent.is_a?(Prism::ElseNode)
        left, right = operands(node.predicate, :>)
        consequent = integer(only_statement(node.statements))
        alternative = integer(only_statement(node.subsequent.statements))
        return "(ite (> #{left} #{right}) #{consequent} #{alternative})"
      end
    end

    raise Unsupported, "unsupported #{node.class} at line #{node.location.start_line}"
  end

  def operands(node, operator)
    arguments = node.arguments&.arguments if node.is_a?(Prism::CallNode)
    unless node.is_a?(Prism::CallNode) && node.name == operator &&
        node.receiver && node.block.nil? && node.call_operator_loc.nil? && arguments&.size == 1
      raise Unsupported, "expected integer #{operator} at line #{node.location.start_line}"
    end

    [integer(node.receiver), integer(arguments.first)]
  end
end
