Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"binarytrees: one long-lived tree of depth 12 kept across every collection, then REPS trees of depth 16 built, checked and dropped, split between n workers."
	| longLived reps sum |
	longLived := Node basicNew build: 12.
	reps := 1280 // n.
	sum := 0.
	[reps > 0] whileTrue: [
		sum := sum + (Node basicNew build: 16) check.
		reps := reps - 1].
	^ sum + longLived check
]
