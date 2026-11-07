Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"fib: REPS repetitions of fib of (27 + (r \\ 2)), split between n workers."
	| reps sum |
	reps := 960 // n.
	sum := 0.
	[reps > 0] whileTrue: [
		sum := sum + (27 + (reps \\ 2)) fib.
		reps := reps - 1].
	^ sum
]
