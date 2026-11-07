Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"collections: the Smalltalk library against Pharo's, REPS times: an OrderedCollection of a million SmallIntegers filled and summed with do: and inject:into:; a Dictionary of 200 000 Symbol keys built and looked up; a String of a million characters built with a WriteStream and scanned; 500 000 SmallIntegers sorted. The answer mixes every part's result."
	| sum |
	sum := 0.
	3 timesRepeat: [
		sum := sum + self orderedCollectionPart + self dictionaryPart + self streamPart + self sortPart].
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

{ #category : #'*Bench' }
UndefinedObject >> streamPart [
	| stream string count chars |
	stream := WriteStream on: String new.
	1 to: 1000000 do: [:i | stream nextPut: (Character value: 97 + (i \\ 26))].
	string := stream contents.
	count := 0.
	chars := 0.
	string do: [:c |
		chars := chars + 1.
		c = $e ifTrue: [count := count + 1]].
	^ chars + count
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
