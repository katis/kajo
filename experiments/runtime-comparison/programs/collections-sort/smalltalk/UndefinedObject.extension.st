Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"collections, part sort alone (the collections-speed module, part 1): the part of programs/collections three times, as there."
	| sum |
	sum := 0.
	3 timesRepeat: [sum := sum + self sortPart].
	^ sum
]

{ #category : #'*Bench' }
UndefinedObject >> sortPart [
	| array seed sum |
	array := Array new: 500000.
	seed := 42.
	1 to: 500000 do: [:i |
		seed := seed * 16807 \\ 2147483647.
		array at: i put: seed].
	array sort.
	sum := 0.
	1 to: 500000 by: 997 do: [:i | sum := sum + (array at: i)].
	2 to: 500000 do: [:i | (array at: i - 1) > (array at: i) ifTrue: [sum := sum + 1000000000000]].
	^ sum
]
