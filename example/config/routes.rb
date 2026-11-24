Rails.application.routes.draw do
  get "/stock/remaining", to: "stock#remaining"
end
