// Loaded by /usr/bin/perl (see MediaController.bridgeScript). macOS 15.4+ only answers Now Playing queries from
// Apple-signed processes, so the app runs this code inside perl and reads JSON lines from its stdout.
void np_stream(void *perl, void *cv);
void np_command(void *perl, void *cv);
