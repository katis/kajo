"A non-negative integer beyond the SmallInteger range: its magnitude in bytes, little-endian. The primitives take any mix with SmallIntegers."
Class {
	#name : #LargePositiveInteger,
	#superclass : #Integer,
	#category : #'Kernel-Numbers',
	#type : #bytes
}

{ #category : #arithmetic }
LargePositiveInteger >> * aNumber [
	<primitive: 42>
	^ self retry: #* coercing: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> + aNumber [
	<primitive: 40>
	^ self retry: #+ coercing: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> - aNumber [
	<primitive: 41>
	^ self retry: #- coercing: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> / aNumber [
	<primitive: 43>
	^ super / aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> // aNumber [
	<primitive: 44>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ self retry: #// coercing: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> \\ aNumber [
	<primitive: 45>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ self retry: #\\ coercing: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> negated [
	<primitive: 58>
	^ 0 - self
]

{ #category : #arithmetic }
LargePositiveInteger >> quo: aNumber [
	<primitive: 46>
	^ super quo: aNumber
]

{ #category : #arithmetic }
LargePositiveInteger >> rem: aNumber [
	<primitive: 47>
	^ super rem: aNumber
]

{ #category : #bits }
LargePositiveInteger >> bitAnd: n [
	<primitive: 54>
	^ self primitiveFailed
]

{ #category : #bits }
LargePositiveInteger >> bitOr: n [
	<primitive: 55>
	^ self primitiveFailed
]

{ #category : #bits }
LargePositiveInteger >> bitShift: n [
	<primitive: 57>
	^ self primitiveFailed
]

{ #category : #bits }
LargePositiveInteger >> bitXor: n [
	<primitive: 56>
	^ self primitiveFailed
]

{ #category : #coercion }
LargePositiveInteger >> asFloat [
	<primitive: 59>
	^ self primitiveFailed
]

{ #category : #coercion }
LargePositiveInteger >> byteSize [
	<primitive: 133>
	^ 0
]

{ #category : #coercion }
LargePositiveInteger >> coerce: aNumber [
	^ aNumber truncated
]

{ #category : #coercion }
LargePositiveInteger >> generality [
	^ 20
]

{ #category : #coercion }
LargePositiveInteger >> negative [
	^ false
]

{ #category : #comparing }
LargePositiveInteger >> < aNumber [
	<primitive: 48>
	^ self retry: #< coercing: aNumber
]

{ #category : #comparing }
LargePositiveInteger >> <= aNumber [
	<primitive: 50>
	^ self retry: #<= coercing: aNumber
]

{ #category : #comparing }
LargePositiveInteger >> = aNumber [
	<primitive: 52>
	^ self retry: #= coercing: aNumber
]

{ #category : #comparing }
LargePositiveInteger >> > aNumber [
	<primitive: 49>
	^ self retry: #> coercing: aNumber
]

{ #category : #comparing }
LargePositiveInteger >> >= aNumber [
	<primitive: 51>
	^ self retry: #>= coercing: aNumber
]

{ #category : #comparing }
LargePositiveInteger >> hash [
	^ (self bitAnd: 16r3FFFFFFF) bitXor: (self bitShift: -30) hash
]

{ #category : #comparing }
LargePositiveInteger >> ~= aNumber [
	<primitive: 53>
	^ self retry: #~= coercing: aNumber
]
