# Quality Gates

## Local Quality Checks

- SwiftLint is the local style and static-checking tool.
- Xcode build warnings must be treated as review findings.
- Unit tests must pass before merge.
- SonarCloud quality gate must be `Passed`.

## SonarCloud Checks

SonarCloud is configured through `sonar-project.properties`.

The expected repository secret is:

```text
SONAR_TOKEN
```

The scanner consumes SwiftLint output from:

```text
reports/swiftlint.json
```

## Dependency Risks

Dependencies are managed through Swift Package Manager and pinned in:

```text
Toernberechnung.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Review dependency updates in merge requests and check:

- version changes
- license compatibility
- security advisories
- build and test results

## Merge Rule

Merge only when:

- build passed
- tests passed
- SwiftLint passed
- SonarCloud quality gate passed
- at least one review approved the change
