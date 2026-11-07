Extension { #name : #UndefinedObject }

{ #category : #'*Answers' }
UndefinedObject >> run: worker of: workers [
	"kajo run is a batch host (the development answers): 1 when the forked Process's unhandled error ended it."
	^ AnswersProbe forkFailureAndWait ifTrue: [1] ifFalse: [0]
]
