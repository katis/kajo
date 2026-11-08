Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"collections, part oc alone (the collections-speed module, part 1): the part of programs/collections three times, as there."
	| sum |
	sum := 0.
	3 timesRepeat: [sum := sum + self orderedCollectionPart].
	^ sum
]

{ #category : #'*Bench' }
UndefinedObject >> orderedCollectionPart [
	| oc sum |
	oc := OrderedCollection new.
	1 to: 1000000 do: [:i | oc add: i].
	sum := 0.
	oc do: [:x | sum := sum + x].
	^ sum + (oc inject: 0 into: [:acc :x | acc + x])
]
