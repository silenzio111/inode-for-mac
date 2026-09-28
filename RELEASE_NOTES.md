## iNode for Mac 0.5.0 beta 1

- Added a dedicated app icon and removed engine, chip and implementation labels from the sidebar footer.
- Built separate native `arm64` and `x86_64` apps. Both retain the existing connection flow and the two-site network check: either Google or Baidu passing displays “网络连接正常”.
- The public archives contain this project's code and apps, **not** H3C's proprietary engine or libraries. For ordinary iNode authentication, connect by another network first and run `Install Engine.command` in the extracted archive. It downloads a pinned upstream revision and prepares the component on your own Mac. On Apple Silicon, that x86_64 component also requires Rosetta 2. The PEAP alternative does not require it.
- These are ad-hoc signed, unnotarized beta builds. macOS may require manual approval in Privacy & Security.

The previous locally built ordinary-authentication version connected on one SWUFE dorm Ethernet port. This beta's source tests, package signatures, and offline PEAP failure path passed on both architectures; ordinary authentication in the public package and use on an Intel Mac have not yet been field-tested. See [README.md](README.md) for installation and licensing details.
