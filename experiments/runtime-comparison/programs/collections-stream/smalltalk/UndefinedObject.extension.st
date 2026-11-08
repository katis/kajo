Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"collections, part stream alone (the collections-speed module, part 1): the part of programs/collections three times, as there."
	| sum |
	sum := 0.
	3 timesRepeat: [sum := sum + self streamPart].
	^ sum
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
