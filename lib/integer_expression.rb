require "prism"

class IntegerExpression
  class Unsupported < StandardError; end

  def initialize(method, module_name:, parameters:)
    @method = method
    @module_name = module_name
    @parameters = parameters
    @expression = read_method
  end

  def to_smt
    smt(@expression)
  end

  def to_quint
    quint(@expression)
  end

  def to_tla
    tla(@expression)
  end

  private

  def read_method
    path, line = @method.source_location
    raise Unsupported, "method has no Ruby source" unless path

    parsed = Prism.parse_file(path)
    raise Unsupported, "unable to parse #{path}" unless parsed.success?

    wrapper = only_statement(parsed.value.statements)
    unless wrapper.is_a?(Prism::ModuleNode) &&
        wrapper.constant_path.is_a?(Prism::ConstantReadNode) &&
        wrapper.constant_path.name == @module_name
      raise Unsupported, "expected a single #{@module_name} module in #{path}"
    end

    definition = only_statement(wrapper.body)
    unless definition.is_a?(Prism::DefNode) && definition.receiver.is_a?(Prism::SelfNode) &&
        definition.name == @method.name && definition.location.start_line == line &&
        @method.parameters == @parameters.map { |name| [:req, name] }
      raise Unsupported, "unexpected method definition at #{path}:#{line}"
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
      return [:parameter, node.name] if @parameters.include?(node.name)
    when Prism::IntegerNode
      return [:integer, node.value]
    when Prism::CallNode
      return [:-, *operands(node, :-)]
    when Prism::IfNode
      if node.subsequent.is_a?(Prism::ElseNode)
        condition = [:>, *operands(node.predicate, :>)]
        consequent = integer(only_statement(node.statements))
        alternative = integer(only_statement(node.subsequent.statements))
        return [:if, condition, consequent, alternative]
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

  def smt(term)
    case term
    in [:parameter, name]
      name.to_s
    in [:integer, value]
      value.negative? ? "(- #{-value})" : value.to_s
    in [:- | :> => operator, left, right]
      "(#{operator} #{smt(left)} #{smt(right)})"
    in [:if, condition, consequent, alternative]
      "(ite #{smt(condition)} #{smt(consequent)} #{smt(alternative)})"
    end
  end

  def quint(term)
    case term
    in [:parameter, name]
      name.to_s
    in [:integer, value]
      value.to_s
    in [:- | :> => operator, left, right]
      "(#{quint(left)} #{operator} #{quint(right)})"
    in [:if, condition, consequent, alternative]
      "(if (#{quint(condition)}) #{quint(consequent)} else #{quint(alternative)})"
    end
  end

  def tla(term)
    case term
    in [:parameter, name]
      name.to_s
    in [:integer, value]
      value.to_s
    in [:- | :> => operator, left, right]
      "(#{tla(left)} #{operator} #{tla(right)})"
    in [:if, condition, consequent, alternative]
      "(IF #{tla(condition)} THEN #{tla(consequent)} ELSE #{tla(alternative)})"
    end
  end
end
