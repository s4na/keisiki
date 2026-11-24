require "digest"
require "prism"

class RubyToLean
  class Unsupported < StandardError; end

  Definition = Data.define(:name, :parameters, :body, :file, :calls)
  Call = Data.define(:name, :arity, :location)

  METHOD_NAME = /\A[a-z_][a-zA-Z0-9_]*\z/
  MODULE_NAME = /\A[A-Z][a-zA-Z0-9_]*\z/
  HOOKS = %w[const_missing method_missing singleton_method_added singleton_method_removed singleton_method_undefined].freeze
  OPERATORS = { :+ => "add", :- => "subtract" }.freeze

  def self.generate(paths)
    new.generate(paths)
  end

  def generate(paths)
    @definitions = {}
    modules = {}
    digests = paths.map do |file|
      source = File.binread(file)
      result = Prism.parse(source, filepath: file)
      unless result.success?
        raise Unsupported, "#{file}: #{result.errors.map(&:message).join(", ")}"
      end

      result.value.statements.body.each { |node| read_module(file, node, modules) }
      Digest::SHA256.hexdigest(source)
    end
    raise Unsupported, "no method definitions" if @definitions.empty?

    methods = @definitions.values.sort_by(&:name)
    bodies = methods.to_h { |method| [method.name, expression(context: method, node: method.body)] }
    validate_calls(methods)

    definitions = methods.map do |method|
      "  ⟨#{method.name.dump}, #{method.parameters.length}, #{bodies.fetch(method.name)}⟩"
    end
    <<~LEAN
      import Keisiki

      namespace GeneratedRuby

      def sourceDigests : List String := [#{digests.sort.map(&:dump).join(", ")}]

      def program : Keisiki.Program Keisiki.Source.Expr := [
      #{definitions.join(",\n")}
      ]

      end GeneratedRuby
    LEAN
  end

  private

  def read_module(file, node, modules)
    unless node.is_a?(Prism::ModuleNode) && node.constant_path.is_a?(Prism::ConstantReadNode) &&
        MODULE_NAME.match?(node.constant_path.name)
      reject(file, node, "expected a top-level named module")
    end

    owner = node.constant_path.name.to_s
    reject(file, node, "module reopening is unsupported: #{owner}") if modules[owner]

    modules[owner] = true
    node.body&.body&.each do |definition|
      unless definition.is_a?(Prism::DefNode) && definition.receiver.is_a?(Prism::SelfNode) &&
          METHOD_NAME.match?(definition.name) && !HOOKS.include?(definition.name.to_s)
        reject(file, definition, "expected an ordinary def self.method")
      end

      parameters = definition.parameters&.child_nodes&.compact || []
      unless parameters.all? { |parameter| parameter.is_a?(Prism::RequiredParameterNode) }
        reject(file, definition, "only required positional parameters are supported")
      end
      names = parameters.map(&:name)
      reject(file, definition, "duplicate parameter names are unsupported") unless names.uniq == names

      name = "#{owner}.#{definition.name}"
      reject(file, definition, "duplicate method #{name}") if @definitions.key?(name)

      body = single_expression(file, definition.body, definition)
      @definitions[name] = Definition.new(name, names, body, file, [])
    end
  end

  def single_expression(file, statements, location)
    unless statements.is_a?(Prism::StatementsNode) && statements.body.size == 1
      reject(file, location, "expected a single expression")
    end

    statements.body.first
  end

  def expression(context:, node:)
    case node
    when Prism::IntegerNode
      "(.literal (#{node.value}))"
    when Prism::LocalVariableReadNode
      index = context.parameters.index(node.name)
      reject(context.file, node, "expected a method parameter") unless index && node.depth.zero?

      "(.parameter #{index})"
    when Prism::ParenthesesNode
      expression(context: context, node: single_expression(context.file, node.body, node))
    when Prism::IfNode
      conditional(context, node)
    when Prism::CallNode
      call(context, node)
    else
      reject(context.file, node, "unsupported expression #{node.class.name}")
    end
  end

  def conditional(context, node)
    predicate = node.predicate
    unless node.subsequent.is_a?(Prism::ElseNode) && predicate.is_a?(Prism::CallNode) &&
        predicate.name == :> && infix?(predicate)
      reject(context.file, node, "expected if lhs > rhs with an explicit else")
    end

    yes = single_expression(context.file, node.statements, node)
    no = single_expression(context.file, node.subsequent.statements, node.subsequent)
    nodes = [predicate.receiver, predicate.arguments.arguments.first, yes, no]
    "(.ifGreater #{nodes.map { |child| expression(context: context, node: child) }.join(" ")})"
  end

  def infix?(node)
    node.receiver && node.call_operator_loc.nil? && node.block.nil? && node.arguments&.arguments&.size == 1
  end

  def call(context, node)
    if OPERATORS.key?(node.name) && infix?(node)
      lhs = expression(context: context, node: node.receiver)
      rhs = expression(context: context, node: node.arguments.arguments.first)
      return "(.#{OPERATORS.fetch(node.name)} #{lhs} #{rhs})"
    end

    unless METHOD_NAME.match?(node.name) && node.block.nil? && node.call_operator_loc&.slice == "."
      reject(context.file, node, "unsupported call #{node.name}")
    end

    owner = case node.receiver
    when Prism::SelfNode then context.name.split(".").first
    when Prism::ConstantReadNode then node.receiver.name.to_s
    end
    reject(context.file, node, "expected a statically named module receiver") unless owner && MODULE_NAME.match?(owner)

    name = "#{owner}.#{node.name}"
    arguments = node.arguments&.arguments || []
    context.calls << Call.new(name, arguments.length, node)
    terms = arguments.map { |argument| expression(context: context, node: argument) }
    list = terms.reverse.reduce(".none") { |rest, term| "(.next #{term} #{rest})" }
    "(.call #{name.dump} #{list})"
  end

  def validate_calls(methods)
    visited = {}
    methods.each { |method| visit(method, visited, []) }
  end

  def visit(method, visited, stack)
    return if visited[method.name]

    stack << method.name
    method.calls.each do |call|
      target = @definitions[call.name]
      reject(method.file, call.location, "unknown method #{call.name}") unless target
      reject(method.file, call.location, "wrong arity for #{call.name}") unless call.arity == target.parameters.length
      if stack.include?(call.name)
        reject(method.file, call.location, "recursive call graph: #{(stack + [call.name]).join(" -> ")}")
      end

      visit(target, visited, stack)
    end
    stack.pop
    visited[method.name] = true
  end

  def reject(file, node, reason)
    raise Unsupported, "#{file}:#{node.location.start_line}: #{reason}"
  end
end
