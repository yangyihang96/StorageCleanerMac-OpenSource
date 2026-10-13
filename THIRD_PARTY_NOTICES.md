# Third-Party Notices

## Sparkle 2

Automatic application updates use Sparkle 2:

- Project: https://github.com/sparkle-project/Sparkle
- License: MIT and bundled third-party notices
- Full license: `Sparkle-LICENSE.txt` inside the application resources and release archives

## Stats SMC helper

The read-only AppleSMC fan-speed access in `SMCFanSpeedService` references the public SMC helper approach from Stats:

- Project: https://github.com/exelban/stats
- License: MIT
- Copyright: Copyright (c) 2019 Serhiy Mytrovtsiy

## PureMac similar-photo matching

The similar-photo review matcher in `DuplicateFileScanner` adapts the perceptual
hash, colour-distance, and aspect-ratio comparison approach from PureMac. It
does not copy PureMac's deletion workflow or artwork.

- Project: https://github.com/momenbasel/PureMac
- License: MIT
- Copyright: Copyright (c) 2026 PureMac Contributors

MIT License text for the two projects above:

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## MacMiniMode power policy reference

The Mac mini mode power-source reconciliation and closed-lid sleep restoration
design references MacMiniMode. StorageCleanerMac implements its own policy,
XPC transport, root-owned recovery journal and lifecycle; no upstream source
code was copied.

- Project: https://github.com/Pama-Lee/MacMiniMode
- Reference commit: `f21aad039bc517f396e31f3612059bafec4d1008`
- License: MIT
- Copyright: Copyright (c) 2026 MacMiniMode contributors
- The MIT permission and warranty text printed above also applies to this notice.
