Extension { #name : #UndefinedObject }

{ #category : #bench }
UndefinedObject >> run: w of: n [
	| cells reps k sum |
	cells := Array new: 4.
	1 to: 4 do: [:i | cells at: i put: (Cell basicNew init: i + w)].
	reps := 32000 // n.
	k := 1.
	[reps > 0] whileTrue: [
		(cells at: k) spin: 1000.
		(k := k + 1) > 4 ifTrue: [k := 1].
		reps := reps - 1].
	sum := 0.
	1 to: 4 do: [:i | sum := sum + (cells at: i) sum].
	^ sum
]
