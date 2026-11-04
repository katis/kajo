"What the owner opens (mode=demo): a window built in Smalltalk from the kernel's wrappers. The slider updates the label; the button appends a line to the text view; the Transcript goes to the text view (the shell posts each Transcript line as a text event for it); a background Process computes on a background worker and hops to the main thread to show its progress, then leaves it."
Class {
	#name : #ShellDemo,
	#superclass : #Object,
	#classInstVars : [
		'window',
		'label',
		'slider',
		'button',
		'text',
		'progress',
		'presses',
		'worker'
	],
	#category : #'Shell-Demo'
}

{ #category : #opening }
ShellDemo class >> open [
	"Build and show the window; answers the text view's handle (the shell sends Transcript lines there)."
	presses := 0.
	window := Window new.
	window title: 'Kajo'.
	window x: 80 y: 80 width: 420 height: 560.
	label := window add: Label new.
	label x: 20 y: 60 width: 380 height: 28.
	label text: 'Slide me'.
	slider := window add: Slider new.
	slider x: 20 y: 100 width: 380 height: 30.
	slider minimum: 0 maximum: 100.
	slider value: 50.
	slider action: [:v | label text: 'Slider at ' , v rounded printString].
	button := window add: Button new.
	button x: 20 y: 145 width: 180 height: 36.
	button title: 'Append a line'.
	button action: [
		presses := presses + 1.
		text appendLine: 'Pressed ' , presses printString , ' time' , (presses = 1 ifTrue: [''] ifFalse: ['s'])].
	progress := window add: Label new.
	progress x: 20 y: 190 width: 380 height: 28.
	progress text: 'Background: starting'.
	text := window add: TextView new.
	text x: 20 y: 230 width: 380 height: 300.
	window onClose: [:w | worker ifNotNil: [:p | p terminate]].
	window show.
	UIEventLoop start.
	Transcript show: 'Kajo demo: the slider updates the label, the button appends here, and a background Process reports below.'; cr.
	worker := [self background] forkAt: 1.
	^ text handle
]

{ #category : #background }
ShellDemo class >> background [
	"Count primes on a background worker; every 2000 numbers hop to the main thread to show the count (the view call moves this Process there), then leave it again."
	| count n |
	count := 0.
	n := 2.
	[n <= 200000] whileTrue: [
		(self isPrime: n) ifTrue: [count := count + 1].
		n \\ 2000 = 0 ifTrue: [
			progress text: 'Background: ' , count printString , ' primes below ' , n printString , ' (worker ' , ProcessorScheduler workerId printString , ' shows it)'.
			ProcessorScheduler detachFromMain].
		n := n + 1].
	Transcript show: 'Background Process done: ' , count printString , ' primes below 200000'; cr
]

{ #category : #background }
ShellDemo class >> isPrime: n [
	| d |
	n < 2 ifTrue: [^ false].
	d := 2.
	[d * d <= n] whileTrue: [n \\ d = 0 ifTrue: [^ false]. d := d + 1].
	^ true
]
