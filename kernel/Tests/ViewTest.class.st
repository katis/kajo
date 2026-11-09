"The view wrappers' protocol (ADR 0010), headless or against a shell: with a shell (the Swift test shell, the apps' tests mode) every call hops to the main thread and goes through the view primitive; without one the wrappers keep their properties themselves. tearDown leaves the main thread so the rest of the suite runs on any worker."
Class {
	#name : #ViewTest,
	#superclass : #TestCase
}

{ #category : #helpers }
ViewTest >> makeAndDropAView [
	^ View new handle
]

{ #category : #running }
ViewTest >> tearDown [
	ProcessorScheduler detachFromMain
]

{ #category : #tests }
ViewTest >> testADeadWrapperReleasesItsHandle [
	| before h tries |
	before := View diedCount.
	h := self makeAndDropAView.
	Smalltalk garbageCollect.
	tries := 0.
	[(View includesHandle: h) and: [tries < 500]] whileTrue: [
		(Delay forMilliseconds: 10) wait.
		tries := tries + 1].
	self deny: (View includesHandle: h).
	self assert: View diedCount > before
]

{ #category : #tests }
ViewTest >> testAWindowHoldsItsViews [
	| w l closedWith |
	w := Window new.
	w title: 'Kajo'.
	l := w add: Label new.
	self assert: (w subviews includes: l).
	self assert: l superview == w.
	self assert: w title equals: 'Kajo'.
	w onClose: [:win | closedWith := win].
	UIEventLoop dispatch: (UIEvent kind: #close target: w handle value: nil time: 0).
	self assert: closedWith == w.
	self assert: w isClosed
]

{ #category : #tests }
ViewTest >> testAnErrorInAHandlerIsCaught [
	| b errors |
	b := Button new.
	b action: [1 / 0].
	errors := UIEventLoop errorCount.
	UIEventLoop dispatch: (UIEvent kind: #click target: b handle value: nil time: 0).
	self assert: UIEventLoop errorCount equals: errors + 1
]

{ #category : #tests }
ViewTest >> testAnEventFromTheShellsArray [
	| e |
	e := UIEvent fromArray: #(2 7 0.5 1000).
	self assert: e kind equals: #valueChanged.
	self assert: e target equals: 7.
	self assert: e value equals: 0.5.
	self assert: e time equals: 1000.
	self assert: (UIEvent fromArray: #(99 0 nil 0)) kind equals: #unknown
]

{ #category : #tests }
ViewTest >> testButtonActionRunsOnAClickEvent [
	| b count |
	count := 0.
	b := Button new.
	b title: 'Press'.
	b action: [count := count + 1].
	UIEventLoop dispatch: (UIEvent kind: #click target: b handle value: nil time: 0).
	UIEventLoop dispatch: (UIEvent kind: #click target: b handle value: nil time: 0).
	self assert: count equals: 2.
	self assert: b title equals: 'Press'
]

{ #category : #tests }
ViewTest >> testFrameAndMove [
	| v |
	v := View new.
	v x: 10 y: 20 width: 30 height: 40.
	self assert: v x equals: 10.
	self assert: v y equals: 20.
	self assert: v width equals: 30.
	self assert: v height equals: 40.
	v moveToX: 5 y: 6.
	self assert: v x equals: 5.
	self assert: v y equals: 6.
	self assert: v width equals: 30
]

{ #category : #tests }
ViewTest >> testHeadlessThereIsNoEventLoop [
	View hasShell ifTrue: [^ self].
	self deny: UIEventLoop start.
	self assert: UIEventLoop nextEvent isNil.
	self assert: View new handle < 0
]

{ #category : #tests }
ViewTest >> testSetThenGetInTheSameTurn [
	| l |
	l := Label new.
	l text: 'hello'.
	self assert: l text equals: 'hello'.
	l text: 'again'.
	self assert: l text equals: 'again'
]

{ #category : #tests }
ViewTest >> testSliderActionGetsTheValue [
	| s got |
	s := Slider new.
	s minimum: 0 maximum: 100.
	s value: 25.
	self assert: s value equals: 25.0.
	self assert: s maximum equals: 100.0.
	s action: [:v | got := v].
	UIEventLoop dispatch: (UIEvent kind: #valueChanged target: s handle value: 42.5 time: 0).
	self assert: got equals: 42.5
]

{ #category : #tests }
ViewTest >> testTextViewAppendsLines [
	| t |
	t := TextView new.
	t appendLine: 'one'.
	UIEventLoop dispatch: (UIEvent kind: #text target: t handle value: 'two' time: 0).
	self assert: t text equals: 'one' , (String with: Character lf) , 'two'.
	t clear.
	self assert: t text equals: ''
]

{ #category : #tests }
ViewTest >> testTheRegistryFindsAWrapperByItsHandle [
	| v |
	v := View new.
	self assert: (View at: v handle) == v.
	self assert: (View at: 123456789) isNil
]
