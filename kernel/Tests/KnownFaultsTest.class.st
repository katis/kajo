"The VM's known faults (docs/modules/known-faults.md), items 3, 5 and 6: a method replaced or removed keeps its source for whoever still holds it, and the record goes with the method; the pragma index is told inside the lock its readers take; a refused class removal names the Process and the frame that hold the class; a method's frame variables are found once for every stop."
Class {
	#name : #KnownFaultsTest,
	#superclass : #TestCase
}

{ #category : #running }
KnownFaultsTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	KnownFaultsSample onInstall: nil.
	KnownFaultsSample selectors do: [:s | (s == #hold:until:) ifFalse: [KnownFaultsSample removeSelector: s]].
	(Smalltalk at: #KnownFaultsRemovable ifAbsent: [nil]) ifNotNil: [:c | [Smalltalk removeClass: c] on: Error do: [:e | nil]]
]

{ #category : #tests }
KnownFaultsTest >> testAHeldMethodRemovedKeepsItsSource [
	"Item 3: a reader that found the method before removeSelector: still reads its source (nil on 7ba9643, 5 of 5)."
	| m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	KnownFaultsSample compile: 'kfGone ^ 1'.
	m := KnownFaultsSample compiledMethodAt: #kfGone.
	KnownFaultsSample removeSelector: #kfGone.
	self deny: (KnownFaultsSample includesSelector: #kfGone).
	self assert: (Smalltalk sourceOf: m) equals: 'kfGone ^ 1'
]

{ #category : #tests }
KnownFaultsTest >> testAHeldMethodReplacedKeepsItsSource [
	"Item 3: a reader that found the method before it was replaced still reads its old source (nil on 7ba9643, 5 of 5); the new method has the new one."
	| m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	KnownFaultsSample compile: 'kfOld ^ 1'.
	m := KnownFaultsSample compiledMethodAt: #kfOld.
	KnownFaultsSample compile: 'kfOld ^ 2'.
	self assert: (Smalltalk sourceOf: m) equals: 'kfOld ^ 1'.
	self assert: (Smalltalk sourceOf: (KnownFaultsSample compiledMethodAt: #kfOld)) equals: 'kfOld ^ 2'
]

{ #category : #tests }
KnownFaultsTest >> testANewStopReadsAMethodsVariablesWithoutCompiling [
	"Item 6: the variables of a method's frames are found once, for every stop: two stops answer the same object (each found its own by compiling the method again on 7ba9643: a new stop's frames reply was 22 times the second reply of the same stop)."
	| m a b |
	m := thisContext method.
	a := (DebugStop process: nil exception: nil reason: 'test' frames: (Array with: thisContext)) variablesOf: m.
	b := (DebugStop process: nil exception: nil reason: 'test' frames: (Array with: thisContext)) variablesOf: m.
	self assert: a == b.
	self assert: (Compiler frameVariablesOf: m) == a.
	self assert: (a anySatisfy: [:v | v first = 'a'])
]

{ #category : #tests }
KnownFaultsTest >> testAPragmaReaderAtTheInstallFindsTheMethod [
	"Item 3: a second Process reads the pragma index while the installing one stands right after the install primitive (the sample's hook), given 2 s; its answer, read after both, has the new method (none on 7ba9643, 5 of 5: the index was told after the install, outside the registry's lock)."
	| answer done t |
	Smalltalk isReleaseImage ifTrue: [^ self].
	answer := nil.
	done := Semaphore new.
	KnownFaultsSample onInstall: [:sel |
		[answer := (Pragma allNamed: #knownFaultsMark) collect: [:p | p method selector]. done signal] fork.
		t := Smalltalk microsecondClock.
		[answer isNil and: [Smalltalk microsecondClock - t < 2000000]] whileTrue: [(Delay forMilliseconds: 5) wait]].
	KnownFaultsSample compile: 'kfMarked <knownFaultsMark> ^ 1'.
	done wait.
	self assert: (answer includes: #kfMarked) description: 'answer ' , answer printString
]

{ #category : #tests }
KnownFaultsTest >> testARefusedInstallSignalsOutsideTheRegistry [
	"Item 3's lock: the VM refuses a method made for another selector; its error is signalled after the registry is let go, so a handler (or a debugger stop) of it holds no lock that another Process's sourceOf: waits for."
	| m read |
	Smalltalk isReleaseImage ifTrue: [^ self].
	m := KnownFaultsSample compiledMethodAt: #hold:until:.
	read := nil.
	[KnownFaultsSample addSelector: #kfElsewhere withMethod: m] on: Error do: [:e | | t |
		[Smalltalk sourceOf: m. read := true] fork.
		t := Smalltalk microsecondClock.
		[read isNil and: [Smalltalk microsecondClock - t < 2000000]] whileTrue: [(Delay forMilliseconds: 5) wait].
		e return: nil].
	self assert: read == true.
	self deny: (KnownFaultsSample includesSelector: #kfElsewhere)
]

{ #category : #tests }
KnownFaultsTest >> testARefusedRemovalNamesTheProcessAndTheFrame [
	"Item 5: another Process holds the class in a temporary while it waits; the removal is refused with a reason that names that Process and the method of its frame (the reason named neither on 7ba9643, 5 of 5), and the class is removed once it has let go."
	| c sem p text |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := Object subclass: #KnownFaultsRemovable instanceVariableNames: '' classVariableNames: '' package: 'Kernel' tag: 'Tests'.
	sem := Semaphore new.
	p := [KnownFaultsSample new hold: c until: sem] fork.
	[p state == #waiting] whileFalse: [(Delay forMilliseconds: 1) wait].
	text := [Smalltalk removeClass: c. nil] on: ClassDefinitionError do: [:e | e messageText].
	sem signal.
	[p isTerminated] whileFalse: [(Delay forMilliseconds: 1) wait].
	self assert: text notNil.
	self assert: (text includesSubstring: 'the Process ' , p id printString , ' holds KnownFaultsRemovable') description: text.
	self assert: (text includesSubstring: 'KnownFaultsSample>>hold:until:') description: text.
	Smalltalk removeClass: c.
	self assert: (Smalltalk at: #KnownFaultsRemovable ifAbsent: [nil]) isNil
]

{ #category : #tests }
KnownFaultsTest >> testARetiredSourceGoesWithItsMethod [
	"Item 3: the source of a replaced method nothing holds leaves no record after a collection; one something holds stays counted."
	| n m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	Smalltalk garbageCollect.
	n := Smalltalk retiredSourceCount.
	KnownFaultsSample compile: 'kfFree ^ 1'.
	KnownFaultsSample compile: 'kfFree ^ 2'.
	KnownFaultsSample compile: 'kfHeld ^ 1'.
	m := KnownFaultsSample compiledMethodAt: #kfHeld.
	KnownFaultsSample compile: 'kfHeld ^ 2'.
	Smalltalk garbageCollect.
	self assert: Smalltalk retiredSourceCount equals: n + 1.
	self assert: (Smalltalk sourceOf: m) equals: 'kfHeld ^ 1'
]
