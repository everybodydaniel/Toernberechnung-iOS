# Contributing

## Workflow

1. Create an issue before larger changes.
2. Create a feature branch from `main`.
3. Keep commits focused and readable.
4. Open a merge request or pull request.
5. Request at least one review before merging.
6. Merge only when build, tests, linting and SonarCloud quality gate pass.

## Branch Names

- `feature/<short-topic>`
- `bugfix/<short-topic>`
- `docs/<short-topic>`
- `chore/<short-topic>`

## Review Labels

- `type:feature`
- `type:bug`
- `type:docs`
- `type:chore`
- `priority:high`
- `priority:medium`
- `priority:low`
- `status:ready-for-review`
- `status:blocked`
- `area:engine`
- `area:ui`
- `area:services`
- `area:tests`

## Local Checks

Run these checks before opening a review:

```bash
./scripts/lint.sh
./scripts/format.sh
./scripts/test.sh
./scripts/build.sh
```

## Versioning

This project uses `<Major>.<Feature>.<Bugfix>`, for example `1.0.0`.

- Major: incompatible or fundamental product changes.
- Feature: user-visible functionality or relevant platform improvements.
- Bugfix: corrections, tests, docs and small internal improvements.
