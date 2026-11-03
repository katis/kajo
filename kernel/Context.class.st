"A frame made into an object on demand (ADR 0009 section 3): live while its frame runs, detached (a copy of its temps) once it returns. Sealed; read through primitives."
Class {
	#name : #Context,
	#superclass : #Object,
	#instVars : [
		'frame',
		'process',
		'method',
		'receiver',
		'closure',
		'pc',
		'marker'
	],
	#category : #'Kernel-Methods',
	#type : #variable
}

{ #category : #accessing }
Context >> sender [
	<primitive: 100>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> tempAt: index [
	<primitive: 101>
	^ self indexError: index
]

{ #category : #accessing }
Context >> tempAt: index put: anObject [
	<primitive: 102>
	^ self indexError: index
]

{ #category : #accessing }
Context >> pc [
	<primitive: 103>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> method [
	<primitive: 104>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> receiver [
	<primitive: 105>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> closure [
	<primitive: 106>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> isDead [
	<primitive: 107>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> terminateTo: aContext [
	<primitive: 108>
	^ self error: 'cannot cut the stack to ' , aContext printString
]

{ #category : #accessing }
Context >> findNextUnwindContextUpTo: aContext [
	<primitive: 109>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> findNextHandlerContextStarting [
	<primitive: 110>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> size [
	<primitive: 111>
	^ 0
]

{ #category : #accessing }
Context >> isContext [
	^ true
]

{ #category : #accessing }
Context >> resume: value through: firstUnwindContext [
	"Unwind thisContext to the receiver, running each pending unwind block from firstUnwindContext on, then answer value as the receiver's last send's result."
	| ctx unwindBlock |
	ctx := firstUnwindContext.
	[ctx isNil] whileFalse: [
		(ctx tempAt: 2) isNil ifTrue: [
			ctx tempAt: 2 put: true.
			unwindBlock := ctx tempAt: 1.
			thisContext terminateTo: ctx.
			unwindBlock value].
		ctx := ctx findNextUnwindContextUpTo: self].
	thisContext terminateTo: self.
	^ value
]

{ #category : #accessing }
Context >> return: value [
	"Return value from the receiver's frame to its sender, unwinding."
	^ self sender resume: value through: (thisContext findNextUnwindContextUpTo: self)
]

{ #category : #accessing }
Context >> aboutToReturn: value through: firstUnwindContext [
	"The VM sends this to the home Context of a non-local return that crosses an unwind mark."
	^ self sender resume: value through: firstUnwindContext
]

{ #category : #accessing }
Context >> stack [
	| out ctx |
	out := OrderedCollection new.
	ctx := self.
	[ctx notNil] whileTrue: [out add: ctx. ctx := ctx sender].
	^ out
]

{ #category : #accessing }
Context >> printOn: aStream [
	aStream print: self method
]
