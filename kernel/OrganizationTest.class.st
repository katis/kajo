"Method categories, class packages and tags, and class comments in the image (module 8e; tags as subdirectories: a class's package is the directory its file is in and its tag the subdirectory): the image build keeps every method category its Tonel files carry, compile: and compile:classified: keep one, removeSelector: forgets it, and organization, categories and selectorsInCategory: read them."
Class {
	#name : #OrganizationTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #running }
OrganizationTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	#(#liveAnswer #liveValue: #liveValue) do: [:s | LiveSample removeSelector: s]
]

{ #category : #tests }
OrganizationTest >> testClassPackageTagAndComment [
	self assert: (Smalltalk packageOf: Object) = 'Kernel'.
	self assert: (Smalltalk tagOf: Object) == #Objects.
	self assert: (Smalltalk tagOf: Object class) == #Objects.
	self assert: (Object comment beginsWith: 'The root of the class hierarchy').
	self assert: Object class comment = Object comment.
	self assert: (Smalltalk tagOf: LiveSample) == #Tests.
	self assert: (Smalltalk tagOf: TestCase) == #SUnit.
	self assert: (Smalltalk definitionOf: Object) tag == #Objects.
	self assert: ((Smalltalk tagsOf: 'Kernel') includes: 'Collections').
	self assert: (ClassDescription includesSelector: #category) not
]

{ #category : #tests }
OrganizationTest >> testCompileKeepsACategory [
	Smalltalk isReleaseImage ifTrue: [^ self].
	LiveSample compile: 'liveAnswer ^ 1'.
	self assert: (LiveSample categoryOf: #liveAnswer) == #'as yet unclassified'.
	LiveSample compile: 'liveAnswer ^ 2' classified: 'answers'.
	self assert: (LiveSample categoryOf: #liveAnswer) == #answers.
	LiveSample compile: 'liveAnswer ^ 3'.
	self assert: (LiveSample categoryOf: #liveAnswer) == #answers.
	LiveSample compile: 'liveValue ^ value' classified: #accessing.
	self assert: (LiveSample selectorsInCategory: #answers) = #(#liveAnswer).
	self assert: LiveSample categories = #(#accessing #answers).
	LiveSample removeSelector: #liveAnswer.
	self assert: (LiveSample categoryOf: #liveAnswer) isNil.
	self assert: LiveSample categories = #(#accessing)
]

{ #category : #tests }
OrganizationTest >> testEveryMethodHasItsCategory [
	| missing |
	missing := OrderedCollection new.
	Smalltalk allBehaviors do: [:c |
		c selectors do: [:s | (c categoryOf: s) isNil ifTrue: [missing add: c printString , '>>' , s]]].
	self assert: missing isEmpty description: (missing isEmpty ifTrue: [''] ifFalse: [missing size printString , ' without a category, the first: ' , missing first])
]

{ #category : #tests }
OrganizationTest >> testTheBuildKeepsTheFilesCategories [
	self assert: (Object categoryOf: #==) == #comparing.
	self assert: (Behavior categoryOf: #new) == #'instance creation'.
	self assert: (Smalltalk class categoryOf: #at:) == #classes.
	self assert: (Object categoryOf: #noSuchSelector) isNil.
	self assert: ((Object selectorsInCategory: #comparing) includes: #~~).
	self assert: ((Object selectorsInCategory: 'comparing') includes: #=).
	self assert: (Object categories includes: #comparing).
	self assert: Object categories = (Object categories asArray sort: [:a :b | a <= b]).
	self assert: ((Object organization at: #comparing) includes: #==)
]
