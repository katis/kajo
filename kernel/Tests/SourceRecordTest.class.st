"A method another Process can see has its source (the tools test's fault, docs/modules/tools-test-fault.md): a reader that finds a method compiled or remade by a redefinition, while the Process making it stands right after the method became visible (SourceRecordSample's hooks), reads its source as the tools test's probe did (sourceOf: then beginsWith:), and finds it."
Class {
	#name : #SourceRecordTest,
	#superclass : #TestCase
}

{ #category : #running }
SourceRecordTest >> readSourceOf: aSymbol [
	"What the tools test's probe read: true, false, or the error's text."
	^ [(Smalltalk sourceOf: (SourceRecordSample compiledMethodAt: aSymbol)) beginsWith: aSymbol asString]
		on: MessageNotUnderstood do: [:e | e return: e messageText]
]

{ #category : #running }
SourceRecordTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	SourceRecordSample onChange: nil.
	SourceRecordSample selectors do: [:s | SourceRecordSample removeSelector: s].
	SourceRecordSample instVarNames isEmpty ifFalse: [
		ClassBuilder redefine: SourceRecordSample instanceVariableNames: #() classVariableNames: #() classInstanceVariableNames: #('onChange' 'inHook')]
]

{ #category : #tests }
SourceRecordTest >> testAReaderAfterTheInstallFindsTheSource [
	"Twenty compiles; at each, a second Process reads the new method's source while the compiling one stands right after the install and waits for it."
	| answers |
	Smalltalk isReleaseImage ifTrue: [^ self].
	answers := OrderedCollection new.
	SourceRecordSample onChange: [:sel | | done |
		done := Semaphore new.
		[answers add: (self readSourceOf: sel). done signal] fork.
		done wait].
	1 to: 20 do: [:i | SourceRecordSample compile: 'recorded' , i printString , ' ^ ' , i printString].
	SourceRecordSample onChange: nil.
	self assert: answers size = 20.
	self assert: (answers allSatisfy: [:a | a == true]) description: 'answers ' , answers asArray printString
]

{ #category : #tests }
SourceRecordTest >> testAReaderDuringARedefinitionFindsTheSource [
	"A reshape makes the class's methods again: a second Process reads one's source while the redefining Process stands where the new methods are installed and their sources not yet recorded anew; the redefining Process waits for the reader 2 s at most (it may be waiting for the redefinition to end), then goes on, and the reader's answer is read after both."
	| answers done hookRan |
	Smalltalk isReleaseImage ifTrue: [^ self].
	SourceRecordSample compile: 'recordedValue ^ 7'.
	answers := OrderedCollection new.
	done := Semaphore new.
	hookRan := false.
	SourceRecordSample onChange: [:sel | | t |
		hookRan := true.
		[answers add: (self readSourceOf: sel). done signal] fork.
		t := Smalltalk microsecondClock.
		[answers isEmpty and: [Smalltalk microsecondClock - t < 2000000]] whileTrue: [(Delay forMilliseconds: 5) wait]].
	ClassBuilder redefine: SourceRecordSample instanceVariableNames: #('extra') classVariableNames: #() classInstanceVariableNames: #('onChange' 'inHook').
	SourceRecordSample onChange: nil.
	done wait.
	self assert: hookRan.
	self assert: SourceRecordSample new recordedValue = 7.
	self assert: answers asArray = #(true) description: 'answers ' , answers asArray printString
]
