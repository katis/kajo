"Question 9: a scripting dictionary (the shape of an sdef: classes with typed properties, read-only or read-write, to-many elements, inheritance, an enumeration and a command with an optional named parameter) given as a Smalltalk literal, turned by code into protocols the checker uses for workspace expressions, and replaced by a second version with the expressions that read it rechecked. Nothing talks to another application."
Class {
	#name : #OTScripting,
	#superclass : #Object
}

{ #category : #dictionaries }
OTScripting class >> dictionary [
	"{kind. name. ...}: #class name parent properties ({name. type. #r or #rw}) elements ({name. type}); #enumeration name values; #command selector parts ({keyword or nil for the direct parameter. type. #optional or nil}) result."
	^ #(
		#(#class 'Mail.Application' nil #(#(#name 'String' #r)) #(#(#mailboxes 'Mail.Mailbox')))
		#(#class 'Mail.Item' nil #(#(#name 'String' #r)) #())
		#(#class 'Mail.Message' 'Mail.Item' #(#(#subject 'String' #rw) #(#sender 'String' #r) #(#readStatus 'Boolean' #rw) #(#priority 'Mail.Priority' #rw)) #())
		#(#class 'Mail.Mailbox' 'Mail.Item' #(#(#unreadCount 'Integer' #r)) #(#(#messages 'Mail.Message')))
		#(#enumeration 'Mail.Priority' #(#low #normal #high))
		#(#command 'move' #(#(nil 'Mail.Message' nil) #(#to 'Mail.Mailbox' nil) #(#withPriority 'Mail.Priority' #optional)) 'Nil'))
]

{ #category : #dictionaries }
OTScripting class >> dictionaryVersion2 [
	"The application updated: a message's subject is now a rich text object, sender is gone (replaced by from), and Mailbox gained a read-write name."
	^ #(
		#(#class 'Mail.Application' nil #(#(#name 'String' #r)) #(#(#mailboxes 'Mail.Mailbox')))
		#(#class 'Mail.Item' nil #(#(#name 'String' #r)) #())
		#(#class 'Mail.RichText' nil #(#(#plainText 'String' #r)) #())
		#(#class 'Mail.Message' 'Mail.Item' #(#(#subject 'Mail.RichText' #rw) #(#from 'String' #r) #(#readStatus 'Boolean' #rw) #(#priority 'Mail.Priority' #rw)) #())
		#(#class 'Mail.Mailbox' 'Mail.Item' #(#(#unreadCount 'Integer' #r) #(#name 'String' #rw)) #(#(#messages 'Mail.Message')))
		#(#enumeration 'Mail.Priority' #(#low #normal #high))
		#(#command 'move' #(#(nil 'Mail.Message' nil) #(#to 'Mail.Mailbox' nil) #(#withPriority 'Mail.Priority' #optional)) 'Nil'))
]

{ #category : #building }
OTScripting class >> typeNamed: aString in: anArray [
	"A class of the image, an enumeration (a Symbol: the values are not a type of the language), or a protocol of the dictionary."
	aString = 'Nil' ifTrue: [^ OTType nilType].
	(anArray anySatisfy: [:e | e first == #enumeration and: [(e at: 2) = aString]]) ifTrue: [^ OTType of: Symbol].
	(Smalltalk classNamed: aString) ifNotNil: [:c | ^ OTType of: c].
	^ OTProtocolType named: aString
]

{ #category : #building }
OTScripting class >> register: anArray in: anOTAnnotations [
	"Make a protocol of each class of the dictionary and register it (replacing one of the same name); the commands go to the application's protocol, an optional parameter giving a selector with it and one without. Answers the dependency keys the registration changes."
	| made keys app |
	made := Dictionary new.
	keys := OrderedCollection new.
	(anArray select: [:e | e first == #class]) do: [:e | | p |
		p := OTProtocolInfo named: (e at: 2) parent: ((e at: 3) ifNotNil: [:n | made at: n]).
		(e at: 4) do: [:prop | | t |
			t := self typeNamed: (prop at: 2) in: anArray.
			p addSignature: (OTSignature selector: prop first argTypes: #() result: t vars: Set new line: 0 meta: false owner: p).
			(prop at: 3) == #rw ifTrue: [
				p addSignature: (OTSignature selector: (prop first , ':') asSymbol argTypes: {t} result: OTSelf new vars: Set new line: 0 meta: false owner: p)]].
		(e at: 5) do: [:el |
			p addSignature: (OTSignature selector: el first argTypes: #() result: (OTClassType cls: Array args: {self typeNamed: (el at: 2) in: anArray}) vars: Set new line: 0 meta: false owner: p)].
		made at: (e at: 2) put: p].
	app := made at: 'Mail.Application'.
	(anArray select: [:e | e first == #command]) do: [:e | | required optional |
		required := (e at: 3) reject: [:part | (part at: 3) == #optional].
		optional := (e at: 3) select: [:part | (part at: 3) == #optional].
		{required. required , optional} do: [:parts | | sel |
			sel := String streamContents: [:s | parts do: [:part | s nextPutAll: (part first ifNil: [e at: 2]); nextPutAll: ':']].
			app addSignature: (OTSignature selector: sel asSymbol argTypes: (parts collect: [:part | self typeNamed: (part at: 2) in: anArray]) asArray
				result: (self typeNamed: (e at: 4) in: anArray) vars: Set new line: 0 meta: false owner: app)]].
	made do: [:p | keys add: (anOTAnnotations register: p)].
	^ keys
]

{ #category : #demo }
OTScripting class >> expressions [
	^ #('app mailboxes first messages first subject asUppercase'
		'app mailboxes first messages first sender , '' wrote'''
		'app mailboxes first messages first sender: ''me'''
		'app mailboxes first unreadCount + 1'
		'app move: app mailboxes first messages first to: app mailboxes last withPriority: #urgent'
		'app mailboxes first name: ''Archive''')
]
