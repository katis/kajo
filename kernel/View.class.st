"A native view behind a handle (ADR 0010). The shell owns the native object (an NSView or UIView) in a table by handle; the wrapper holds the handle, and every property is set and read through the view primitive in the same turn (ADR 0004's set then get). The primitive is a hop primitive: called off the main thread the Process moves to the main worker and the send is retried there. The protocol is the same on AppKit and UIKit; the platform is behind the primitive. A wrapper is registered by handle (weakly, for events) and with an Ephemeron whose finalizer tells the shell the handle died, so the shell releases the native view when the wrapper is collected. With no shell (headless: kajo test, kajo run) the wrapper keeps its properties itself and its handle is negative, so the protocol and its tests run anywhere. Frames are in points, no layout system."
Class {
	#name : #View,
	#superclass : #Object,
	#instVars : [
		'handle',
		'props',
		'subviews',
		'superview'
	],
	#classInstVars : [
		'registry',
		'lock',
		'headlessHandles',
		'died'
	],
	#category : #'Kernel-UI'
}

{ #category : #accessing }
View >> detach [
	handle := nil
]

{ #category : #accessing }
View >> handle [
	^ handle
]

{ #category : #accessing }
View >> isHeadless [
	^ handle notNil and: [handle < 0]
]

{ #category : #events }
View >> handleEvent: anEvent [
	"Sent by the event loop with an event for this view's handle."
	^ self
]

{ #category : #geometry }
View >> height [
	^ self get: 'height'
]

{ #category : #geometry }
View >> moveToX: x y: y [
	"Move without resizing: the display-link probe moves a View with this every frame."
	self isHeadless ifTrue: [self set: 'x' to: x; set: 'y' to: y. ^ self].
	self class primCall: #origin handle: handle with: {x. y}
]

{ #category : #geometry }
View >> width [
	^ self get: 'width'
]

{ #category : #geometry }
View >> x [
	^ self get: 'x'
]

{ #category : #geometry }
View >> x: x y: y width: w height: h [
	"The frame in points, in the superview's coordinates (y down on both platforms)."
	self isHeadless ifTrue: [
		self set: 'x' to: x; set: 'y' to: y; set: 'width' to: w; set: 'height' to: h.
		^ self].
	self class primCall: #frame handle: handle with: {x. y. w. h}
]

{ #category : #geometry }
View >> y [
	^ self get: 'y'
]

{ #category : #hierarchy }
View >> add: aView [
	"aView becomes a subview: the native view is added to this one, and the wrapper is held here, so a window's views live while the window does."
	aView setSuperview: self.
	subviews add: aView.
	self isHeadless ifFalse: [self class primCall: #add handle: handle with: {aView handle}].
	^ aView
]

{ #category : #hierarchy }
View >> setSuperview: aView [
	superview := aView
]

{ #category : #hierarchy }
View >> subviews [
	^ subviews
]

{ #category : #hierarchy }
View >> superview [
	^ superview
]

{ #category : #initialization }
View >> initialize [
	subviews := OrderedCollection new.
	handle := self class createNative: self class kind.
	self class track: self
]

{ #category : #printing }
View >> printOn: aStream [
	aStream nextPutAll: self class name; nextPut: $(; print: handle; nextPut: $)
]

{ #category : #properties }
View >> autoresize: aString [
	"Which edges follow the superview's size (module 9c): 'width', 'height', 'width height', 'left', 'top' combined, or '' for none."
	self set: 'autoresize' to: aString
]

{ #category : #properties }
View >> call: aName with: anArray [
	"A native method of the view (show, close, appendLine, clear): one primitive call."
	self isHeadless ifTrue: [^ self headlessCall: aName with: anArray].
	^ self class primCall: #call handle: handle with: {aName} , anArray
]

{ #category : #properties }
View >> color: aString [
	"A named color: red, green, blue, orange, gray, black, white, clear."
	self set: 'color' to: aString
]

{ #category : #properties }
View >> contextMenu: aMenu [
	"aMenu opens on a secondary click in this view (module 9c); held here so it lives while the view does."
	subviews add: aMenu.
	aMenu setSuperview: self.
	self call: 'setMenu' with: {aMenu handle}
]

{ #category : #properties }
View >> get: aName [
	self isHeadless ifTrue: [^ props isNil ifTrue: [nil] ifFalse: [props at: aName ifAbsent: [nil]]].
	^ self class primCall: #get handle: handle with: {aName}
]

{ #category : #properties }
View >> headlessCall: aName with: anArray [
	^ nil
]

{ #category : #properties }
View >> hidden: aBoolean [
	self set: 'hidden' to: aBoolean
]

{ #category : #properties }
View >> isHidden [
	^ (self get: 'hidden') == true
]

{ #category : #properties }
View >> set: aName to: aValue [
	"Set a native property and answer the value; set then get answers it in the same turn."
	self isHeadless ifTrue: [
		props isNil ifTrue: [props := Dictionary new].
		props at: aName put: aValue.
		^ aValue].
	self class primCall: #set handle: handle with: {aName. aValue}.
	^ aValue
]

{ #category : #primitives }
View class >> hasShell [
	<primitive: 151>
	^ false
]

{ #category : #primitives }
View class >> primCall: op handle: aHandle with: anArray [
	"Primitive 150, a hop primitive (see the class comment)."
	<primitive: 150>
	^ self error: 'the view call ' , op printString , ' failed'
]

{ #category : #primitives }
View class >> releaseHandle: aHandle [
	"Primitive 152: the shell releases the native view of aHandle on its main thread. Does nothing with no shell."
	<primitive: 152>
	^ self
]

{ #category : #registry }
View class >> at: aHandle [
	"The live wrapper of aHandle, or nil."
	| cell |
	self == View ifFalse: [^ View at: aHandle].
	lock critical: [cell := registry at: aHandle ifAbsent: [nil]].
	^ cell isNil ifTrue: [nil] ifFalse: [cell at: 1]
]

{ #category : #registry }
View class >> createNative: aKind [
	"The registry's state lives in View's class-side variables, not in each subclass's."
	self == View ifFalse: [^ View createNative: aKind].
	self hasShell ifTrue: [^ self primCall: #create handle: nil with: {aKind}].
	^ lock critical: [headlessHandles := headlessHandles - 1]
]

{ #category : #registry }
View class >> diedCount [
	self == View ifFalse: [^ View diedCount].
	^ died
]

{ #category : #registry }
View class >> handleDied: aHandle [
	"Run by the finalization Process when the wrapper of aHandle was collected."
	self == View ifFalse: [^ View handleDied: aHandle].
	lock critical: [
		registry removeKey: aHandle ifAbsent: [nil].
		died := died + 1].
	aHandle > 0 ifTrue: [self releaseHandle: aHandle]
]

{ #category : #registry }
View class >> includesHandle: aHandle [
	self == View ifFalse: [^ View includesHandle: aHandle].
	^ lock critical: [registry includesKey: aHandle]
]

{ #category : #registry }
View class >> initialize [
	"View's own; the subclasses' class-side variables stay nil (every registry method goes to View)."
	self == View ifFalse: [^ self].
	registry := Dictionary new.
	lock := Semaphore forMutualExclusion.
	headlessHandles := 0.
	died := 0
]

{ #category : #registry }
View class >> kind [
	"The native kind the shell creates for this class."
	^ 'view'
]

{ #category : #registry }
View class >> resumeAfterSnapshot [
	"A saved image resumed in a new shell: native views are not saved, so every live wrapper comes back detached (handle nil; a view call on it fails) and the table is emptied."
	| cells |
	self == View ifFalse: [^ View resumeAfterSnapshot].
	lock critical: [cells := registry values. registry := Dictionary new].
	cells do: [:c | (c at: 1) ifNotNil: [:v | v detach]]
]

{ #category : #registry }
View class >> track: aView [
	"Register aView by its handle (weakly) and arrange for its handle to be released when it is collected. The finalizer holds the handle, never the wrapper."
	| cell h |
	self == View ifFalse: [^ View track: aView].
	h := aView handle.
	cell := WeakArray new: 1.
	cell at: 1 put: aView.
	lock critical: [registry at: h put: cell].
	Ephemeron key: aView value: h finalizer: [:dead | self handleDied: dead]
]
