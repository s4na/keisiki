---- MODULE QuoteCases ----
EXTENDS Integers, Json

VARIABLE ready

Quote(requested, available, volumeOffer, coupon) ==
  LET fulfilled == IF requested <= available THEN requested ELSE available
      volumeDiscount == IF volumeOffer /\ fulfilled >= 3 THEN 20 ELSE 0
      couponDiscount == IF coupon /\ fulfilled > 0 THEN 20 ELSE 0
      discounted == 40 * fulfilled - volumeDiscount - couponDiscount
      merchandise == IF discounted >= 0 THEN discounted ELSE 0
      shipping == IF fulfilled = 0 \/ merchandise >= 100 THEN 0 ELSE 12
  IN [fulfilled |-> fulfilled, merchandise |-> merchandise,
      shipping |-> shipping, total |-> merchandise + shipping]

Row(requested, available, volumeOffer, coupon) ==
  [input |-> [requested |-> requested, available |-> available,
              volume_offer |-> volumeOffer, coupon |-> coupon],
   expected |-> Quote(requested, available, volumeOffer, coupon)]

Cases ==
  [i \in 1..100 |->
    LET pair == (i - 1) \div 4
        flags == (i - 1) % 4
    IN Row(pair \div 5, pair % 5, flags \div 2 = 1, flags % 2 = 1)]

Init == ready = TRUE /\ JsonSerialize("cases.json", Cases)
Next == UNCHANGED ready
====
