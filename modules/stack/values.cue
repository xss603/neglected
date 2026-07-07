package main

// values accepts user-supplied overrides from --values flags.
// Timoni replaces this field with the provided YAML/JSON/CUE content,
// so defaults must NOT live here — they are defined in #Config (templates package).
values: {}
