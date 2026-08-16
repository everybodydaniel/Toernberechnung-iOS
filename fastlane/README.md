fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios lint

```sh
[bundle exec] fastlane ios lint
```

Führt SwiftLint auf dem gesamten Projekt aus

### ios test

```sh
[bundle exec] fastlane ios test
```

Baut das Projekt und führt alle Unit Tests aus

### ios coverage

```sh
[bundle exec] fastlane ios coverage
```

Erzeugt Coverage-Reports (Cobertura, SonarQube, HTML) via Slather

### ios ui_tests

```sh
[bundle exec] fastlane ios ui_tests
```

Führt XCUITest UI-Tests aus (erfordert UI-Test-Target/-Scheme)

### ios ci

```sh
[bundle exec] fastlane ios ci
```

Vollständiger lokaler CI-Lauf (Lint → Test → Coverage)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Baut und veröffentlicht eine interne TestFlight-Beta

### ios public_beta

```sh
[bundle exec] fastlane ios public_beta
```

Baut und veröffentlicht eine externe TestFlight-Beta über den Public Link

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
