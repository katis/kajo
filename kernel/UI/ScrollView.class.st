"A view whose added views scroll inside it (module 9c); contentWidth:height: sizes what scrolls. Text, outline and table views scroll by themselves."
Class {
	#name : #ScrollView,
	#superclass : #View
}

{ #category : #accessing }
ScrollView >> contentWidth: w height: h [
	self set: 'contentWidth' to: w; set: 'contentHeight' to: h
]

{ #category : #registry }
ScrollView class >> kind [
	^ 'scroll'
]
