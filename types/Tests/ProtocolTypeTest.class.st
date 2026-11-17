"Protocols made by code (the owner's answer: protocol types are made by code only; the experiment's question 9 and its OTScriptingTest): a scripting dictionary in the shape of an sdef, given as a Smalltalk literal, made into protocols the checker uses for workspace expressions, then replaced by a second version, and the expressions that read it rechecked. Nothing talks to another application."
Class {
	#name : #ProtocolTypeTest,
	#superclass : #TestCase
}

{ #category : #tests }
ProtocolTypeTest >> testProtocolsMadeByCodeAndReplaced [
	| checker app mc keys |
	checker := TypeChecker new.
	ProtocolTypeTest register: ProtocolTypeTest dictionary in: checker table.
	app := Dictionary new at: 'app' put: (ProtocolType named: 'Mail.Application'); yourself.
	mc := checker checkSource: 'app mailboxes first messages first subject' named: 'doit' bindings: app.
	self assert: mc diagnostics isEmpty.
	self assert: mc inferredResult printString equals: 'String'.
	mc := checker checkSource: 'app mailboxes first messages first sender: ''me''' named: 'doit2' bindings: app.
	self assert: (mc diagnostics collect: [:d | d text]) asArray equals: #('Mail.Message does not answer #sender:').
	keys := ProtocolTypeTest register: ProtocolTypeTest dictionaryVersion2 in: checker table.
	checker recheck: (keys inject: Set new into: [:s :k | s addAll: (checker invalidate: k); yourself]).
	self assert: (checker doitCheck: 'doit') inferredResult printString equals: 'Mail.RichText'
]

{ #category : #building }
ProtocolTypeTest class >> register: anArray in: aTypeTable [
	"Make a protocol of each class of the dictionary and register it (replacing one of the same name); the commands go to the application's protocol, an optional parameter giving a selector with it and one without. Answers the dependency keys the registration changes."
	| made keys app |
	made := Dictionary new.
	keys := OrderedCollection new.
	(anArray select: [:e | e first == #class]) do: [:e | | p |
		p := TypeProtocol named: (e at: 2) parent: ((e at: 3) ifNotNil: [:n | made at: n]).
		(e at: 4) do: [:prop | | t |
			t := self typeNamed: (prop at: 2) in: anArray.
			p addSignature: (TypeSignature selector: prop first argTypes: #() result: t vars: Set new meta: false owner: p name kind: #protocol).
			(prop at: 3) == #rw ifTrue: [
				p addSignature: (TypeSignature selector: (prop first , ':') asSymbol argTypes: {t} result: SelfType new vars: Set new meta: false owner: p name kind: #protocol)]].
		(e at: 5) do: [:el |
			p addSignature: (TypeSignature selector: el first argTypes: #() result: (NominalType cls: Array args: {self typeNamed: (el at: 2) in: anArray}) vars: Set new meta: false owner: p name kind: #protocol)].
		made at: (e at: 2) put: p].
	app := made at: 'Mail.Application'.
	(anArray select: [:e | e first == #command]) do: [:e | | required optional |
		required := (e at: 3) reject: [:part | (part at: 3) == #optional].
		optional := (e at: 3) select: [:part | (part at: 3) == #optional].
		{required. required , optional} do: [:parts | | sel |
			sel := String streamContents: [:s | parts do: [:part | s nextPutAll: (part first ifNil: [e at: 2]); nextPutAll: ':']].
			app addSignature: (TypeSignature selector: sel asSymbol argTypes: (parts collect: [:part | self typeNamed: (part at: 2) in: anArray]) asArray
				result: (self typeNamed: (e at: 4) in: anArray) vars: Set new meta: false owner: app name kind: #protocol)]].
	made do: [:p | keys add: (aTypeTable register: p)].
	^ keys
]

{ #category : #building }
ProtocolTypeTest class >> typeNamed: aString in: anArray [
	"A class of the image, an enumeration (a Symbol: the values are not a type of the language), or a protocol of the dictionary."
	aString = 'Nil' ifTrue: [^ Type nilType].
	(anArray anySatisfy: [:e | e first == #enumeration and: [(e at: 2) = aString]]) ifTrue: [^ Type of: Symbol].
	(Smalltalk classNamed: aString) ifNotNil: [:c | ^ Type of: c].
	^ ProtocolType named: aString
]

{ #category : #dictionaries }
ProtocolTypeTest class >> dictionary [
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
ProtocolTypeTest class >> dictionaryVersion2 [
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
