# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "ripper"
require "tmpdir"

module ReserveStockSource
  class Unsupported < StandardError; end
  class CheckError < StandardError; end

  SHAPE = <<~RUBY
    class ReserveStock
      class Conflict < StandardError; end

      def call(reservation_id:, quantity:)
        Stock.transaction do
          stock = Stock.lock.find(1)
          reservation = Reservation.find_by(id: reservation_id)
          raise Conflict if reservation && reservation.quantity != quantity

          if capture_debit_guard
            raise Conflict if capture_stock_guard

            stock.update!(quantity: capture_write_quantity)
          end
          reservation || Reservation.create!(id: reservation_id, stock_id: stock.id, quantity: quantity)
        end
      end

      private

      def debit_stock?(reservation)
        capture_helper
      end
    end
  RUBY

  CAPTURES = %w[capture_debit_guard capture_stock_guard capture_write_quantity capture_helper].freeze
  COMPARISONS = { :< => "<", :<= => "≤", :> => ">", :>= => "≥", :== => "=", :!= => "≠" }.freeze
  CONNECTIVES = { :"&&" => "∧", :and => "∧", :"||" => "∨", :or => "∨" }.freeze
  ARITHMETIC = { :+ => "+", :- => "-" }.freeze

  module_function

  def without_positions(node)
    return node unless node.is_a?(Array)
    # Ripper token nodes have a trailing source location.
    return node.first(2) if node.first.is_a?(Symbol) && node.first.start_with?("@")

    node.map { |child| without_positions(child) }
  end

  def ast(source)
    without_positions(Ripper.sexp(source))
  end

  def atom(source)
    ast("def expression(stock, quantity, reservation)\n#{source}\nend").dig(1, 0, 3, 1, 0)
  end

  RESERVATION = atom("reservation")
  RESERVATION_NIL = atom("reservation.nil?")
  DEBIT_HELPER = atom("debit_stock?(reservation)")
  STOCK_QUANTITY = atom("stock.quantity")
  REQUESTED = atom("quantity")

  def match_shape(pattern, node, captures)
    if pattern.is_a?(Array)
      case pattern
      in [:vcall, [:@ident, name]] if CAPTURES.include?(name)
        captures[name] = node
        return true
      else
        return false unless node.is_a?(Array) && node.length == pattern.length

        return pattern.zip(node).all? { |expected, actual| match_shape(expected, actual, captures) }
      end
    end
    pattern == node
  end

  def quantity(node, arithmetic:)
    return "stock" if node == STOCK_QUANTITY
    return "requested" if node == REQUESTED

    case node
    in [:@int, "0" | "1"]
      "(#{node.last} : Int)"
    in [:paren, [inner]]
      quantity(inner, arithmetic:)
    in [:binary, left, operator, right] if arithmetic && ARITHMETIC.key?(operator)
      "(#{quantity(left, arithmetic:)} #{ARITHMETIC.fetch(operator)} #{quantity(right, arithmetic:)})"
    else
      raise Unsupported, "quantity expression outside supported integer grammar"
    end
  end

  def condition(node, helper: nil)
    return "(previous ≠ none)" if node == RESERVATION
    return "(previous = none)" if node == RESERVATION_NIL
    return helper if helper && node == DEBIT_HELPER

    case node
    in [:var_ref, [:@kw, "true"]]
      "True"
    in [:var_ref, [:@kw, "false" | "nil"]]
      "False"
    in [:paren, [inner]]
      condition(inner, helper:)
    in [:unary, (:! | :not), inner]
      "(¬ #{condition(inner, helper:)})"
    in [:binary, left, operator, right] if CONNECTIVES.key?(operator)
      "(#{condition(left, helper:)} #{CONNECTIVES.fetch(operator)} #{condition(right, helper:)})"
    in [:binary, left, operator, right] if helper && COMPARISONS.key?(operator)
      "(#{quantity(left, arithmetic: false)} #{COMPARISONS.fetch(operator)} #{quantity(right, arithmetic: false)})"
    else
      raise Unsupported, "condition outside supported side-effect-free grammar"
    end
  end

  def translate(source)
    source.force_encoding(Encoding::UTF_8)
    raise Unsupported, "expected valid UTF-8 Ruby source" unless source.valid_encoding?
    if Ripper.lex(source).any? { |_, event, _, _| event == :on___end__ }
      raise Unsupported, "Ruby data section is outside the supported file shape"
    end

    captures = {}
    tree = ast(source)
    raise Unsupported, "Ruby parse failed" unless tree
    unless match_shape(ast(SHAPE), tree, captures)
      raise Unsupported, "class, transaction, or effect sequence outside the supported file shape"
    end

    helper = condition(captures.fetch("capture_helper"))
    debit_guard = condition(captures.fetch("capture_debit_guard"), helper:)
    stock_guard = condition(captures.fetch("capture_stock_guard"), helper:)
    write_quantity = quantity(captures.fetch("capture_write_quantity"), arithmetic: true)
    <<~LEAN
      def generated (stock requested : Int) (previous : Option Int) : Attempt :=
        if previous ≠ none ∧ previous ≠ some requested then .conflict
        else if #{debit_guard} then
          if #{stock_guard} then .conflict
          else finish previous (some #{write_quantity})
        else finish previous none
    LEAN
  rescue ArgumentError => error
    raise Unsupported, "Ruby parse failed: #{error.message}"
  end

  def lean_check(path, program)
    File.write(path, program)
    stdout, stderr, status = Open3.capture3(
      "lean", "-DwarningAsError=true", File.basename(path), chdir: File.dirname(path)
    )
    diagnostics = "#{stdout}#{stderr}".scrub
    [diagnostics, status.success? && !diagnostics.include?("sorryAx")]
  end

  def verify(generated, report)
    model = File.read(File.join(__dir__, "contract.lean")) + "\n" + generated
    proof = model + <<~LEAN

      set_option linter.unusedSimpArgs false in
      theorem p1_stock_debit (stock requested : Int) (previous : Option Int) :
          generated stock requested previous = expected stock requested previous := by
        cases previous <;> simp [generated, expected, finish] <;>
          (repeat' split) <;> simp_all <;> omega

      #print axioms p1_stock_debit
      end ReserveStockSource
    LEAN
    Dir.mktmpdir("reserve-stock-lean-") do |dir|
      version, stderr, status = Open3.capture3("lean", "--version", chdir: dir)
      unless status.success? && version.match?(/\bversion 4\.36\.0(?:,|\))/)
        raise CheckError, "Lean 4.36.0 is required: #{version}#{stderr}".strip
      end
      report[:lean_version] = version.strip

      path = File.join(dir, "ReserveStock.lean")
      diagnostics, proved = lean_check(path, proof)
      if proved
        return record(report, "proved", "p1_stock_debit", proof, diagnostics, 0)
      end

      refutation = model + File.read(File.join(__dir__, "counterexample.lean"))
      counterexample, refuted = lean_check(path, refutation)
      return record(report, "property_failed", "p1_counterexample", refutation, counterexample, 1) if refuted

      warn diagnostics
      warn counterexample
      raise CheckError, "Lean produced neither a proof nor a checked counterexample"
    end
  end

  def record(report, status, theorem, program, diagnostics, code)
    output = ENV["KEISIKI_LEAN_OUTPUT"]
    File.write(output, program) if output && !output.empty?
    report.merge!(status:, theorem:, lean_sha256: Digest::SHA256.hexdigest(program), lean_output: diagnostics.strip)
    code
  end

  def check(args)
    report = { ruby_version: RUBY_VERSION }
    code = check_input(args, report)
    puts JSON.generate(report)
    code
  end

  def check_input(args, report)
    raise CheckError, "usage: bin/check-reserve-stock PATH_TO_RUBY_SOURCE" unless args.length == 1
    raise CheckError, "CRuby 4.0.9 is required" unless RUBY_ENGINE == "ruby" && RUBY_VERSION == "4.0.9"

    source = File.binread(args.first)
    report[:source_sha256] = Digest::SHA256.hexdigest(source)
    verify(translate(source), report)
  rescue Unsupported => error
    report.merge!(status: "unsupported", reason: error.message.scrub)
    2
  rescue StandardError, SystemStackError => error
    report.merge!(status: "execution_error", reason: error.message.scrub)
    2
  end
end
