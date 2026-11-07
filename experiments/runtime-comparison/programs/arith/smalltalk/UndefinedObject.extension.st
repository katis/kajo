Extension { #name : #UndefinedObject }

{ #category : #'*Bench' }
UndefinedObject >> run: w of: n [
	"arith: the sum of (i * 3 + 7) modulo 1000000007 over this worker's slice of TOTAL iterations; the modulo is a conditional subtract."
	| chunk i end sum |
	chunk := 320000000 // n.
	i := w * chunk.
	end := i + chunk.
	sum := 0.
	[i < end] whileTrue: [
		sum := sum + (i * 3 + 7).
		sum >= 1000000007 ifTrue: [sum := sum - 1000000007].
		i := i + 1].
	^ sum
]
