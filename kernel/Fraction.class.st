"An exact quotient of two integers, kept normalized: the denominator positive, no common factor, never 1 (that is an Integer). Integer / answers one when the division is not exact."
Class {
	#name : #Fraction,
	#superclass : #Number,
	#instVars : [
		'numerator',
		'denominator'
	],
	#category : #'Kernel-Numbers'
}

{ #category : #accessing }
Fraction class >> numerator: n denominator: d [
	^ self basicNew setNumerator: n denominator: d
]

{ #category : #accessing }
Fraction >> setNumerator: n denominator: d [
	numerator := n.
	denominator := d
]

{ #category : #accessing }
Fraction >> normalized [
	| g n d |
	denominator = 0 ifTrue: [^ ZeroDivide new dividend: numerator; signal: 'division by zero'].
	g := numerator gcd: denominator.
	n := numerator // g. d := denominator // g.
	d < 0 ifTrue: [n := n negated. d := d negated].
	d = 1 ifTrue: [^ n].
	^ Fraction numerator: n denominator: d
]

{ #category : #accessing }
Fraction >> numerator [
	^ numerator
]

{ #category : #accessing }
Fraction >> denominator [
	^ denominator
]

{ #category : #accessing }
Fraction >> isFraction [
	^ true
]

{ #category : #accessing }
Fraction >> + aNumber [
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #+ coercing: aNumber].
	^ (Fraction numerator: numerator * aNumber denominator + (aNumber numerator * denominator)
		denominator: denominator * aNumber denominator) normalized
]

{ #category : #accessing }
Fraction >> - aNumber [
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #- coercing: aNumber].
	^ (Fraction numerator: numerator * aNumber denominator - (aNumber numerator * denominator)
		denominator: denominator * aNumber denominator) normalized
]

{ #category : #accessing }
Fraction >> * aNumber [
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #* coercing: aNumber].
	^ (Fraction numerator: numerator * aNumber numerator denominator: denominator * aNumber denominator) normalized
]

{ #category : #accessing }
Fraction >> / aNumber [
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #/ coercing: aNumber].
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ (Fraction numerator: numerator * aNumber denominator denominator: denominator * aNumber numerator) normalized
]

{ #category : #accessing }
Fraction >> < aNumber [
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #< coercing: aNumber].
	^ numerator * aNumber denominator < (aNumber numerator * denominator)
]

{ #category : #accessing }
Fraction >> = aNumber [
	aNumber isNumber ifFalse: [^ false].
	aNumber isFraction | aNumber isInteger ifFalse: [^ self retry: #= coercing: aNumber].
	^ numerator = aNumber numerator and: [denominator = aNumber denominator]
]

{ #category : #accessing }
Fraction >> hash [
	^ numerator hash bitXor: denominator hash
]

{ #category : #accessing }
Fraction >> negated [
	^ Fraction numerator: numerator negated denominator: denominator
]

{ #category : #accessing }
Fraction >> reciprocal [
	^ (Fraction numerator: denominator denominator: numerator) normalized
]

{ #category : #accessing }
Fraction >> truncated [
	^ numerator quo: denominator
]

{ #category : #accessing }
Fraction >> negative [
	^ numerator < 0
]

{ #category : #accessing }
Fraction >> asFloat [
	^ numerator asFloat / denominator asFloat
]

{ #category : #accessing }
Fraction >> generality [
	^ 30
]

{ #category : #accessing }
Fraction >> coerce: aNumber [
	^ aNumber asFraction
]

{ #category : #accessing }
Fraction >> asFraction [
	^ self
]

{ #category : #accessing }
Fraction >> printOn: aStream [
	aStream print: numerator; nextPut: $/; print: denominator
]

{ #category : #accessing }
Fraction >> printString [
	^ numerator printString , '/' , denominator printString
]
