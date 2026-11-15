# Module 8c: Processes saved in the image

Processes saved in the image built in module 8c: the stack words copied
verbatim into Array chunks under special object 8 with the ready queues, the
finalization Semaphore and the saver, image format version 2 (3 since 8d, 4
since 9b for class-table holes, 5 since module 10 for runs of blocks; 1 to 4
are refused naming module 10, images are rebuilt from sources), `Smalltalk
snapshot:` answering false in the saver and true on resume, a hold on the
scheduler before the stop with its own model, a loader that checks every
saved frame against its method and the bytecode verifier's depth at its pc,
`kajo run` resuming such an image until it is quiescent, the random programs
saved mid-run agreeing with their model, the kernels within noise, a save's
stop at 0.45 to 0.56 ms; 8c's six open questions in
`docs/modules/image-processes.md`.
