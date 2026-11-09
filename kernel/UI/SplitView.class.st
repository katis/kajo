"Panes side by side (vertical: true, the default) or stacked, each added view a pane the user can resize (module 9c)."
Class {
	#name : #SplitView,
	#superclass : #View
}

{ #category : #accessing }
SplitView >> position: aNumber of: aDivider [
	"Move divider aDivider (from 1) to aNumber points from the split view's left or top."
	self call: 'setPosition' with: {aDivider. aNumber}
]

{ #category : #accessing }
SplitView >> vertical: aBoolean [
	"Panes side by side when true, stacked when false."
	self set: 'vertical' to: aBoolean
]

{ #category : #registry }
SplitView class >> kind [
	^ 'split'
]
