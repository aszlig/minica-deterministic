# WARNING: Do not use this in *anything* other than test environments!

This is a deterministic version of [Minica](https://github.com/jsha/minica),
which is useful for generating certificates in NixOS tests.

Currently this is implemented by patching Go in order to introduce determinism
in [`randutil.MaybeReadByte`][1] and also uses `sed` to patch Minica.

The implementation is gruesome and will probably break with future versions of
Minica. This is **deliberate** so that I someday™ get annoyed enough to
implement it in sane way as an upstream pull request.

[1]: https://golang.org/pkg/crypto/internal/randutil/#MaybeReadByte
