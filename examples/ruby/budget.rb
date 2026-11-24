module Budget
  def self.remaining(available, requested)
    self.difference(available, BudgetRules.approved(available, requested))
  end

  def self.difference(available, approved)
    available - approved
  end
end
