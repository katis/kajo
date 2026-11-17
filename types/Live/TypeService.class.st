"The type checker live in the image whose code it checks (Types 2, docs/modules/types-2.md, part 5). Two locks: lock guards the queue of changes and is held only to add or take (so a compile never waits for a check), checkLock guards the checker and is held through a check and by a reader of its diagnostics. Nothing runs until it is first asked (TypeService start, or the development protocol's diagnostics request): then it is Smalltalk's change listener, and its Process, below the user's priority, checks the whole image once and from then on hears of every method compiled or removed, signature added, changed or removed, and class defined, redefined or removed (Smalltalk noteChange:of:in:), and rechecks what depended on each change. Changes inside Smalltalk changesDuring: (a Tonel file loaded) are one recheck. When it has nothing to do its Process waits on its Semaphore, untimed. After a recheck that changed the set of diagnostics it emits one diagnostics.changed event to the development protocol's sessions. Class-side state: one service per image."
Class {
	#name : #TypeService,
	#superclass : #Object,
	#classInstVars : [
		'checker',
		'process',
		'semaphore',
		'lock',
		'checkLock',
		'pending',
		'depth',
		'busy',
		'waiters',
		'passes',
		'events',
		'lastChange',
		'lastRechecked',
		'lastPassUs'
	]
}

