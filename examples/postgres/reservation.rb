class Reservation
  def initialize(connection, sql: File.binread(File.join(__dir__, "reserve.sql")))
    @connection = connection
    @sql = sql.dup.freeze
  end

  def reserve(quantity)
    @connection.exec_params(@sql, [quantity]) do |result|
      return nil if result.ntuples.zero?
      raise "Reservation updated more than one row" unless result.ntuples == 1

      Integer(result.getvalue(0, 0), 10)
    end
  end
end
