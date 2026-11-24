module BudgetRules
  def self.approved(available, requested)
    if requested > available
      0
    else
      requested
    end
  end
end
