Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"collections, part dict alone (the collections-speed module, part 1): the part of programs/collections three times, as there."
	| sum |
	sum := 0.
	3 timesRepeat: [sum := sum + self dictionaryPart].
	^ sum
]

{ #category : #'*Bench' }
UndefinedObject >> dictionaryPart [
	| keys dict sum |
	keys := Array new: 200000.
	1 to: 200000 do: [:i | keys at: i put: ('k', i printString) asSymbol].
	dict := Dictionary new.
	1 to: 200000 do: [:i | dict at: (keys at: i) put: i].
	sum := 0.
	keys do: [:k | sum := sum + (dict at: k)].
	^ sum + dict size
]
