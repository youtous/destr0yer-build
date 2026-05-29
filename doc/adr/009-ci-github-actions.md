# ADR-009: CI/CD — GitHub Actions

**Status**: Done

**Decision**: Migrated from GitLab CI to GitHub Actions.

**Workflows**:
- `lint.yml`: pre-commit + ansible-lint on push/PR
- `release.yml`: automatic GitHub release creation on tag

**Old file**: `.gitlab-ci.yml` (removed, available in git history)

**Related Trello item**:
- "Argo + local git replicated on GitHub" — superseded by Kluctl (ADR-013).
