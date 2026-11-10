"The review fixes, item 10: the registries request Processes share (Smalltalk's sources and categories, the pragma index, a session's handles) stay whole when Processes write and read them at once."
Class {
	#name : #RegistryTest,
	#superclass : #TestCase
}

{ #category : #running }
RegistryTest >> fork: n times: aBlock [
	"Run aBlock (with its Process's index) in n Processes at once and wait for all of them: 600 s at most, a bound for a hang only (under ThreadSanitizer the work is many times slower)."
	| done count deadline |
	done := Semaphore new.
	count := 0.
	1 to: n do: [:i | [[aBlock value: i] ensure: [done signal]] fork].
	deadline := Smalltalk microsecondClock + 600000000.
	[count < n and: [Smalltalk microsecondClock < deadline]] whileTrue: [
		done excessSignals > 0 ifTrue: [done wait. count := count + 1] ifFalse: [(Delay forMilliseconds: 5) wait]].
	self assert: count = n
]

{ #category : #tests }
RegistryTest >> testCompilesFromManyProcessesKeepEverySource [
	| per |
	per := Array new: 4.
	self fork: 4 times: [:i |
		per at: i put: ((1 to: 20) collect: [:k | | sel |
			sel := ('registryProbe' , i printString , 'x' , k printString) asSymbol.
			RegistryTestProbe compile: sel , ' ^ ' , k printString.
			sel])].
	[per do: [:sels | sels do: [:sel |
		self assert: (Smalltalk sourceOf: (RegistryTestProbe compiledMethodAt: sel)) notNil]]]
		ensure: [per do: [:sels | sels ifNotNil: [sels do: [:sel | RegistryTestProbe removeSelector: sel]]]]
]

{ #category : #tests }
RegistryTest >> testHandlesFromManyProcessesAreDistinct [
	| session per all |
	session := DevSession conn: 0 client: 'developer' package: nil.
	per := Array new: 8.
	self fork: 8 times: [:i | per at: i put: ((1 to: 60) collect: [:k | session handleOf: Object new])].
	all := Set new.
	per do: [:hs | hs do: [:h | all add: h]].
	self assert: all size = 480
]

{ #category : #tests }
RegistryTest >> testThePragmaIndexIsWholeWhileItIsRebuilt [
	| n misses |
	n := (Pragma allNamed: #devProtocol) size.
	misses := 0.
	self fork: 2 times: [:i |
		i = 1
			ifTrue: [8 timesRepeat: [Pragma rebuildIndex]]
			ifFalse: [100 timesRepeat: [(Pragma allNamed: #devProtocol) size = n ifFalse: [misses := misses + 1]]]].
	self assert: misses = 0.
	self assert: (Pragma allNamed: #devProtocol) size = n
]
