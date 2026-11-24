namespace Keisiki

inductive Fault where
  | missingArgument
  | unknownMethod
  | wrongArity
  | callBudget
  deriving Repr, DecidableEq

abbrev Outcome := Except Fault Int
abbrev Dispatch := String → List Int → Outcome

structure Method (Term : Type) where
  name : String
  arity : Nat
  body : Term

abbrev Program (Term : Type) := List (Method Term)

def lookup (name : String) : Program Term → Option (Method Term)
  | [] => none
  | method :: rest => if method.name == name then some method else lookup name rest

def execute (eval : Dispatch → List Int → Term → Outcome) (program : Program Term) :
    Nat → Dispatch
  | 0, _, _ => .error .callBudget
  | budget + 1, name, arguments =>
    match lookup name program with
    | none => .error .unknownMethod
    | some method =>
      if arguments.length == method.arity then
        eval (execute eval program budget) arguments method.body
      else
        .error .wrongArity

namespace Source

mutual
  inductive Expr where
    | literal : Int → Expr
    | parameter : Nat → Expr
    | add : Expr → Expr → Expr
    | subtract : Expr → Expr → Expr
    | ifGreater : Expr → Expr → Expr → Expr → Expr
    | call : String → Arguments → Expr
  inductive Arguments where
    | none
    | next : Expr → Arguments → Arguments
end

mutual
  def eval (dispatch : Dispatch) (locals : List Int) : Expr → Outcome
    | .literal value => .ok value
    | .parameter index =>
      match locals[index]? with
      | some value => .ok value
      | none => .error .missingArgument
    | .add lhs rhs => do
      let left ← eval dispatch locals lhs
      let right ← eval dispatch locals rhs
      pure (left + right)
    | .subtract lhs rhs => do
      let left ← eval dispatch locals lhs
      let right ← eval dispatch locals rhs
      pure (left - right)
    | .ifGreater lhs rhs yes no => do
      let left ← eval dispatch locals lhs
      let right ← eval dispatch locals rhs
      if left > right then eval dispatch locals yes else eval dispatch locals no
    | .call name arguments => do
      let values ← evalArguments dispatch locals arguments
      dispatch name values

  def evalArguments (dispatch : Dispatch) (locals : List Int) :
      Arguments → Except Fault (List Int)
    | .none => .ok []
    | .next first rest => do
      let value ← eval dispatch locals first
      let values ← evalArguments dispatch locals rest
      pure (value :: values)
end

def invoke (program : Program Expr) : Dispatch :=
  execute eval program program.length

end Source

namespace IR

inductive IntOp where
  | add
  | subtract

def IntOp.apply : IntOp → Int → Int → Int
  | .add => (· + ·)
  | .subtract => (· - ·)

mutual
  inductive Expr where
    | constant : Int → Expr
    | load : Nat → Expr
    | binary : IntOp → Expr → Expr → Expr
    | branchLe : Expr → Expr → Expr → Expr → Expr
    | invoke : String → Arguments → Expr
  inductive Arguments where
    | empty
    | push : Expr → Arguments → Arguments
end

mutual
  def eval (dispatch : Dispatch) (locals : List Int) : Expr → Outcome
    | .constant value => .ok value
    | .load index =>
      match locals[index]? with
      | some value => .ok value
      | none => .error .missingArgument
    | .binary op lhs rhs => do
      let left ← eval dispatch locals lhs
      let right ← eval dispatch locals rhs
      pure (op.apply left right)
    | .branchLe lhs rhs yes no => do
      let left ← eval dispatch locals lhs
      let right ← eval dispatch locals rhs
      if left ≤ right then eval dispatch locals yes else eval dispatch locals no
    | .invoke name arguments => do
      let values ← evalArguments dispatch locals arguments
      dispatch name values

  def evalArguments (dispatch : Dispatch) (locals : List Int) :
      Arguments → Except Fault (List Int)
    | .empty => .ok []
    | .push first rest => do
      let value ← eval dispatch locals first
      let values ← evalArguments dispatch locals rest
      pure (value :: values)
end

def invoke (program : Program Expr) : Dispatch :=
  execute eval program program.length

end IR
end Keisiki
