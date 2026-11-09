"Module 9b's kernel items: Process>>terminate runs ensure: and ifCurtailed: blocks (a waiting, a running and the active Process; bounded); a send run again from a Context (frame restart, retried send); the pc-to-source map; evaluating in a Context; extensions of sealed classes; removed classes freed and their indices reused; Json; packages, extension files and author marks in Tonel; the request kinds."
Class {
	#name : #DevelopmentTest,
	#superclass : #TestCase
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
DevelopmentTest >> authorMarkSample [
	"Both compilers agree on a method with an author pragma (CompilerTest compiles every method of the image with both)."
	<author: #'agent:sample'>
	^ 42
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
	a := Object subclass: #DevelopmentSampleA instanceVariableNames: '' classVariableNames: '' package: 'Kernel' tag: 'Tests-Development'.
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
DevelopmentTest >> testAnAgentsAuthorMarkIsOnePragma [
	"The rule a session follows (TonelWriter source:author:, the development answers): an agent's compile leaves exactly one author pragma, its own, after the pattern, the comment and the pragmas before the temporaries; a developer's source is compiled as written."
	| lf tab mark |
	lf := String lf.
	tab := String tab.
	mark := tab , '<author: #''agent:a''>' , lf.
	self assert: (TonelWriter source: 'foo' , lf , tab , '^ 1' , lf author: 'agent:a')
		equals: 'foo' , lf , mark , tab , '^ 1' , lf.
	self assert: (TonelWriter source: 'foo: x' , lf , tab , '"c"' , lf , tab , '<bar>' , lf , tab , '| t |' , lf , tab , '^ x' , lf author: 'agent:a')
		equals: 'foo: x' , lf , tab , '"c"' , lf , tab , '<bar>' , lf , mark , tab , '| t |' , lf , tab , '^ x' , lf.
	"Another agent's mark is replaced; the same agent's stays one."
	self assert: (TonelWriter source: 'foo' , lf , tab , '<author: #''agent:b''>' , lf , tab , '^ 1' , lf author: 'agent:a')
		equals: 'foo' , lf , mark , tab , '^ 1' , lf.
	self assert: (TonelWriter source: 'foo' , lf , mark , tab , '^ 1' , lf author: 'agent:a')
		equals: 'foo' , lf , mark , tab , '^ 1' , lf.
	"A mark after the temporaries moves before them; one sharing its line keeps the line."
	self assert: (TonelWriter source: 'foo' , lf , tab , '| t |' , lf , tab , '<author: #x>' , lf , tab , '^ t' , lf author: 'agent:a')
		equals: 'foo' , lf , mark , tab , '| t |' , lf , tab , '^ t' , lf.
	self assert: (TonelWriter source: 'foo' , lf , tab , '<author: #x> <bar>' , lf , tab , '^ 1' , lf author: 'agent:a')
		equals: 'foo' , lf , tab , '<bar>' , lf , mark , tab , '^ 1' , lf.
	"A developer's source, a mark included, is compiled as written; so is one the scanner cannot read."
	self assert: (TonelWriter source: 'foo' , lf , tab , '<author: #''agent:b''>' , lf , tab , '^ 1' , lf author: 'developer')
		equals: 'foo' , lf , tab , '<author: #''agent:b''>' , lf , tab , '^ 1' , lf.
	self assert: (TonelWriter source: 'foo' , lf , tab , '<author: ' author: 'agent:a') equals: 'foo' , lf , tab , '<author: '.
	"An empty body."
	self assert: (TonelWriter source: 'foo' , lf author: 'agent:a') equals: 'foo' , lf , mark
]

{ #category : #tests }
DevelopmentTest >> testClassDefineIntoATagAndMoving [
	"class.define with a package and a tag (tags as subdirectories): the class's file is <Tag>/<Name>.class.st in the session's project, a definition with another tag moves it (the new file to write, the old one to remove), one with no tag puts it at the package's root, one with neither keeps its place, and the file never carries a #category, #package or #tag key."
	| s r files c |
	Smalltalk isReleaseImage ifTrue: [^ self].
	s := DevSession conn: 0 client: 'developer' package: 'DevelopmentSamples'.
	[r := s classDefine: 'DevelopmentSampleT' superclass: nil instanceVariables: 'a' classVariables: nil package: nil tag: 'Things'.
	c := Smalltalk at: #DevelopmentSampleT.
	self assert: (Smalltalk packageOf: c) = 'DevelopmentSamples'.
	self assert: (Smalltalk tagOf: c) == #Things.
	files := r at: 'files'.
	self assert: files size = 1.
	self assert: (files first at: 'path') = 'Things/DevelopmentSampleT.class.st'.
	self deny: ((files first at: 'text') includesSubstring: (String with: Character tab) , '#category :').
	self deny: ((files first at: 'text') includesSubstring: (String with: Character tab) , '#tag :').
	self deny: ((files first at: 'text') includesSubstring: (String with: Character tab) , '#package :').
	r := s classDefine: 'DevelopmentSampleT' superclass: nil instanceVariables: 'a b' classVariables: nil package: nil tag: nil.
	self assert: (Smalltalk tagOf: c) == #Things.
	self assert: ((r at: 'files') collect: [:f | f at: 'path']) = #('Things/DevelopmentSampleT.class.st').
	r := s classDefine: 'DevelopmentSampleT' superclass: nil instanceVariables: 'a b' classVariables: nil package: nil tag: 'Other'.
	files := r at: 'files'.
	self assert: (files collect: [:f | f at: 'path']) = #('Other/DevelopmentSampleT.class.st' 'Things/DevelopmentSampleT.class.st').
	self assert: ((files at: 1) at: 'text') notNil.
	self assert: ((files at: 2) at: 'remove') == true.
	r := s classDefine: 'DevelopmentSampleT' superclass: nil instanceVariables: 'a b' classVariables: nil package: 'DevelopmentSamples' tag: nil.
	self assert: (Smalltalk tagOf: c) isNil.
	self assert: ((r at: 'files') collect: [:f | f at: 'path']) = #('DevelopmentSampleT.class.st' 'Other/DevelopmentSampleT.class.st').
	self assert: ((s classList: 'DevelopmentSamples' tag: nil) includes: 'DevelopmentSampleT').
	self assert: (s classList: 'DevelopmentSamples' tag: 'Other') isEmpty.
	self assert: ((s classDefinition: 'DevelopmentSampleT') at: 'package') = 'DevelopmentSamples'.
	self assert: ((s classDefinition: 'DevelopmentSampleT') at: 'tag') isNil.
	files := (s classRemove: 'DevelopmentSampleT') at: 'files'.
	self assert: (files first at: 'path') = 'DevelopmentSampleT.class.st'.
	self assert: (files first at: 'remove') == true]
		ensure: [
			(Smalltalk at: #DevelopmentSampleT ifAbsent: [nil]) ifNotNil: [:k | Smalltalk removeClass: k].
			c := nil.
			Smalltalk garbageCollect]
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
	"A method of another package than its class's is written in that package's extension file; the class file leaves it out. An agent's author mark is a pragma in the source (the development answers): the metadata holds the category only, the pragma index finds the method, and a file still carrying the old #author key reads with the key ignored."
	| text doc |
	Smalltalk isReleaseImage ifTrue: [^ self].
	Object compile: (TonelWriter source: (TonelWriter canonicalSource: 'developmentPackageSample ^ 42') author: 'agent:test') classified: 'samples'.
	Smalltalk notePackage: 'DevelopmentSamples' of: #developmentPackageSample in: Object.
	self assert: (Smalltalk packageOfSelector: #developmentPackageSample in: Object) = 'DevelopmentSamples'.
	self assert: (Smalltalk authorOfSelector: #developmentPackageSample in: Object) = 'agent:test'.
	self assert: ((Pragma allNamed: #author:) anySatisfy: [:p | p method == (Object >> #developmentPackageSample)]).
	self assert: (TonelWriter fileNameOf: Object package: 'DevelopmentSamples') = 'Object.extension.st'.
	text := TonelWriter sourceOf: Object package: 'DevelopmentSamples'.
	self assert: (text beginsWith: 'Extension { #name : #Object }').
	self assert: (text includesSubstring: '{ #category : #samples }
Object >> developmentPackageSample [
	<author: #''agent:test''>
	^ 42
]').
	self deny: (text includesSubstring: '#author :').
	self deny: ((TonelWriter sourceOf: Object) includesSubstring: 'developmentPackageSample').
	doc := TonelReader read: text.
	self assert: doc methods first size = 3.
	self assert: ((doc methods first at: 3) includesSubstring: '<author: #''agent:test''>').
	doc := TonelReader read: 'Extension { #name : #Object }

{ #category : #samples, #author : #''agent:old'' }
Object >> developmentOldMark [
	^ 1
]
'.
	self assert: (doc methods first at: 2) = 'samples'.
	self assert: doc methods first size = 3.
	Object removeSelector: #developmentPackageSample.
	self assert: (Smalltalk authorOfSelector: #developmentPackageSample in: Object) isNil.
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
	a := Object subclass: #DevelopmentSampleA instanceVariableNames: 'x' classVariableNames: '' package: 'Kernel' tag: 'Tests-Development'.
	index := a classIndex.
	Smalltalk removeClass: a.
	self assert: a isObsolete.
	self should: [a basicNew] raise: Error.
	a := nil.
	self assert: Smalltalk garbageCollect >= 1.
	self assert: (Smalltalk classAt: index) isNil.
	self assert: (Smalltalk classAt: index + 1) isNil.
	b := Object subclass: #DevelopmentSampleB instanceVariableNames: '' classVariableNames: '' package: 'Kernel' tag: 'Tests-Development'.
	self assert: b classIndex = index.
	self assert: b new class == b
]

{ #category : #tests }
DevelopmentTest >> testRequestKinds [
	self assert: (DevProtocol kindOf: #processRetrySend:) = 'process.retrySend'.
	self assert: (DevProtocol kindOf: #protocolDescribe) = 'protocol.describe'.
	self assert: (DevProtocol kindOf: #evaluate:receiver:) = 'evaluate'.
	self assert: ((DevProtocol argumentNamesOf: #methodCompile:source:category:side:) = #('className' 'source' 'category' 'side')).
	self assert: ((DevProtocol argumentNamesOf: #classDefine:superclass:instanceVariables:classVariables:package:tag:) = #('name' 'superclass' 'instanceVariables' 'classVariables' 'package' 'tag')).
	self assert: ((DevProtocol argumentNamesOf: #classList:tag:) = #('package' 'tag')).
	self assert: (DevSession lookupSelector: #classCategories) isNil
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
	"The bound stays, and a cut-off is never silent (the development answers): terminate answers false, the cut-off is counted, and the Transcript names the Process and the block it stood in."
	<slow>
	| p before hang |
	before := Unwinding cutOffCount.
	hang := [Semaphore new wait].
	p := [[Semaphore new wait] ensure: hang] fork.
	[p state == #waiting] whileFalse: [ProcessorScheduler yield].
	self deny: p terminate.
	self assert: p isTerminated.
	self assert: Unwinding cutOffCount equals: before + 1.
	self assert: (Unwinding blockOf: p) isNil.
	self assert: (Unwinding describe: hang) equals: '[] in DevelopmentTest>>testTerminateEndsAProcessWhoseUnwindBlockHangs'
]

{ #category : #tests }
DevelopmentTest >> testTerminateRunsTheUnwindBlocksOfARunningProcess [
	| log started p n |
	log := OrderedCollection new.
	started := false.
	n := 0.
	p := [[started := true. [true] whileTrue: [n := n + 1]] ensure: [log add: #ensure]] fork.
	[started] whileFalse: [ProcessorScheduler yield].
	self assert: p terminate.
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
	self assert: p terminate.
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
