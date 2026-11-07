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
Context >> aboutToReturn: value through: firstUnwindContext [
	"The VM sends this to the home Context of a non-local return that crosses an unwind mark."
	^ self sender resume: value through: firstUnwindContext
]

{ #category : #accessing }
Context >> closure [
	<primitive: 106>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> findNextHandlerContextStarting [
	<primitive: 110>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> findNextUnwindContextUpTo: aContext [
	<primitive: 109>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> isContext [
	^ true
]

{ #category : #accessing }
Context >> isDead [
	<primitive: 107>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> method [
	<primitive: 104>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> pc [
	<primitive: 103>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> printOn: aStream [
	aStream print: self method
]

{ #category : #accessing }
Context >> receiver [
	<primitive: 105>
	^ self primitiveFailed
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
Context >> sender [
	<primitive: 100>
	^ self primitiveFailed
]

{ #category : #accessing }
Context >> size [
	<primitive: 111>
	^ 0
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
Context >> terminateTo: aContext [
	<primitive: 108>
	^ self error: 'cannot cut the stack to ' , aContext printString
]

{ #category : #debugging }
Context >> primResend: anArray [
	"Primitive 156: the receiver, the caller of the running frame, runs again from the send its pc is after, with anArray (the send's receiver, then its arguments) as the operands; the running frame goes."
	<primitive: 156>
	^ self error: 'cannot re-execute the send of ' , self printString
]

{ #category : #debugging }
Context >> restartSendWith: anArray [
	"Unwind to the receiver, running every pending ensure: and ifCurtailed: block above it, then run the send the receiver's pc is after again with anArray (its receiver, then its arguments): a frame restart re-enters the current version of the method, a send retried after doesNotUnderstand: is looked up again (module 9b). Never returns here."
	^ self restartSendWith: anArray afterUnwinding: nil
]

{ #category : #debugging }
Context >> restartSendWith: anArray afterUnwinding: aBlockOrNil [
	"restartSendWith:, and aBlockOrNil runs once the blocks above have run, before the send (the debugger's restart and retry answer then: the development answers). Each unwind block is noted (Unwinding note:for:) so a Process waiting for this one can say where it stands."
	| ctx unwindBlock me |
	me := ProcessorScheduler activeProcess.
	ctx := thisContext findNextUnwindContextUpTo: self.
	[ctx isNil] whileFalse: [
		(ctx tempAt: 2) isNil ifTrue: [
			ctx tempAt: 2 put: true.
			unwindBlock := ctx tempAt: 1.
			thisContext terminateTo: ctx.
			Unwinding note: unwindBlock for: me.
			unwindBlock value].
		ctx := ctx findNextUnwindContextUpTo: self].
	Unwinding forget: me.
	thisContext terminateTo: self.
	aBlockOrNil isNil ifFalse: [aBlockOrNil value].
	^ self primResend: anArray
]

{ #category : #debugging }
Context >> sendBeforePc [
	"{selector. argc} of the send the receiver's pc is just after, or nil."
	<primitive: 157>
	^ nil
]
