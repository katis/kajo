"63-bit immediate integers. The special sends do the arithmetic inline; these methods are the fallbacks and perform:'s targets. Overflow answers a LargeInteger."
Class {
	#name : #SmallInteger,
	#superclass : #Integer,
	#category : #'Kernel-Numbers',
	#type : #normal
}

{ #category : #arithmetic }
SmallInteger >> + aNumber [
	<primitive: 40>
	^ self retry: #+ coercing: aNumber
]

{ #category : #arithmetic }
SmallInteger >> - aNumber [
	<primitive: 41>
	^ self retry: #- coercing: aNumber
]

{ #category : #arithmetic }
SmallInteger >> * aNumber [
	<primitive: 42>
	^ self retry: #* coercing: aNumber
]

{ #category : #arithmetic }
SmallInteger >> / aNumber [
	<primitive: 43>
	^ super / aNumber
]

{ #category : #arithmetic }
SmallInteger >> // aNumber [
	<primitive: 44>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ self retry: #// coercing: aNumber
]

{ #category : #arithmetic }
SmallInteger >> \\ aNumber [
	<primitive: 45>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ self retry: #\\ coercing: aNumber
]

{ #category : #arithmetic }
SmallInteger >> quo: aNumber [
	<primitive: 46>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ super quo: aNumber
]

{ #category : #arithmetic }
SmallInteger >> rem: aNumber [
	<primitive: 47>
	aNumber = 0 ifTrue: [^ ZeroDivide new dividend: self; signal: 'division by zero'].
	^ super rem: aNumber
]

{ #category : #arithmetic }
SmallInteger >> negated [
	<primitive: 58>
	^ 0 - self
]

{ #category : #comparing }
SmallInteger >> < aNumber [
	<primitive: 48>
	^ self retry: #< coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> > aNumber [
	<primitive: 49>
	^ self retry: #> coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> <= aNumber [
	<primitive: 50>
	^ self retry: #<= coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> >= aNumber [
	<primitive: 51>
	^ self retry: #>= coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> = aNumber [
	<primitive: 52>
	^ self retry: #= coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> ~= aNumber [
	<primitive: 53>
	^ self retry: #~= coercing: aNumber
]

{ #category : #comparing }
SmallInteger >> hash [
	^ self
]

{ #category : #comparing }
SmallInteger >> identityHash [
	^ self
]

{ #category : #bits }
SmallInteger >> bitAnd: n [
	<primitive: 54>
	^ self primitiveFailed
]

{ #category : #bits }
SmallInteger >> bitOr: n [
	<primitive: 55>
	^ self primitiveFailed
]

{ #category : #bits }
SmallInteger >> bitXor: n [
	<primitive: 56>
	^ self primitiveFailed
]

{ #category : #bits }
SmallInteger >> bitShift: n [
	<primitive: 57>
	^ self primitiveFailed
]

{ #category : #coercion }
SmallInteger >> generality [
	^ 10
]

{ #category : #coercion }
SmallInteger >> coerce: aNumber [
	^ aNumber truncated
]

{ #category : #coercion }
SmallInteger >> asFloat [
	<primitive: 59>
	^ self primitiveFailed
]
