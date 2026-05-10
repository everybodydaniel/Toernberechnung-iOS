# Build Management

## Project Generation

`project.yml` is the source for XcodeGen-based project regeneration.

```bash
xcodegen generate
```

## Build

```bash
./scripts/build.sh
```

## Test

```bash
./scripts/test.sh
```

Use a different simulator through `DESTINATION`:

```bash
DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.4.1' ./scripts/test.sh
```

## Documentation

Generate static DocC documentation:

```bash
./scripts/docs.sh
```

The generated website is written to:

```text
docs/api
```

For PDF export, open the generated documentation in a browser and print/save it as PDF. Xcode/DocC produces the website artifact; PDF generation is intentionally a final export step.
