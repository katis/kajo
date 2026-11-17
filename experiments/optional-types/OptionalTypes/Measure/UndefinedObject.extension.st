Extension {
	#name : #UndefinedObject
}

{ #category : #'*OptionalTypes' }
UndefinedObject >> run: i of: n [
	"The experiment's entry for `kajo run <image> --sources <dir>`: the first word of <dir>/command names an OTMeasure class-side measurement; answers 0 when it finished, 1 when it signalled an error (written to out/error.txt)."
	| command |
	command := (Smalltalk primReadFile: 'command') ifNil: [^ 2].
	^ [OTMeasure perform: command substrings first asSymbol. 0]
		on: Error
		do: [:e |
			Smalltalk primWriteFile: 'out/error.txt' contents: e messageText printString , String lf , e frames printString.
			e return: 1]
]
