"closures in Smalltalk (module 8b): closures.kasm in kernel style. A real (not inlined) from:to:do: loop calling a closure over a temp vector, then a detect that returns non-locally from two frames up."
Extension { #name : #UndefinedObject }

{ #category : #bench }
UndefinedObject >> from: a to: b do: aBlock [
	| i |
	i := a.
	[i <= b] whileTrue: [
		aBlock value: i.
		i := i + 1]
]

{ #category : #bench }
UndefinedObject >> sumMods [
	| sum |
	sum := 0.
	nil from: 1 to: 1000 do: [:i | sum := sum + (i \\ 7)].
	^ sum
]

{ #category : #bench }
UndefinedObject >> detect: target [
	nil from: 1 to: 1000 do: [:i | i = target ifTrue: [^ i]].
	^ 0
]

{ #category : #bench }
UndefinedObject >> run: w of: n [
	| reps sum |
	reps := 60000 // n.
	sum := 0.
	[reps > 0] whileTrue: [
		sum := sum + nil sumMods + (nil detect: reps \\ 1000 + 1).
		reps := reps - 1].
	^ sum
]
