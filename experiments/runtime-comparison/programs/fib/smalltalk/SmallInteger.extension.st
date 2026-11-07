Extension { #name : #SmallInteger }

{ #category : #'*Bench' }
SmallInteger >> fib [
	^ self < 2
		ifTrue: [self]
		ifFalse: [(self - 1) fib + (self - 2) fib]
]
