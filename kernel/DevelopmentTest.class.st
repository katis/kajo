"Module 9b's kernel items: Process>>terminate runs ensure: and ifCurtailed: blocks (a waiting, a running and the active Process; bounded); a send run again from a Context (frame restart, retried send); the pc-to-source map; evaluating in a Context; extensions of sealed classes; removed classes freed and their indices reused; Json; packages, extension files and author marks in Tonel; the request kinds."
Class {
	#name : #DevelopmentTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #running }
DevelopmentTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	#(#DevelopmentSampleA #DevelopmentSampleB) do: [:n |
		(Smalltalk at: n ifAbsent: [nil]) ifNotNil: [:c | Smalltalk removeClass: c]].
	(CompiledMethod includesSelector: #developmentExtensionSample) ifTrue: [CompiledMethod removeSelector: #developmentExtensionSample].
	(Object includesSelector: #developmentPackageSample) ifTrue: [Object removeSelector: #developmentPackageSample]
]

{ #category : #samples }
DevelopmentTest >> restartSample: n log: log [
	^ self restartedSample: n log: log
]

{ #category : #samples }
DevelopmentTest >> restartedSample: n log: log [
	| ctx |
	log add: n.
	ctx := thisContext.
	n = 1 ifTrue: [[ctx sender restartSendWith: (Array with: self with: 2 with: log)] ensure: [log add: #ensure]].
	^ n * 10
]

{ #category : #tests }
DevelopmentTest >> testAContextRunsItsSendAgain [
	"Context>>restartSendWith: unwinds to the sender (its ensure: blocks run) and re-executes the send: here, once, with another argument."
	| log result |
	log := OrderedCollection new.
	result := self restartSample: 1 log: log.
	self assert: result = 20.
	self assert: log asArray = #(1 #ensure 2)
]

{ #category : #tests }
DevelopmentTest >> testARemovedClassStillNamedIsKept [
	"A removed class an object still names keeps its indices until nothing does."
	| a index holder |
	Smalltalk isReleaseImage ifTrue: [^ self].
	a := Object subclass: #DevelopmentSampleA instanceVariableNames: '' classVariableNames: '' category: 'Kernel-Tests-Development'.
	index := a classIndex.
	Smalltalk removeClass: a.
	holder := Array with: a.
	a := nil.
	Smalltalk garbageCollect.
	self assert: (Smalltalk classAt: index) == holder first.
	self assert: holder first isObsolete.
	holder := nil.
	self assert: Smalltalk garbageCollect >= 1.
	self assert: (Smalltalk classAt: index) isNil
]

{ #category : #tests }
DevelopmentTest >> testEvaluateInAContextReadsAndWritesItsVariables [
	| x y r |
	Smalltalk isReleaseImage ifTrue: [^ self].
	x := 1.
	y := 5.
	r := Compiler evaluate: 'x := x + 10. x + y' in: thisContext.
	self assert: r = 16.
	self assert: x = 11.
	r := #(3) collect: [:each | Compiler evaluate: 'each * y' in: thisContext].
	self assert: r first = 15
]

{ #category : #tests }
DevelopmentTest >> testExtensionFilesAndAuthorMarks [
	"A method of another package than its class's is written in that package's extension file, with its author in the metadata; the class file leaves it out."
	| text |
	Smalltalk isReleaseImage ifTrue: [^ self].
	Object compile: 'developmentPackageSample ^ 42' classified: 'samples'.
	Smalltalk notePackage: 'DevelopmentSamples' of: #developmentPackageSample in: Object.
	Smalltalk noteAuthor: 'agent:test' of: #developmentPackageSample in: Object.
	self assert: (Smalltalk packageOfSelector: #developmentPackageSample in: Object) = 'DevelopmentSamples'.
	self assert: (TonelWriter fileNameOf: Object package: 'DevelopmentSamples') = 'Object.extension.st'.
	text := TonelWriter sourceOf: Object package: 'DevelopmentSamples'.
	self assert: (text beginsWith: 'Extension { #name : #Object }').
	self assert: (text includesSubstring: '{ #category : #samples, #author : #''agent:test'' }').
	self assert: (text includesSubstring: 'Object >> developmentPackageSample').
	self deny: ((TonelWriter sourceOf: Object) includesSubstring: 'developmentPackageSample').
	self assert: ((TonelReader read: text) methods first at: 4) = 'agent:test'.
	Object removeSelector: #developmentPackageSample.
	self assert: (Smalltalk packageOfSelector: #developmentPackageSample in: Object) = 'Kernel'
]

{ #category : #tests }
DevelopmentTest >> testJsonRoundTrip [
	| o text back |
	o := JsonObject new.
	o at: 'b' put: #(1 -2 3.5 true false nil); at: 'a' put: 'x"y\z', (String with: Character lf); at: 'c' put: JsonObject new.
	text := Json write: o.
	self assert: text = '{"b":[1,-2,3.5,true,false,null],"a":"x\"y\\z\n","c":{}}'.
	back := Json read: text.
	self assert: back keys = #('b' 'a' 'c').
	self assert: (back at: 'b') = #(1 -2 3.5 true false nil).
	self assert: (back at: 'a') = ('x"y\z', (String with: Character lf)).
	self assert: (Json read: '"é"') = 'é'.
	self should: [Json read: '{"a":}'] raise: Error
]

{ #category : #tests }
DevelopmentTest >> testRemovedClassesAreFreedAndTheirIndicesTaken [
	| a index b |
	Smalltalk isReleaseImage ifTrue: [^ self].
	a := Object subclass: #DevelopmentSampleA instanceVariableNames: 'x' classVariableNames: '' category: 'Kernel-Tests-Development'.
	index := a classIndex.
	Smalltalk removeClass: a.
	self assert: a isObsolete.
	self should: [a basicNew] raise: Error.
	a := nil.
	self assert: Smalltalk garbageCollect >= 1.
	self assert: (Smalltalk classAt: index) isNil.
	self assert: (Smalltalk classAt: index + 1) isNil.
	b := Object subclass: #DevelopmentSampleB instanceVariableNames: '' classVariableNames: '' category: 'Kernel-Tests-Development'.
	self assert: b classIndex = index.
	self assert: b new class == b
]

{ #category : #tests }
DevelopmentTest >> testRequestKinds [
	self assert: (DevProtocol kindOf: #processRetrySend:) = 'process.retrySend'.
	self assert: (DevProtocol kindOf: #protocolDescribe) = 'protocol.describe'.
	self assert: (DevProtocol kindOf: #evaluate:receiver:) = 'evaluate'.
	self assert: ((DevProtocol argumentNamesOf: #methodCompile:source:category:side:) = #('className' 'source' 'category' 'side'))
]

{ #category : #tests }
DevelopmentTest >> testSealedClassesTakeExtensionsThatOnlySend [
	Smalltalk isReleaseImage ifTrue: [^ self].
	CompiledMethod compile: 'developmentExtensionSample ^ self selector printString' classified: 'samples'.
	self assert: (CompiledMethod >> #developmentExtensionSample) developmentExtensionSample = '#developmentExtensionSample'.
	#('developmentExtensionSample ^ self slotAt: 1 put: 2' 'developmentExtensionSample <primitive: 117> ^ nil' 'developmentExtensionSample ^ self become: 3' 'developmentExtensionSample ^ [:x | x instVarAt: 1 put: 2] value: self') do: [:src |
		[CompiledMethod compile: src. self assert: false description: src] on: Error do: [:e |
			self assert: ((e messageText includesSubstring: 'sealed') or: [e messageText includesSubstring: 'instance variable'])]].
	self assert: (CompiledMethod >> #developmentExtensionSample) developmentExtensionSample = '#developmentExtensionSample'.
	CompiledMethod removeSelector: #developmentExtensionSample.
	self should: [Context compile: 'developmentExtensionSample ^ pc'] raise: Error
]

{ #category : #tests }
DevelopmentTest >> testSendBeforePcAndTheSourceMap [
	| m range src |
	m := DevelopmentTest >> #restartedSample:log:.
	self assert: m hasSourceMap.
	src := m sourceCode.
	self assert: (m sourceMapEntries allSatisfy: [:e | (e at: 2) <= (e at: 3) and: [(e at: 3) <= src byteSize]]).
	range := m sourceRangeAt: (m sourceMapEntries detect: [:e | (src copyFrom: (e at: 2) to: (e at: 3)) endsWith: 'add: n']) first.
	self assert: (src copyFrom: range first to: range last) = 'log add: n'.
	self assert: thisContext sender sendBeforePc notNil
]

{ #category : #tests }
DevelopmentTest >> testTerminateEndsAProcessWhoseUnwindBlockHangs [
	<slow>
	| p s |
	s := Semaphore new.
	p := [[Semaphore new wait] ensure: [Semaphore new wait]] fork.
	ProcessorScheduler yield.
	p terminate.
	self assert: p isTerminated
]

{ #category : #tests }
DevelopmentTest >> testTerminateRunsTheUnwindBlocksOfARunningProcess [
	| log started p n |
	log := OrderedCollection new.
	started := false.
	n := 0.
	p := [[started := true. [true] whileTrue: [n := n + 1]] ensure: [log add: #ensure]] fork.
	[started] whileFalse: [ProcessorScheduler yield].
	p terminate.
	self assert: p isTerminated.
	self assert: log asArray = #(#ensure)
]

{ #category : #tests }
DevelopmentTest >> testTerminateRunsTheUnwindBlocksOfAWaitingProcess [
	| log s p |
	log := OrderedCollection new.
	s := Semaphore new.
	p := [[[s wait] ifCurtailed: [log add: #curtailed]] ensure: [log add: #ensure]] fork.
	[p state == #waiting] whileFalse: [ProcessorScheduler yield].
	p terminate.
	self assert: p isTerminated.
	self assert: log asArray = #(#curtailed #ensure)
]

{ #category : #tests }
DevelopmentTest >> testTerminateRunsTheUnwindBlocksOfTheActiveProcess [
	| log done p |
	log := OrderedCollection new.
	done := Semaphore new.
	p := [[[log add: #body. ProcessorScheduler activeProcess terminate. log add: #notReached] ifCurtailed: [log add: #curtailed]]
		ensure: [log add: #ensure. done signal]] fork.
	done wait.
	self assert: log asArray = #(#body #curtailed #ensure)
]
