require "digest"
require "pg_query"

module PostgresUpdateToLean
  class Unsupported < StandardError; end

  IDENTIFIER = /\A[a-z_][a-z0-9_]{0,62}\z/
  GUARD_COMBINATIONS = [true, false].repeated_permutation(2).map(&:freeze).freeze

  def self.generate(sql)
    parsed = tree(sql)
    update = parsed.dig(0, :update_stmt)
    table = update&.dig(:relation, :relname)
    quantity = update&.dig(:target_list, 0, :res_target, :name)
    raise Unsupported, "expected named table and quantity column" unless identifier?(table) && identifier?(quantity)
    raise Unsupported, "the target key must stay unchanged" if quantity == "id"

    guards = GUARD_COMBINATIONS.find do |stock_guard, positive_guard|
      parsed == tree(grammar(table, quantity, stock_guard, positive_guard))
    end
    raise Unsupported, "expected one UPDATE ONLY with a bigint subtraction, id = 1 and one RETURNING column" unless guards

    stock_guard, positive_guard = guards
    <<~LEAN
      import Keisiki

      namespace GeneratedSQL

      def sha256 : String := "#{Digest::SHA256.hexdigest(sql)}"
      def table : String := "#{table}"
      def quantityColumn : String := "#{quantity}"
      def update : Keisiki.Postgres.Update := ⟨#{stock_guard}, #{positive_guard}⟩

      end GeneratedSQL
    LEAN
  rescue PgQuery::ParseError => error
    raise Unsupported, error.message
  end

  def self.tree(sql)
    PgQuery.parse(sql).tree.stmts.map { |statement| without_locations(statement.stmt.to_h) }
  end

  def self.without_locations(value)
    case value
    when Hash
      value.reject { |key, _| key == :location }.transform_values { |item| without_locations(item) }
    when Array
      value.map { |item| without_locations(item) }
    else
      value
    end
  end

  def self.grammar(table, quantity, stock_guard, positive_guard)
    predicates = ["id = 1"]
    predicates << "#{quantity} >= $1::bigint" if stock_guard
    predicates << "$1::bigint > 0" if positive_guard
    "UPDATE ONLY #{table} SET #{quantity} = #{quantity} - $1::bigint WHERE #{predicates.join(" AND ")} RETURNING #{quantity}"
  end

  def self.identifier?(name)
    name.is_a?(String) && IDENTIFIER.match?(name)
  end

  private_class_method :tree, :without_locations, :grammar, :identifier?
end
