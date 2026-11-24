---- MODULE StockCases ----
EXTENDS Integers, Sequences, Json

VARIABLE ready

Row(band, s, q) ==
  [band |-> band, stock |-> s, quantity |-> q,
   expectedBand |-> IF q > s THEN band ELSE "small",
   expectedOffset |-> IF q > s THEN s ELSE s - q]

Grid(band, width) ==
  [i \in 1..(width * width) |->
    Row(band, (i - 1) \div width, (i - 1) % width)]

Init == ready = TRUE /\ JsonSerialize("cases.json", Grid("small", 5) \o Grid("large", 3))
Next == UNCHANGED ready
====
