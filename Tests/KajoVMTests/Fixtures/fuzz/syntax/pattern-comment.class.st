"A comment in a method's pattern holds brackets (the review fixes, part 2, item 3)."
Class {
	#name : #PatternComment,
	#superclass : #Object
}

{ #category : #accessing }
PatternComment >> at: i "index in [1, size]" put: v [
	^ v
]

{ #category : #accessing }
PatternComment >> "helper [x]" foo [
	^ 1
]
