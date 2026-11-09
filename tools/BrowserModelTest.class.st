"The browser's model against a fake target (module 9c): the packages and the class tree by superclass and grouped by tag (tags as subdirectories), a class's categories, selectors and definition, a method's source, compiling (the files of the reply kept, a compile error at its line), a class definition parsed and sent, senders, removal, and define-and-retry."
Class {
	#name : #BrowserModelTest,
	#superclass : #TestCase,
	#instVars : [
		'compiled'
	],
	#category : #'Tools-Tests'
}

{ #category : #helpers }
BrowserModelTest >> answer: kind args: args [
	| o |
	kind = 'package.list' ifTrue: [^ #('Kernel' 'Sample')].
	kind = 'class.hierarchy' ifTrue: [^ {
		self entry: 'Object' superclass: nil package: 'Kernel' tag: 'Objects'.
		self entry: 'Shape' superclass: 'Object' package: 'Sample' tag: 'Shapes'.
		self entry: 'Circle' superclass: 'Shape' package: 'Sample' tag: 'Shapes'.
		self entry: 'Square' superclass: 'Shape' package: 'Sample' tag: 'Shapes'.
		self entry: 'Canvas' superclass: 'Object' package: 'Sample' tag: nil}].
	kind = 'class.selectors' ifTrue: [
		o := JsonObject new.
		o at: 'accessing' put: #('radius' 'radius:'); at: 'drawing' put: #('drawOn:').
		^ o].
	kind = 'class.definition' ifTrue: [
		o := JsonObject new.
		o at: 'name' put: (args at: 'className'); at: 'superclass' put: 'Shape'; at: 'instanceVariables' put: #('radius');
			at: 'classVariables' put: #(); at: 'package' put: 'Sample'; at: 'tag' put: 'Shapes'; at: 'comment' put: 'A circle.'.
		^ o].
	kind = 'method.source' ifTrue: [
		o := JsonObject new.
		o at: 'class' put: (args at: 'className'); at: 'selector' put: (args at: 'selector'); at: 'source' put: 'radius
	^ radius'; at: 'author' put: nil.
		^ o].
	kind = 'method.compile' ifTrue: [
		((args at: 'source') includesSubstring: '^ ^') ifTrue: [^ self error: 'CompileError: line 2: an expression expected'].
		compiled := args.
		o := JsonObject new.
		o at: 'selector' put: 'area'; at: 'files' put: {(JsonObject new) at: 'path' put: 'Circle.class.st'; at: 'text' put: '...'; yourself}.
		^ o].
	kind = 'class.define' ifTrue: [
		compiled := args.
		^ (JsonObject new) at: 'class' put: (args at: 'name');
			at: 'files' put: {(JsonObject new) at: 'path' put: ((args at: 'tag') ifNil: [''] ifNotNil: [:t | t , '/']) , (args at: 'name') , '.class.st'; at: 'text' put: '...'; yourself};
			yourself].
	kind = 'method.senders' ifTrue: [^ #('Canvas>>paint' 'Circle>>drawOn:')].
	kind = 'method.remove' ifTrue: [^ (JsonObject new) at: 'files' put: #(); yourself].
	^ nil
]

{ #category : #helpers }
BrowserModelTest >> entry: aName superclass: aSuper package: aPackage tag: aTag [
	| o |
	o := JsonObject new.
	o at: 'name' put: aName; at: 'superclass' put: aSuper; at: 'package' put: aPackage; at: 'tag' put: aTag.
	^ o
]

{ #category : #helpers }
BrowserModelTest >> fake [
	^ FakeDevClient on: [:kind :args | self answer: kind args: args]
]

{ #category : #tests }
BrowserModelTest >> testAClassDefinitionIsParsedAndSent [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectPackage: 'Sample'.
	m newClassTemplate.
	self assert: m sourceKind equals: #newClass.
	self assert: (m source includesSubstring: 'package: #Sample').
	self deny: (m source includesSubstring: 'category:').
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''a b c''
	classVariableNames: ''''
	package: #Sample
	tag: #''New-Shapes'''.
	self assert: (compiled at: 'name') equals: 'Triangle'.
	self assert: (compiled at: 'superclass') equals: 'Shape'.
	self assert: (compiled at: 'instanceVariables') equals: 'a b c'.
	self assert: (compiled at: 'package') equals: 'Sample'.
	self assert: (compiled at: 'tag') equals: 'New-Shapes'.
	self assert: (compiled includesKey: 'category') not.
	self assert: (m filesWritten first at: 'path') equals: 'New-Shapes/Triangle.class.st'.
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''a b c''
	classVariableNames: ''''
	package: ''Sample'''.
	self assert: (compiled at: 'tag') isNil.
	self assert: (m filesWritten first at: 'path') equals: 'Triangle.class.st'.
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''''
	classVariableNames: ''''
	category: ''Sample-Shapes'''.
	self assert: (m status includesSubstring: 'category: is gone').
	m accept: 'not a definition'.
	self assert: (m status includesSubstring: 'not a class definition')
]

{ #category : #tests }
BrowserModelTest >> testAClassItsSelectorsAndAMethod [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	self assert: m categories equals: #('accessing' 'drawing').
	self assert: m selectors equals: #('drawOn:' 'radius' 'radius:').
	self assert: m sourceKind equals: #definition.
	self assert: (m source beginsWith: 'Shape subclass: #Circle').
	self assert: (m source includesSubstring: 'instanceVariableNames: ''radius''').
	self assert: (m source endsWith: 'package: #Sample
	tag: #Shapes').
	m selectCategory: 'accessing'.
	self assert: m selectors equals: #('radius' 'radius:').
	m selectSelector: 'radius'.
	self assert: m sourceKind equals: #method.
	self assert: (m source beginsWith: 'radius')
]

{ #category : #tests }
BrowserModelTest >> testCompilingAndACompileErrorAtItsLine [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	m newMethodTemplate.
	m accept: 'area
	^ radius * radius'.
	self assert: (compiled at: 'className') equals: 'Circle'.
	self assert: (compiled at: 'category') equals: 'as yet unclassified'.
	self assert: m selector equals: 'area'.
	self assert: (m filesWritten first at: 'path') equals: 'Circle.class.st'.
	self assert: m errorLine isNil.
	m accept: 'area
	^ ^'.
	self assert: m errorLine equals: 2.
	self assert: (m status includesSubstring: 'line 2')
]

{ #category : #tests }
BrowserModelTest >> testDefineAMissingMethodThenRetry [
	| m retried |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m defineMethod: 'scaleBy:' in: 'Circle' then: [:sel | retried := sel].
	self assert: m className equals: 'Circle'.
	self assert: m sourceKind equals: #newMethod.
	self assert: (m source beginsWith: 'scaleBy: anObject').
	m accept: m source.
	self assert: retried equals: 'area'
]

{ #category : #tests }
BrowserModelTest >> testPatterns [
	| m |
	m := BrowserModel new.
	self assert: (m patternOf: 'foo') equals: 'foo'.
	self assert: (m patternOf: '+') equals: '+ anObject'.
	self assert: (m patternOf: 'at:put:') equals: 'at: anObject put: arg2'
]

{ #category : #tests }
BrowserModelTest >> testSendersAndGoingToOne [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	m senders.
	self assert: m messagesTitle equals: 'senders of radius'.
	self assert: m messages equals: #('Canvas>>paint' 'Circle>>drawOn:').
	m selectMessage: 'Canvas>>paint'.
	self assert: m className equals: 'Canvas'.
	self assert: m selector equals: 'paint'
]

{ #category : #tests }
BrowserModelTest >> testTheClassTreeBySuperclassAndByTag [
	| m tree |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	self assert: m packages equals: #('Kernel' 'Sample').
	m selectPackage: 'Sample'.
	self assert: m classNames asArray equals: #('Shape' 'Circle' 'Square' 'Canvas').
	tree := m classTree.
	self assert: (tree collect: [:t | t at: 3]) asArray equals: #('Canvas' 'Shape' 'Circle' 'Square').
	self assert: ((tree at: 3) at: 2) equals: (m idOfClass: 'Shape').
	self assert: ((tree at: 1) at: 2) equals: 0.
	m toggleByTag.
	self assert: m byTag.
	tree := m classTree.
	self assert: (tree collect: [:t | t at: 3]) asArray equals: #('Shapes' 'Shape' 'Circle' 'Square' 'Canvas').
	self assert: ((tree at: 2) at: 2) equals: (tree at: 1) first.
	self assert: (m classOfId: (tree at: 2) first) equals: 'Shape'.
	self assert: ((tree at: 5) at: 2) equals: 0.
	self assert: (m classOfId: (tree at: 5) first) equals: 'Canvas'
]
