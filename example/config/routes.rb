Rails.application.routes.draw do
  post "/stock/reservations", to: "reservations#create"
end
