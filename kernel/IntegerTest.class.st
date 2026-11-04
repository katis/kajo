"SmallInteger arithmetic, division semantics, printing, overflow into LargeIntegers."
Class {
	#name : #IntegerTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
IntegerTest >> testArithmetic [
	self assert: 3 + 4 = 7.
	self assert: 3 - 4 = -1.
	self assert: 6 * 7 = 42.
	self assert: 7 // 2 = 3.
	self assert: -7 // 2 = -4.
	self assert: 7 \\ 2 = 1.
	self assert: -7 \\ 2 = 1.
	self assert: (-7 quo: 2) = -3.
	self assert: (-7 rem: 2) = -1.
	self assert: 6 / 3 = 2.
	self assert: 3 negated = -3.
	self assert: -3 abs = 3
]

{ #category : #accessing }
IntegerTest >> testBits [
	self assert: (12 bitAnd: 10) = 8.
	self assert: (12 bitOr: 3) = 15.
	self assert: (12 bitXor: 10) = 6.
	self assert: (1 bitShift: 10) = 1024.
	self assert: (1024 bitShift: -3) = 128.
	self assert: 1 << 4 = 16
]

{ #category : #accessing }
IntegerTest >> testComparing [
	self assert: 3 < 4.
	self assert: 4 > 3.
	self assert: 3 <= 3.
	self assert: 3 >= 3.
	self assert: (3 max: 9) = 9.
	self assert: (3 min: 9) = 3.
	self assert: (5 between: 1 and: 5)
]

{ #category : #accessing }
IntegerTest >> testDivisionByZero [
	self should: [1 // 0] raise: ZeroDivide.
	self should: [1 / 0] raise: ZeroDivide.
	self should: [1 \\ 0] raise: ZeroDivide.
	self assert: ([1 / 0] on: ZeroDivide do: [:e | e dividend]) = 1
]

{ #category : #accessing }
IntegerTest >> testFunctions [
	self assert: (12 gcd: 18) = 6.
	self assert: (4 lcm: 6) = 12.
	self assert: 5 factorial = 120.
	self assert: 7 isPrime.
	self deny: 9 isPrime.
	self assert: 17 sqrtFloor = 4.
	self assert: (2 raisedTo: 10) = 1024.
	self assert: 4 even.
	self assert: 3 odd.
	self assert: 0 isZero.
	self assert: -3 sign = -1
]

{ #category : #accessing }
IntegerTest >> testHash [
	self assert: 3 hash = 3.
	self assert: (2 raisedTo: 80) hash = (2 raisedTo: 80) hash
]

{ #category : #accessing }
IntegerTest >> testLoops [
	| sum |
	sum := 0.
	1 to: 10 do: [:i | sum := sum + i].
	self assert: sum = 55.
	sum := 0.
	10 to: 1 by: -3 do: [:i | sum := sum + i].
	self assert: sum = (10 + 7 + 4 + 1).
	sum := 0.
	4 timesRepeat: [sum := sum + 2].
	self assert: sum = 8.
	sum := 0.
	(1 to: 5) do: [:i | sum := sum + i].
	self assert: sum = 15
]

{ #category : #accessing }
IntegerTest >> testOverflowIntoLargeIntegers [
	| big |
	big := 4611686018427387903 + 1.
	self assert: big class == LargePositiveInteger.
	self assert: big - 1 = 4611686018427387903.
	self assert: (big - 1) class == SmallInteger.
	self assert: (-4611686018427387904 - 1) class == LargeNegativeInteger.
	self assert: 30 factorial printString = '265252859812191058636308480000000'.
	self assert: (30 factorial / 29 factorial) = 30.
	self assert: (2 raisedTo: 100) printString = '1267650600228229401496703205376'.
	self assert: ((2 raisedTo: 100) bitAnd: (2 raisedTo: 100) - 1) = 0.
	self assert: (2 raisedTo: 64) negated < 0.
	self assert: ((2 raisedTo: 64) // 3) * 3 + ((2 raisedTo: 64) \\ 3) = (2 raisedTo: 64)
]

{ #category : #accessing }
IntegerTest >> testParsing [
	self assert: '123' asInteger = 123.
	self assert: '-42' asInteger = -42.
	self assert: 'abc' asInteger isNil.
	self assert: '12abc' asInteger = 12
]

{ #category : #accessing }
IntegerTest >> testPrinting [
	self assert: 0 printString = '0'.
	self assert: 123 printString = '123'.
	self assert: -45 printString = '-45'.
	self assert: (255 printString: 16) = 'FF'.
	self assert: (5 printString: 2) = '101'.
	self assert: (7 printPaddedWith: $0 to: 3) = '007'
]
