Extension { #name : #UndefinedObject }

{ #category : #bench }
UndefinedObject >> run: w of: n [
	| arr reps sum k |
	arr := Array new: 3.
	arr at: 1 put: Leaf basicNew; at: 2 put: Doubler basicNew; at: 3 put: Subber basicNew.
	reps := 40000000 // n.
	sum := 0.
	k := w \\ 3 + 1.
	[reps > 0] whileTrue: [
		sum := sum + ((arr at: k) step: reps).
		(k := k + 1) > 3 ifTrue: [k := 1].
		reps := reps - 1].
	^ sum
]