{ #category : #accessing }
TypeService class >> checker [
	"The TypeChecker, or nil before the service started."
	^ checker
]

{ #category : #accessing }
TypeService class >> diagnosticsAt: aKey [
	"The diagnostics of one method or signature key, as the checker has them now (nil before the service started)."
	checker isNil ifTrue: [^ nil].
	^ checkLock critical: [checker diagnosticsAt: aKey]
]

{ #category : #accessing }
TypeService class >> events [
	"How many diagnostics.changed events the rechecks made (whether or not a session heard them)."
	^ events ifNil: [0]
]

{ #category : #accessing }
TypeService class >> hasResultFor: aKey [
	checker isNil ifTrue: [^ false].
	^ checkLock critical: [checker hasResultFor: aKey]
]

{ #category : #accessing }
TypeService class >> isRunning [
	^ process notNil
]

{ #category : #accessing }
TypeService class >> lastPassUs [
	"How long the last check took, its invalidation included, in microseconds."
	^ lastPassUs ifNil: [0]
]

{ #category : #accessing }
TypeService class >> lastRechecked [
	"How many methods and signatures the last check checked (the whole image's count after the first)."
	^ lastRechecked ifNil: [0]
]

{ #category : #accessing }
TypeService class >> passes [
	"How many checks (the first whole one and every recheck) the service has made."
	^ passes ifNil: [0]
]

{ #category : #changes }
TypeService class >> beginChanges [
	"Smalltalk changesDuring: began: changes are held until it ends."
	lock critical: [depth := depth + 1]
]

{ #category : #changes }
TypeService class >> endChanges [
	"Smalltalk changesDuring: ended: what it held is one recheck."
	| go |
	go := lock critical: [
		depth := depth - 1 max: 0.
		depth = 0 and: [pending notEmpty]].
	go ifTrue: [semaphore signal]
]

{ #category : #changes }
TypeService class >> noteChange: aKind of: aSelectorOrName in: aBehavior [
	"Smalltalk's change listener: a change to recheck after; a wake-up unless inside Smalltalk changesDuring:."
	| go |
	go := lock critical: [
		pending add: (Array with: aKind with: aSelectorOrName with: aBehavior).
		lastChange := Smalltalk microsecondClock.
		depth = 0].
	go ifTrue: [semaphore signal]
]

{ #category : #checking }
TypeService class >> behaviorAndKeysOf: aClass into: aSet [
	"Every method and signature key of aClass and its subclasses, both sides, into aSet."
	(OrderedCollection new add: aClass; addAll: aClass allSubclasses; yourself) do: [:c |
		(Array with: c with: c class) do: [:b |
			b selectors do: [:sel | aSet add: (checker keyOf: sel in: b)].
			(Smalltalk typesOf: c) ifNotNil: [:t | (t signatureSelectorsMeta: b isMeta) do: [:sel | aSet add: (checker keyOf: sel in: b)]]]]
]

{ #category : #checking }
TypeService class >> classKeysOf: aName [
	"The checked keys of the class named aName, both sides."
	^ checker resultKeys select: [:k | (k beginsWith: aName , '>>') or: [k beginsWith: aName , ' class>>']]
]

{ #category : #checking }
TypeService class >> diagnosticsFor: aKeyCollection [
	"{key. its diagnostics' printStrings} of each key: what a recheck compares."
	^ aKeyCollection collect: [:k | Array with: k with: ((checker diagnosticsAt: k) collect: [:d | d printString])]
]

{ #category : #checking }
TypeService class >> drain [
	"One recheck: every change heard since the last, as one."
	| changes keys before after changed o |
	changes := lock critical: [ | c |
		c := pending.
		pending := OrderedCollection new.
		busy := c notEmpty.
		c].
	changes isEmpty ifTrue: [^ self].
	[checkLock critical: [ | t0 |
		t0 := Smalltalk microsecondClock.
		(changes includes: #all)
			ifTrue: [
				checker table forgetAll.
				checker forgetCaches.
				lastRechecked := checker checkAll.
				changed := nil]
			ifFalse: [
				keys := (self invalidationOf: changes) asArray.
				before := self diagnosticsFor: keys.
				checker recheck: keys.
				lastRechecked := keys size.
				after := self diagnosticsFor: keys.
				changed := OrderedCollection new.
				1 to: keys size do: [:i | ((before at: i) last = (after at: i) last) ifFalse: [changed add: (before at: i) first]]].
		passes := passes + 1.
		lastPassUs := Smalltalk microsecondClock - t0].
	(changed notNil and: [changed notEmpty]) ifTrue: [self emitChanged: changed]]
		ensure: [
			lock critical: [
				busy := false.
				pending isEmpty ifTrue: [
					waiters do: [:s | s signal].
					waiters := OrderedCollection new]]]
]

{ #category : #checking }
TypeService class >> invalidationOf: changes [
	"The keys to check again after the changes ({kind. selector or the class's old name. behavior} each), the type table and the inferred results forgotten where they read a changed class. A changed body rechecks the method alone (callers read its signature); a changed signature, an added or removed method and a class change recheck what read them."
	| keys table oldSigs |
	keys := Set new.
	table := checker table.
	changes do: [:c | | kind sel b cls key old new flipped |
		kind := c first. sel := c at: 2. b := c at: 3.
		cls := b theNonMetaClass.
		(kind == #method or: [kind == #methodRemoved or: [kind == #signature]]) ifTrue: [
			key := checker keyOf: sel in: b.
			old := (table classes at: cls ifAbsent: [nil]) ifNotNil: [:tc | (tc signaturesAt: sel meta: b isMeta) ifNil: [''] ifNotNil: [:l | l printString]].
			flipped := (table refresh: sel in: b) not and: [old notNil].
			new := (table typedClass: cls) in: [:tc | (tc signaturesAt: sel meta: b isMeta) ifNil: [''] ifNotNil: [:l | l printString]].
			flipped
				ifTrue: [
					"the class began or stopped carrying types: every lookup through it may change, so everything is checked again"
					checker forgetCaches.
					keys addAll: checker resultKeys]
				ifFalse: [
					keys addAll: (checker invalidate: 'body:' , key).
					(kind == #method and: [old notNil and: [old = new and: [checker hasResultFor: key]]]) ifFalse: [
						keys addAll: (checker invalidate: 'sig:' , key).
						keys addAll: (checker invalidate: 'sel:' , sel).
						keys addAll: (self withDependents: (checker indexKeysEndingWith: '>>' , sel))]].
			keys add: key].
		kind == #class ifTrue: [
			table forget: cls.
			self behaviorAndKeysOf: cls into: keys.
			(OrderedCollection new add: cls; addAll: cls allSubclasses; yourself) do: [:x |
				keys addAll: (self withDependents: (checker indexKeysOfClassNamed: x name)).
				(self classKeysOf: x name) do: [:k |
					keys add: k.
					keys addAll: (checker invalidate: 'sel:' , (k copyFrom: (k indexOfSubstring: '>>') + 2 to: k byteSize))]]].
		kind == #classRemoved ifTrue: [
			table forget: b.
			checker forgetClassNamed: sel.
			(self classKeysOf: sel) do: [:k |
				keys add: k.
				keys addAll: (checker invalidate: 'sel:' , (k copyFrom: (k indexOfSubstring: '>>') + 2 to: k byteSize))].
			keys addAll: (self withDependents: (checker indexKeysOfClassNamed: sel))]].
	^ keys
]

{ #category : #checking }
TypeService class >> withDependents: aKeyCollection [
	"The methods that read any of the keys (each key invalidated: the inferred results that read it forgotten)."
	| out |
	out := Set new.
	aKeyCollection do: [:k | out addAll: (checker invalidate: k)].
	^ out
]

{ #category : #protocol }
TypeService class >> diagnostic: a sortsBefore: b [
	| ka kb |
	ka := a where. kb := b where.
	ka = kb ifTrue: [^ a line <= b line].
	^ ka <= kb
]

{ #category : #protocol }
TypeService class >> diagnosticsOf: aClassName selector: aSelector side: aSide [
	"The development protocol's diagnostics request (DevSession>>diagnostics:selector:side:): every diagnostic of the image, of the class aClassName (both sides) or of its method or signature aSelector on aSide ('instance', the default, or 'class'), once the checker has caught up with every change made so far. A JsonObject: count, checked (methods and signatures checked) and diagnostics (each TypeDiagnostic>>asJson), sorted by class, side, selector and line. Starts the service when it is not running."
	| cls b keys out o |
	(aSide notNil and: [aSide ~= 'instance' and: [aSide ~= 'class']]) ifTrue: [^ self error: 'side is instance or class, not ' , aSide printString].
	(aSelector notNil and: [aClassName isNil]) ifTrue: [^ self error: 'a selector needs its className'].
	aClassName notNil ifTrue: [
		aClassName isString ifFalse: [^ self error: 'className is a String'].
		cls := Smalltalk at: aClassName asSymbol ifAbsent: [^ self error: 'no class ' , aClassName].
		cls isBehavior ifFalse: [^ self error: aClassName , ' is not a class']].
	(aSelector notNil and: [aSelector isString not]) ifTrue: [^ self error: 'selector is a String'].
	self start.
	(self waitUntilIdleFor: 600000) ifFalse: [^ self error: 'the type checker did not catch up in 600 s'].
	checkLock critical: [
		aClassName isNil
			ifTrue: [keys := checker resultKeys reject: [:k | (k indexOfSubstring: '>>') = 0]]
			ifFalse: [
				aSelector isNil
					ifTrue: [keys := self classKeysOf: cls name]
					ifFalse: [
						b := aSide = 'class' ifTrue: [cls class] ifFalse: [cls].
						keys := Array with: (checker keyOf: aSelector asSymbol in: b)]].
		out := OrderedCollection new.
		keys do: [:k | out addAll: (checker diagnosticsAt: k)]].
	out := out asArray sort: [:x :y | self diagnostic: x sortsBefore: y].
	o := JsonObject new.
	o at: 'count' put: out size; at: 'checked' put: keys size; at: 'diagnostics' put: (out collect: [:d | d asJson]).
	^ o
]

{ #category : #protocol }
TypeService class >> emitChanged: keys [
	"diagnostics.changed to the development protocol's sessions (nothing when not serving): the count now, the methods and signatures whose diagnostics changed (at most 200) and their diagnostics now (at most 500)."
	| o diags |
	events := events + 1.
	DevProtocol isServing ifFalse: [^ nil].
	diags := OrderedCollection new.
	keys do: [:k | diags addAll: (checker diagnosticsAt: k)].
	o := JsonObject new.
	o at: 'count' put: checker diagnosticCount;
		at: 'pass' put: passes;
		at: 'methods' put: (keys asArray sort: [:a :b | a <= b]) asArray;
		at: 'diagnostics' put: (diags asArray collect: [:d | d asJson]).
	(keys size > 200 or: [diags size > 500]) ifTrue: [
		o at: 'methods' put: ((o at: 'methods') copyFrom: 1 to: (keys size min: 200));
			at: 'diagnostics' put: ((o at: 'diagnostics') copyFrom: 1 to: (diags size min: 500));
			at: 'truncated' put: true].
	^ DevProtocol emit: 'diagnostics.changed' with: o
]

{ #category : #running }
TypeService class >> run [
	"The service's Process: one drain per wake-up; between them it waits on its Semaphore, untimed."
	[true] whileTrue: [
		semaphore wait.
		self drain]
]

{ #category : #running }
TypeService class >> start [
	"Start checking the image (nothing when it already is): the checker, the change listener, the Process at the user background priority, and the first check of the whole image, queued. Not in a release image (no type checker is built into one; this refuses if one was)."
	Smalltalk isReleaseImage ifTrue: [^ self error: 'a release image does not check types'].
	process notNil ifTrue: [^ self].
	lock := Mutex new.
	checkLock := Mutex new.
	pending := OrderedCollection with: #all.
	depth := 0.
	busy := false.
	waiters := OrderedCollection new.
	passes := 0.
	events := 0.
	checker := TypeChecker new.
	semaphore := Semaphore new.
	Smalltalk changeListener: self.
	process := [self run] forkAt: ProcessorScheduler userBackgroundPriority.
	semaphore signal
]

{ #category : #running }
TypeService class >> stop [
	"Stop listening and checking; what was checked is dropped."
	Smalltalk changeListener == self ifTrue: [Smalltalk changeListener: nil].
	process ifNotNil: [:p | p terminate].
	process := nil.
	checker := nil.
	waiters ifNotNil: [:w | w do: [:s | s signal]].
	waiters := nil
]

{ #category : #running }
TypeService class >> waitUntilIdleFor: milliseconds [
	"Wait until every change heard so far is checked; false when that took longer than milliseconds (a wait for something that must come, long everywhere). The timer that bounds the wait exists only while someone waits."
	| s timer timedOut |
	s := Semaphore new.
	(lock critical: [
		(pending isEmpty and: [busy not])
			ifTrue: [true]
			ifFalse: [waiters add: s. false]]) ifTrue: [^ true].
	timedOut := false.
	timer := [(Delay forMilliseconds: milliseconds) wait. timedOut := true. s signal] forkAt: ProcessorScheduler userInterruptPriority.
	s wait.
	timer terminate.
	^ timedOut not
]
