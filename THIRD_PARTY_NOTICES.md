# Third-party notices

## LAME 3.100

MP3 export uses a separate LAME executable, compiled from a pinned upstream source archive with static libmp3lame linkage. LAME is licensed under LGPL-2.0-or-later and is not relicensed under Ryokuon's MIT license.

Every app bundle includes the upstream license (`LAME-LICENSE.txt`), the corresponding upstream source archive (`lame-3.100-source.tar.gz`) and the recipe (`LAME-build.sh`) under `Contents/Resources`. `Scripts/build-lame.sh` documents the build flags and the removal of the obsolete `lame_init_old` export entry. To reproduce or modify the helper, use the recipe from the repository on macOS with Xcode command-line tools. Users may replace `Contents/Helpers/lame` in their own development builds; re-sign the development bundle afterwards.

Upstream: https://lame.sourceforge.io/

Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz

SHA-256: `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`

The source checksum and build fix match Homebrew's [3.100 formula](https://github.com/Homebrew/homebrew-core/blob/f68a7afb7c9ffc5fa5f16ab63fa3d03fc7c63843/Formula/l/lame.rb). Bundling deliberately does not reuse the latest Homebrew binary, whose runtime dependencies can change.
