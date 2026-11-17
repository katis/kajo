"The checker live (Types 2, docs/modules/types-2.md, part 5), through the one TypeService of the image, started without the first check of the whole image (startCheckingAll: false; the development protocol's tests check it whole) and stopped by each test: a file loaded is one recheck, a method body changed rechecks that method alone, a signature changed rechecks what read it, a class removed takes its diagnostics with it; and an idle service holds no timer, and work after idling is checked within a bound."
Class {
	#name : #TypeServiceTest,
	#superclass : #TestCase
}

{ #category : #helpers }
TypeServiceTest >> callerText [
	^ 'Class {
	#name : #TypeLiveCaller,
	#superclass : #Object
}

{ #category : #probe }
TypeLiveCaller >> use [
	^ TypeLiveProbe new size + 1
]
'
]

{ #category : #helpers }
TypeServiceTest >> probeText [
	"A class of twenty methods and one typed one, as one Tonel file."
	| s |
	s := WriteStream on: String new.
	s nextPutAll: 'Class {
	#name : #TypeLiveProbe,
	#superclass : #Object
}
'.
	1 to: 20 do: [:i |
		s nextPutAll: '
{ #category : #probe }
TypeLiveProbe >> m'; print: i; nextPutAll: ' [
	^ '; print: i; nextPutAll: ' + 1
]
'].
	s nextPutAll: '
{ #category : #probe }
TypeLiveProbe >> size ^<Integer> [
	^ 3
]
'.
	^ s contents
]

{ #category : #helpers }
TypeServiceTest >> waitIdle [
	self assert: (TypeService waitUntilIdleFor: 600000) description: 'the checker did not catch up in 600 s'
]

{ #category : #running }
TypeServiceTest >> tearDown [
	TypeService stop.
	#(#TypeLiveCaller #TypeLiveProbe) do: [:n | (Smalltalk at: n ifAbsent: [nil]) ifNotNil: [:c | Smalltalk removeClass: c]]
]

{ #category : #tests }
TypeServiceTest >> testIdleHoldsNoTimerAndWorkAfterIdlingIsChecked [
	| delays passes |
	delays := Delay pendingCount.
	TypeService startCheckingAll: false.
	self waitIdle.
	"idle: the service's Process waits on its Semaphore, untimed; no Delay of its own is pending"
	self assert: Delay pendingCount equals: delays.
	self assert: TypeService isRunning.
	passes := TypeService passes.
	Smalltalk readTonel: self probeText.
	"a wait for something that must come, with a long bound"
	self assert: (TypeService waitUntilIdleFor: 120000).
	self assert: TypeService passes equals: passes + 1.
	self assert: Delay pendingCount equals: delays
]

{ #category : #tests }
TypeServiceTest >> testLiveRechecks [
	| passes |
	TypeService startCheckingAll: false.
	self waitIdle.
	self assert: TypeService passes equals: 0.
	"a file of twenty-one methods loaded: one recheck"
	passes := TypeService passes.
	Smalltalk readTonel: self probeText.
	self waitIdle.
	self assert: TypeService passes equals: passes + 1.
	self assert: TypeService lastRechecked >= 21.
	self assert: (TypeService hasResultFor: 'TypeLiveProbe>>m20').
	Smalltalk readTonel: self callerText.
	self waitIdle.
	self assert: (TypeService diagnosticsAt: 'TypeLiveCaller>>use') isEmpty.
	"a method body changed: that method alone (its callers read its signature)"
	passes := TypeService passes.
	(Smalltalk at: #TypeLiveProbe) compile: 'size ^<Integer>
	^ 4'.
	self waitIdle.
	self assert: TypeService passes equals: passes + 1.
	self assert: TypeService lastRechecked equals: 1.
	"its signature changed: what read it, the caller among them"
	(Smalltalk at: #TypeLiveProbe) compile: 'size ^<String>
	^ ''four'''.
	self waitIdle.
	self assert: TypeService lastRechecked >= 2.
	self assert: ((TypeService diagnosticsAt: 'TypeLiveCaller>>use') collect: [:d | d kind]) asArray equals: #(#dnu).
	"a class removed: its diagnostics go"
	Smalltalk removeClass: (Smalltalk at: #TypeLiveCaller).
	self waitIdle.
	self deny: (TypeService hasResultFor: 'TypeLiveCaller>>use').
	self assert: (TypeService diagnosticsAt: 'TypeLiveCaller>>use') isEmpty
]
