"Collections with integer positions from 1: at:, at:put: and size are the subclass's."
Class {
	#name : #SequenceableCollection,
	#superclass : #Collection,
	#typeParameters : [
		'E'
	]
}

{ #category : #accessing }
SequenceableCollection >> allButFirst ^<Self> [
	^ self copyFrom: 2 to: self size
]

{ #category : #accessing }
SequenceableCollection >> allButLast ^<Self> [
	^ self copyFrom: 1 to: self size - 1
]

{ #category : #accessing }
SequenceableCollection >> atAllPut: anObject <E> ^<Self> [
	1 to: self size do: [:i | self at: i put: anObject]
]

{ #category : #accessing }
SequenceableCollection >> first ^<E> [
	self isEmpty ifTrue: [^ self error: 'the collection is empty'].
	^ self at: 1
]

{ #category : #accessing }
SequenceableCollection >> first: n <Integer> ^<Self> [
	^ self copyFrom: 1 to: n
]

{ #category : #accessing }
SequenceableCollection >> indexOf: anObject <Object> ^<Integer> [
	^ self indexOf: anObject ifAbsent: [0]
]

{ #category : #accessing }
SequenceableCollection >> indexOf: anObject <Object> ifAbsent: aBlock <[^:X]> ^<Integer | X> [
	1 to: self size do: [:i | (self at: i) = anObject ifTrue: [^ i]].
	^ aBlock value
]

{ #category : #accessing }
SequenceableCollection >> last ^<E> [
	self isEmpty ifTrue: [^ self error: 'the collection is empty'].
	^ self at: self size
]

{ #category : #accessing }
SequenceableCollection >> last: n <Integer> ^<Self> [
	^ self copyFrom: self size - n + 1 to: self size
]

{ #category : #accessing }
SequenceableCollection >> replaceFrom: start <Integer> to: stop <Integer> with: aCollection <SequenceableCollection[E]> ^<Self> [
	^ self replaceFrom: start to: stop with: aCollection startingAt: 1
]

{ #category : #accessing }
SequenceableCollection >> replaceFrom: start <Integer> to: stop <Integer> with: aCollection <SequenceableCollection[E]> startingAt: from <Integer> ^<Self> [
	| j |
	j := from.
	start to: stop do: [:i | self at: i put: (aCollection at: j). j := j + 1]
]

{ #category : #accessing }
SequenceableCollection >> swap: i <Integer> with: j <Integer> ^<Self> [
	| t |
	t := self at: i.
	self at: i put: (self at: j).
	self at: j put: t
]

{ #category : #comparing }
SequenceableCollection >> = aCollection <Object> ^<Boolean> [
	self == aCollection ifTrue: [^ true].
	self class == aCollection class ifFalse: [^ false].
	self size = aCollection size ifFalse: [^ false].
	1 to: self size do: [:i | (self at: i) = (aCollection at: i) ifFalse: [^ false]].
	^ true
]

{ #category : #comparing }
SequenceableCollection >> hash ^<Integer> [
	| h |
	h := self size.
	1 to: (self size min: 4) do: [:i | h := (h * 31 + (self at: i) hash) bitAnd: 16r3FFFFFFF].
	^ h
]

{ #category : #copying }
SequenceableCollection >> , aCollection <SequenceableCollection[E]> ^<Self> [
	| out |
	out := self species new: self size + aCollection size.
	out replaceFrom: 1 to: self size with: self startingAt: 1.
	out replaceFrom: self size + 1 to: out size with: aCollection asArray startingAt: 1.
	^ out
]

{ #category : #copying }
SequenceableCollection >> copyFrom: start <Integer> to: stop <Integer> ^<Self> [
	| out |
	stop < start ifTrue: [^ self species new: 0].
	out := self species new: stop - start + 1.
	out replaceFrom: 1 to: stop - start + 1 with: self startingAt: start.
	^ out
]

{ #category : #copying }
SequenceableCollection >> copyWith: anObject <E> ^<Self> [
	| out |
	out := self species new: self size + 1.
	out replaceFrom: 1 to: self size with: self startingAt: 1.
	out at: out size put: anObject.
	^ out
]

{ #category : #copying }
SequenceableCollection >> reversed ^<Self> [
	| out n |
	n := self size.
	out := self species new: n.
	1 to: n do: [:i | out at: i put: (self at: n - i + 1)].
	^ out
]

{ #category : #enumerating }
SequenceableCollection >> collect: aBlock <[E, ^:X]> ^<SequenceableCollection[X]> [
	| out |
	out := self species new: self size.
	1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i))].
	^ out
]

{ #category : #enumerating }
SequenceableCollection >> do: aBlock <[E, ^Dynamic]> ^<Self> [
	1 to: self size do: [:i | aBlock value: (self at: i)]
]

{ #category : #enumerating }
SequenceableCollection >> doWithIndex: aBlock <[E, Integer, ^Dynamic]> ^<Self> [
	1 to: self size do: [:i | aBlock value: (self at: i) value: i]
]

{ #category : #enumerating }
SequenceableCollection >> keysAndValuesDo: aBlock <[Integer, E, ^Dynamic]> ^<Self> [
	1 to: self size do: [:i | aBlock value: i value: (self at: i)]
]

{ #category : #enumerating }
SequenceableCollection >> reverseDo: aBlock <[E, ^Dynamic]> ^<Self> [
	self size to: 1 by: -1 do: [:i | aBlock value: (self at: i)]
]

{ #category : #enumerating }
SequenceableCollection >> select: aBlock <[E, ^Boolean]> ^<Self> [
	| s |
	s := WriteStream on: (self species new: 0).
	self do: [:e | (aBlock value: e) ifTrue: [s nextPut: e]].
	^ s contents
]

{ #category : #enumerating }
SequenceableCollection >> with: aCollection <SequenceableCollection[:Y]> collect: aBlock <[E, Y, ^:X]> ^<SequenceableCollection[X]> [
	| out |
	out := self species new: self size.
	1 to: self size do: [:i | out at: i put: (aBlock value: (self at: i) value: (aCollection at: i))].
	^ out
]

{ #category : #enumerating }
SequenceableCollection >> with: aCollection <SequenceableCollection[:Y]> do: aBlock <[E, Y, ^Dynamic]> ^<Self> [
	1 to: self size do: [:i | aBlock value: (self at: i) value: (aCollection at: i)]
]

{ #category : #enumerating }
SequenceableCollection >> withIndexDo: aBlock <[E, Integer, ^Dynamic]> ^<Self> [
	1 to: self size do: [:i | aBlock value: (self at: i) value: i]
]

{ #category : #sorting }
SequenceableCollection >> insertionSortFrom: lo <Integer> to: hi <Integer> by: aBlock <[E, E, ^Boolean]> ^<Self> [
	lo + 1 to: hi do: [:i | | x j |
		x := self at: i.
		j := i - 1.
		[j >= lo and: [(aBlock value: (self at: j) value: x) not]] whileTrue: [
			self at: j + 1 put: (self at: j).
			j := j - 1].
		self at: j + 1 put: x]
]

{ #category : #sorting }
SequenceableCollection >> merge: src <Array[E]> from: lo <Integer> mid: mid <Integer> to: hi <Integer> into: dst <Array[E]> by: aBlock <[E, E, ^Boolean]> ^<Self> [
	"src lo..mid and mid+1..hi are sorted: merge them into dst lo..hi, the left run first among equals."
	| i j k |
	i := lo.
	j := mid + 1.
	k := lo.
	[i <= mid and: [j <= hi]] whileTrue: [
		(aBlock value: (src at: i) value: (src at: j))
			ifTrue: [dst at: k put: (src at: i). i := i + 1]
			ifFalse: [dst at: k put: (src at: j). j := j + 1].
		k := k + 1].
	[i <= mid] whileTrue: [dst at: k put: (src at: i). i := i + 1. k := k + 1].
	[j <= hi] whileTrue: [dst at: k put: (src at: j). j := j + 1. k := k + 1]
]

{ #category : #sorting }
SequenceableCollection >> sort ^<Self> [
	^ self sort: [:a :b | a <= b]
]

{ #category : #sorting }
SequenceableCollection >> sort: aBlock <[E, E, ^Boolean]> ^<Self> [
	"In place, stable: a merge sort (module 9c: the browser sorts thousands of names) with runs of up to 8 sorted by insertion first."
	| n src dst width |
	n := self size.
	1 to: n by: 8 do: [:lo | self insertionSortFrom: lo to: (lo + 7 min: n) by: aBlock].
	n <= 8 ifTrue: [^ self].
	src := Array new: n.
	1 to: n do: [:i | src at: i put: (self at: i)].
	dst := Array new: n.
	width := 8.
	[width < n] whileTrue: [ | t |
		1 to: n by: width * 2 do: [:lo |
			self merge: src from: lo mid: (lo + width - 1 min: n) to: (lo + (width * 2) - 1 min: n) into: dst by: aBlock].
		t := src. src := dst. dst := t.
		width := width * 2].
	1 to: n do: [:i | self at: i put: (src at: i)]
]

{ #category : #streams }
SequenceableCollection >> readStream ^<ReadStream[Self]> [
	^ ReadStream on: self
]

{ #category : #streams }
SequenceableCollection >> writeStream ^<WriteStream[Self]> [
	^ WriteStream on: self
]

{ #category : #testing }
SequenceableCollection >> isSequenceable ^<Boolean> [
	^ true
]
