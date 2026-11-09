"The debugger's model against a fake target (module 9c): process.stopped fetches the frames, a frame's source, range and variables, the commands sent with the selected frame, fix and continue (compile, then restart), and define-and-retry at a doesNotUnderstand: stop."
Class {
	#name : #DebuggerModelTest,
	#superclass : #TestCase
}

{ #category : #helpers }
DebuggerModelTest >> frame: anIndex method: aMethod receiverClass: aClass [
	| f r v |
	f := JsonObject new.
	r := JsonObject new.
	r at: 'value' put: 'a ' , aClass; at: 'class' put: aClass.
	v := JsonObject new.
	v at: 'name' put: 'x'; at: 'value' put: '3'.
	f at: 'index' put: anIndex; at: 'method' put: aMethod; at: 'pc' put: 5; at: 'range' put: #(8 12);
		at: 'receiver' put: r; at: 'variables' put: {v}; at: 'source' put: 'foo: x
	^ x bar'.
	^ f
]

{ #category : #helpers }
DebuggerModelTest >> stopEvent: anError [
	| e |
	e := JsonObject new.
	e at: 'kind' put: 'process.stopped'; at: 'process' put: 42; at: 'reason' put: 'error'; at: 'error' put: anError.
	^ e
]

{ #category : #tests }
DebuggerModelTest >> testAStopShowsItsFramesAndTheCommandsGoOut [
	| c m |
	c := FakeDevClient on: [:kind :args |
		kind = 'process.frames'
			ifTrue: [{self frame: 1 method: 'Object>>doesNotUnderstand:' receiverClass: 'Foo'. self frame: 2 method: 'Foo>>foo:' receiverClass: 'Foo'}]
			ifFalse: [(JsonObject new) at: 'value' put: '4'; at: 'class' put: 'SmallInteger'; yourself]].
	m := DebuggerModel new client: c; yourself.
	m stopped: (self stopEvent: 'ZeroDivide: division by zero').
	self assert: m state equals: #stopped.
	self assert: m frameTitles equals: #('Object>>doesNotUnderstand:' 'Foo>>foo:').
	self assert: m range equals: #(8 12).
	self assert: m variables equals: {{'self'. 'a Foo'}. {'x'. '3'}}.
	m selectFrame: 2.
	self assert: m methodClassAndSide equals: #('Foo' 'instance' 'foo:').
	m step: 'over'.
	self assert: (c sent last last at: 'frame') equals: 2.
	self assert: (c sent last last at: 'mode') equals: 'over'.
	self assert: m state equals: #running.
	m workspace doIt: 'x + 1'.
	self assert: c sent last first equals: 'process.evaluate'.
	self assert: (c sent last last at: 'frame') equals: 2.
	m proceed.
	self assert: c sent last first equals: 'process.proceed'
]

{ #category : #tests }
DebuggerModelTest >> testDefineTheMissingMethodRetriesTheSend [
	| c m defined |
	c := FakeDevClient on: [:kind :args |
		kind = 'process.frames' ifTrue: [{self frame: 1 method: 'Object>>doesNotUnderstand:' receiverClass: 'Foo'}] ifFalse: [true]].
	m := DebuggerModel new client: c; yourself.
	m browseAction: [:cls :sel :then | defined := {cls. sel}. then value: sel].
	m stopped: (self stopEvent: 'MessageNotUnderstood: a Foo does not understand #frob:').
	self assert: m isDoesNotUnderstand.
	m defineMissingMethod.
	self assert: defined equals: #('Foo' 'frob:').
	self assert: c sentKinds last equals: 'process.retrySend'
]

{ #category : #tests }
DebuggerModelTest >> testFixAndContinueCompilesThenRestarts [
	| c m |
	c := FakeDevClient on: [:kind :args |
		kind = 'process.frames' ifTrue: [{self frame: 1 method: 'Foo class>>foo:' receiverClass: 'Foo class'}] ifFalse: [
		kind = 'method.compile' ifTrue: [(JsonObject new) at: 'selector' put: 'foo:'; at: 'files' put: #(); yourself] ifFalse: [true]]].
	m := DebuggerModel new client: c; yourself.
	m stopped: (self stopEvent: 'Error: boom').
	m save: 'foo: x
	^ x'.
	self assert: (c sentKinds last: 2) equals: #('method.compile' 'process.restart').
	self assert: ((c sent at: c sent size - 1) last at: 'className') equals: 'Foo'.
	self assert: ((c sent at: c sent size - 1) last at: 'side') equals: 'class'.
	self assert: (c sent last last at: 'frame') equals: 1
]
