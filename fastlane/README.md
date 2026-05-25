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

Statische Code-Analyse mit SwiftLint

### ios test

```sh
[bundle exec] fastlane ios test
```

Baut das Projekt und führt alle Unit-Tests mit Coverage aus

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

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
